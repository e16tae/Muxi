import Foundation
import os

// MARK: - ConnectionState

/// Represents the high-level state of a ``ConnectionManager`` session.
///
/// The typical lifecycle progresses:
///   `.disconnected` -> `.connecting` -> `.attached`
///
/// `.reconnecting` is entered when an active connection drops and the
/// manager attempts automatic re-establishment with exponential backoff.
enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case attached(sessionName: String)
    case reconnecting
}

// MARK: - ScrollbackError

/// Errors specific to scrollback fetch operations.
enum ScrollbackError: Error, Equatable {
    case notAttached
    case fetchInProgress
}

// MARK: - ConnectionManager

/// Orchestrates SSH connection, tmux session querying, and state management.
///
/// `ConnectionManager` ties together ``SSHServiceProtocol``,
/// ``TmuxControlService``, and ``KeychainService`` into a single observable
/// object that the UI layer can bind to.
///
/// - Note: Marked `@MainActor` so all property mutations are safe to observe
///   from SwiftUI views.
@MainActor
@Observable
final class ConnectionManager {
    private let logger = Logger(subsystem: "com.muxi.app", category: "ConnectionManager")
    private let sshService: SSHServiceProtocol
    private let tmuxService = TmuxControlService()
    private let keychainService = KeychainService()
    private let lastSessionStore: LastSessionStore

    /// The current connection state.
    private(set) var state: ConnectionState = .disconnected

    #if DEBUG
    /// Test-only: override the connection state for unit tests.
    func setStateForTesting(_ newState: ConnectionState) {
        state = newState
    }
    #endif

    /// The server we are currently connected (or connecting) to.
    private(set) var currentServer: Server?

    /// The list of tmux sessions discovered on the remote server.
    private(set) var sessions: [TmuxSession] = []

    /// Per-pane terminal buffers, keyed by tmux pane ID (e.g., "%0").
    private(set) var paneBuffers: [String: TerminalBuffer] = [:]

    /// Current pane layout from tmux.
    private(set) var currentPanes: [TmuxControlService.ParsedPane] = []

    /// The SSH service (exposed for actor-routed channel writes).
    var sshServiceForWrites: SSHServiceProtocol { sshService }

    /// The active SSH shell channel (for tmux control mode).
    private(set) var activeChannel: SSHChannel?

    /// Monitors SSH connection health and triggers reconnect on drop.
    private var sshMonitorTask: Task<Void, Never>?
    private var detachTask: Task<Void, Never>?

    /// Cached credentials from the last successful ``connect(server:password:)``
    /// call, reused by ``reconnect()`` so we do not need to hit the Keychain
    /// again when re-establishing a dropped connection.
    private var cachedAuth: SSHAuth?

    /// Queue of pane IDs waiting for ``capture-pane`` response.
    /// Each ``capture-pane -e -p -t %<id>`` triggers a %begin/%end block;
    /// responses are matched to panes in FIFO order.
    private var capturePaneQueue: [String] = []

    /// When `true`, layout-change callbacks skip ``capture-pane`` for new
    /// panes. Set at attach time and cleared by the first real resize from
    /// the GeometryReader so we don't capture at the placeholder 80×24 size.
    private var pendingInitialResize = false

    /// Continuation waiting for a scrollback `capture-pane` response.
    /// Set by ``fetchScrollback(paneId:)`` and resumed by
    /// ``deliverScrollbackResponse(_:)``.
    private var scrollbackContinuation: CheckedContinuation<String, Error>?

    /// Pane IDs currently in scrollback mode. Managed by TerminalSessionView.
    var scrolledBackPanes: Set<String> = []

    /// Panes that received new output while in scrollback mode.
    var paneHasNewOutput: Set<String> = []

    /// Whether the last disconnect was caused by the app going to background.
    /// When true, `handleForeground()` will auto-reconnect.
    private(set) var disconnectedByBackground = false

    /// The server from the last background disconnect, used for auto-reconnect.
    private var lastBackgroundServer: Server?

    /// The tmux session name from the last background disconnect.
    private var lastBackgroundSession: String?

    // MARK: - Reconnect Configuration

    /// Maximum number of reconnection attempts before giving up.
    let maxReconnectAttempts: Int

    /// Base delay for exponential backoff (1s, 2s, 4s, 8s, 16s ...).
    let baseDelay: TimeInterval

    /// The current reconnection attempt (observable for the UI).
    /// Zero when not reconnecting.
    private(set) var reconnectAttempt: Int = 0

    /// Create a connection manager, optionally injecting an SSH service
    /// implementation for testing.
    init(
        sshService: SSHServiceProtocol? = nil,
        lastSessionStore: LastSessionStore = LastSessionStore(),
        maxReconnectAttempts: Int = 5,
        baseDelay: TimeInterval = 1.0
    ) {
        self.sshService = sshService ?? SSHService()
        self.lastSessionStore = lastSessionStore
        self.maxReconnectAttempts = maxReconnectAttempts
        self.baseDelay = baseDelay
    }

    // MARK: - Connect

    /// Establish an SSH connection to the given server, query its tmux
    /// sessions, and auto-attach to the best candidate.
    ///
    /// Session selection priority:
    /// 1. Last-used session for this server (if it still exists)
    /// 2. First available session
    /// 3. Create a new session named "main"
    ///
    /// - Parameters:
    ///   - server: The server profile to connect to.
    ///   - password: An optional password.  When `nil` and the server's
    ///     ``AuthMethod`` is `.password`, the password is retrieved from the
    ///     Keychain.
    func connect(server: Server, password: String? = nil) async throws {
        guard state == .disconnected else { return }
        state = .connecting
        currentServer = server
        logger.info("Connecting to \(server.host):\(server.port) user=\(server.username)")

        do {
            let auth = try resolveAuth(for: server, password: password)
            cachedAuth = auth
            logger.info("Auth resolved, starting SSH connect...")

            try await sshService.connect(
                host: server.host,
                port: server.port,
                username: server.username,
                auth: auth
            )
            logger.info("SSH connected, querying tmux sessions...")

            // Check tmux availability before querying sessions.
            try await checkTmuxAvailability()

            // Query tmux sessions via a formatted list-sessions command.
            let output = try await sshService.execCommand(
                "tmux list-sessions -F '#{session_id}:#{session_name}:#{session_windows}:#{session_activity}'"
            )
            sessions = TmuxControlService.parseFormattedSessionList(output)
            logger.info("Found \(self.sessions.count) tmux sessions")

            // Auto-select session: last-used > first available > create new
            let serverID = server.id.uuidString
            let targetSession: String

            if let lastUsed = lastSessionStore.lastSessionName(forServerID: serverID),
               sessions.contains(where: { $0.name == lastUsed }) {
                targetSession = lastUsed
                logger.info("Resuming last-used session: \(lastUsed)")
            } else if let first = sessions.first {
                targetSession = first.name
                logger.info("Attaching to first session: \(targetSession)")
            } else {
                // No sessions exist — create one
                _ = try await sshService.execCommand("tmux new-session -d -s \("main".shellEscaped())")
                targetSession = "main"
                logger.info("Created new session: main")
                // Refresh to populate sessions array
                let refreshed = try await sshService.execCommand(
                    "tmux list-sessions -F '#{session_id}:#{session_name}:#{session_windows}:#{session_activity}'"
                )
                sessions = TmuxControlService.parseFormattedSessionList(refreshed)
            }

            try await performAttach(sessionName: targetSession)
            lastSessionStore.save(sessionName: targetSession, forServerID: serverID)

        } catch {
            logger.error("Connection failed: \(error)")
            state = .disconnected
            currentServer = nil
            cachedAuth = nil
            throw error
        }
    }

    // MARK: - Disconnect

    /// Tear down the SSH connection and reset all state.
    func disconnect() {
        sshMonitorTask?.cancel()
        sshMonitorTask = nil
        activeChannel = nil  // Don't close — SSHService owns the channel lifecycle
        tmuxService.resetLineBuffer()
        paneBuffers = [:]
        currentPanes = []
        sshService.disconnect()
        state = .disconnected
        currentServer = nil
        sessions = []
        cachedAuth = nil
        capturePaneQueue = []
        lastSentSize = (0, 0)
        pendingInitialResize = false

        scrolledBackPanes = []
        paneHasNewOutput = []

        // Cancel any pending scrollback fetch to avoid leaking the continuation.
        if let continuation = scrollbackContinuation {
            scrollbackContinuation = nil
            continuation.resume(throwing: ScrollbackError.notAttached)
        }
    }

    // MARK: - App Lifecycle

    /// Called when the app enters background. Saves connection state,
    /// cancels the SSH monitor, sends tmux detach, and disconnects.
    func handleBackground() {
        if case .attached(let sessionName) = state {
            lastBackgroundServer = currentServer
            lastBackgroundSession = sessionName
            disconnectedByBackground = true

            // Cancel monitor to prevent it from detecting our disconnect
            // and triggering its own reconnect.
            sshMonitorTask?.cancel()
            sshMonitorTask = nil

            // Clear UI state immediately (keep currentServer and cachedAuth for reconnect).
            activeChannel = nil
            tmuxService.resetLineBuffer()
            paneBuffers = [:]
            currentPanes = []
            state = .disconnected
            sessions = []
            capturePaneQueue = []
            lastSentSize = (0, 0)

            // Clear credentials from memory while backgrounded.
            cachedAuth = nil

            // Send detach THEN disconnect — ordering guaranteed within same Task.
            // Without this, disconnect() could tear down the channel before detach is sent.
            Task {
                try? await sshService.writeToChannel(Data("detach\n".utf8))
                sshService.disconnect()
            }
        } else if state == .connecting {
            lastBackgroundServer = currentServer
            lastBackgroundSession = nil
            disconnectedByBackground = true

            cachedAuth = nil

            sshMonitorTask?.cancel()
            sshMonitorTask = nil
            sshService.disconnect()
            state = .disconnected
            sessions = []
            capturePaneQueue = []
            lastSentSize = (0, 0)
        }
        // If already disconnected, do nothing.
    }

    /// Called when the app returns to foreground. Auto-reconnects if the
    /// previous disconnect was caused by backgrounding.
    func handleForeground() {
        guard disconnectedByBackground else { return }
        disconnectedByBackground = false

        guard let server = lastBackgroundServer ?? currentServer else {
            lastBackgroundServer = nil
            lastBackgroundSession = nil
            return
        }

        // Re-query Keychain for credentials cleared during background.
        if cachedAuth == nil {
            do {
                cachedAuth = try resolveAuth(for: server)
            } catch {
                // User didn't save password — can't auto-reconnect.
                logger.info("Cannot re-query credentials from Keychain: \(error.localizedDescription)")
                lastBackgroundServer = nil
                lastBackgroundSession = nil
                state = .disconnected
                return
            }
        }

        // Restore state needed by reconnect().
        currentServer = server
        let sessionName = lastBackgroundSession

        if let sessionName {
            state = .attached(sessionName: sessionName)
        } else {
            // Was connecting/transitioning — just disconnect cleanly
            lastBackgroundServer = nil
            lastBackgroundSession = nil
            return
        }

        lastBackgroundServer = nil
        lastBackgroundSession = nil

        Task {
            await reconnect()
        }
    }

    // MARK: - Session Management

    /// Core attach logic: wire callbacks, open shell, send tmux -CC attach.
    /// Callers must ensure previous channel is cleaned up before calling.
    private func performAttach(sessionName: String) async throws {
        wireCallbacks()

        let channel = try await sshService.startShell(onData: { [weak self] data in
            Task { @MainActor in
                self?.tmuxService.feed(data)
            }
        })
        activeChannel = channel

        let command = "tmux -CC attach -t \(sessionName.shellEscaped())\n"
        try await sshService.writeToChannel(Data(command.utf8))
        state = .attached(sessionName: sessionName)

        pendingInitialResize = true
        let refreshCmd = "refresh-client -C 80,24\n"
        try await sshService.writeToChannel(Data(refreshCmd.utf8))

        sshMonitorTask?.cancel()
        sshMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if self.sshService.state == .disconnected,
                   case .attached = self.state {
                    await self.reconnect()
                    return
                }
            }
        }
    }

    /// Attach to a tmux session by name.
    ///
    /// Opens an interactive SSH shell channel running
    /// `tmux -CC attach -t <name>` and pipes output through
    /// ``TmuxControlService/feed(_:)``.
    func attachSession(_ session: TmuxSession) async throws {
        guard state != .disconnected else { return }
        await detachTask?.value
        detachTask = nil
        try await performAttach(sessionName: session.name)
        if let serverID = currentServer?.id.uuidString {
            lastSessionStore.save(sessionName: session.name, forServerID: serverID)
        }
    }

    /// Disconnect from the server entirely and return to the server list.
    func detach() {
        disconnect()
    }

    /// Switch to a different tmux session from within the terminal.
    /// Closes the current control mode channel and reattaches to the new session.
    func switchSession(to sessionName: String) async throws {
        guard case .attached(let currentSession) = state else { return }
        logger.info("Switching session: '\(currentSession)' → '\(sessionName)'")

        // Cancel any pending scrollback fetch to avoid leaking the continuation.
        if let continuation = scrollbackContinuation {
            scrollbackContinuation = nil
            continuation.resume(throwing: ScrollbackError.notAttached)
        }

        // Clean up current session
        sshMonitorTask?.cancel()
        sshMonitorTask = nil
        activeChannel = nil
        tmuxService.resetLineBuffer()
        paneBuffers = [:]
        currentPanes = []
        scrolledBackPanes = []
        paneHasNewOutput = []
        capturePaneQueue = []
        lastSentSize = (0, 0)

        // Close the shell channel
        await sshService.closeShell()

        // Attach to new session
        try await performAttach(sessionName: sessionName)

        // Save as last-used
        if let serverID = currentServer?.id.uuidString {
            lastSessionStore.save(sessionName: sessionName, forServerID: serverID)
        }
    }

    /// Create a new tmux session and switch to it.
    ///
    /// When a shell is active (non-blocking mode), `execCommand` cannot open
    /// new channels. Instead, the create command is sent through the tmux
    /// control mode channel, and the session list is updated locally.
    func createAndSwitchToNewSession(name: String) async throws {
        guard case .attached = state else { return }

        // Create session via tmux control mode channel.
        let cmd = "new-session -d -s \(name.shellEscaped())\n"
        logger.info("Creating new session '\(name)' via control channel")
        try await sshService.writeToChannel(Data(cmd.utf8))

        // Add to local session list (execCommand-based refresh doesn't work
        // while a shell is active).
        if !sessions.contains(where: { $0.name == name }) {
            sessions.append(TmuxSession(
                id: "", name: name, windows: [], createdAt: Date(), lastActivity: Date()
            ))
        }

        try await switchSession(to: name)
    }

    // MARK: - Terminal Resize

    /// The last terminal size sent to tmux, to avoid redundant commands.
    private var lastSentSize: (cols: Int, rows: Int) = (0, 0)

    /// Notify tmux of a new client size. Tmux will re-layout panes and
    /// TUI applications will receive SIGWINCH to adapt.
    func resizeTerminal(cols: Int, rows: Int) {
        guard case .attached = state else { return }
        guard cols > 0, rows > 0 else { return }
        guard (cols, rows) != lastSentSize else { return }
        lastSentSize = (cols, rows)
        pendingInitialResize = false
        logger.info("Resizing terminal to \(cols)x\(rows)")
        let cmd = "refresh-client -C \(cols),\(rows)\n"
        Task {
            try? await sshService.writeToChannel(Data(cmd.utf8))
        }
    }

    // MARK: - tmux Session CRUD

    /// Create a new detached tmux session with the given name on the remote
    /// server. Uses the tmux control mode channel (execCommand doesn't work
    /// while a shell is active due to non-blocking mode).
    func createTmuxSession(name: String) async throws {
        guard case .attached = state else { return }
        let cmd = "new-session -d -s \(name.shellEscaped())\n"
        try await sshService.writeToChannel(Data(cmd.utf8))
        if !sessions.contains(where: { $0.name == name }) {
            sessions.append(TmuxSession(
                id: "", name: name, windows: [], createdAt: Date(), lastActivity: Date()
            ))
        }
    }

    /// Kill the specified tmux session on the remote server.
    /// Uses the tmux control mode channel.
    func deleteTmuxSession(_ session: TmuxSession) async throws {
        guard case .attached = state else { return }
        let cmd = "kill-session -t \(session.name.shellEscaped())\n"
        try await sshService.writeToChannel(Data(cmd.utf8))
        sessions.removeAll { $0.name == session.name }
    }

    // MARK: - Reconnect

    /// Attempt to re-establish a dropped SSH connection using exponential
    /// backoff.
    ///
    /// If the manager was attached to a tmux session before the disconnect,
    /// and that session still exists on the server, the manager automatically
    /// re-attaches.  Otherwise it tries the last-used session, then the first
    /// available session.  If no sessions exist, the state moves to
    /// `.disconnected`.
    ///
    /// After exhausting ``maxReconnectAttempts`` the state moves to
    /// `.disconnected`.
    func reconnect() async {
        guard state != .reconnecting else { return }
        guard let server = currentServer,
              let auth = cachedAuth else { return }

        let previousSessionName: String?
        if case .attached(let name) = state {
            previousSessionName = name
        } else {
            previousSessionName = nil
        }

        state = .reconnecting
        reconnectAttempt = 0

        for attempt in 1...maxReconnectAttempts {
            reconnectAttempt = attempt
            do {
                try await sshService.connect(
                    host: server.host,
                    port: server.port,
                    username: server.username,
                    auth: auth
                )

                try await refreshSessions()

                // Try to reattach: previous session > last-used > first available
                let serverID = server.id.uuidString
                let targetSession: String?

                if let name = previousSessionName,
                   sessions.contains(where: { $0.name == name }) {
                    targetSession = name
                } else if let lastUsed = lastSessionStore.lastSessionName(forServerID: serverID),
                          sessions.contains(where: { $0.name == lastUsed }) {
                    targetSession = lastUsed
                } else {
                    targetSession = sessions.first?.name
                }

                if let target = targetSession {
                    try await performAttach(sessionName: target)
                    lastSessionStore.save(sessionName: target, forServerID: serverID)
                } else {
                    // No sessions at all
                    state = .disconnected
                }

                reconnectAttempt = 0
                return
            } catch {
                if attempt < maxReconnectAttempts {
                    let delay = baseDelay * pow(2, Double(attempt - 1))
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
        }

        // All attempts exhausted.
        state = .disconnected
        reconnectAttempt = 0
    }

    // MARK: - Scrollback

    /// Fetch scrollback history for a pane from tmux.
    ///
    /// Sends `capture-pane -e -p -S -<lineCount>` to fetch history
    /// with ANSI color escapes. Returns the raw response string.
    ///
    /// - Parameters:
    ///   - paneId: The tmux pane ID (e.g., "%0").
    ///   - lineCount: Number of lines of history to request (default 500).
    /// - Returns: The captured scrollback content with ANSI escapes.
    func fetchScrollback(paneId: String, lineCount: Int = 500) async throws -> String {
        switch state {
        case .disconnected, .connecting, .reconnecting:
            throw ScrollbackError.notAttached
        case .attached:
            break
        }
        guard scrollbackContinuation == nil else {
            throw ScrollbackError.fetchInProgress
        }

        return try await withCheckedThrowingContinuation { continuation in
            scrollbackContinuation = continuation
            let cmd = "capture-pane -e -p -S -\(lineCount) -t \(paneId.shellEscaped())\n"
            Task {
                do {
                    try await sshServiceForWrites.writeToChannel(Data(cmd.utf8))
                    logger.info("Sent scrollback capture-pane for \(paneId)")
                } catch {
                    if let cont = self.scrollbackContinuation {
                        self.scrollbackContinuation = nil
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Deliver a scrollback capture-pane response from tmux.
    /// Called by ``onCommandResponse`` when a scrollback fetch is pending.
    func deliverScrollbackResponse(_ response: String) {
        guard let continuation = scrollbackContinuation else { return }
        scrollbackContinuation = nil
        continuation.resume(returning: response)
    }

    // MARK: - Auth Resolution

    /// Resolve the ``SSHAuth`` credentials for a server by looking up secrets
    /// in the Keychain.
    ///
    /// Shared by ``connect(server:password:)`` and ``reconnect()`` to avoid
    /// duplicating credential resolution logic.
    private func resolveAuth(for server: Server, password: String? = nil) throws -> SSHAuth {
        switch server.authMethod {
        case .password:
            let pw = try password ?? keychainService.retrievePassword(account: server.id.uuidString)
            return .password(pw)
        case .key(let keyId):
            let (_, keyData) = try keychainService.retrieveSSHKey(id: keyId)
            return .key(privateKey: keyData, passphrase: nil)
        }
    }

    // MARK: - tmux Version Check

    /// Verify that tmux is installed and meets the minimum version.
    /// Throws ``TmuxError`` if tmux is missing or too old.
    private func checkTmuxAvailability() async throws {
        let output: String
        do {
            output = try await sshService.execCommand("tmux -V")
        } catch {
            // execCommand failure (e.g. command not found exit code) → not installed.
            throw TmuxError.notInstalled
        }

        guard let version = TmuxError.parseTmuxVersion(output) else {
            throw TmuxError.notInstalled
        }

        if !TmuxError.versionMeetsMinimum(version) {
            throw TmuxError.versionTooOld(detected: version)
        }

        logger.info("tmux version \(version) detected")
    }

    // MARK: - Callback Wiring

    /// Connect ``TmuxControlService`` callbacks to pane buffer management.
    ///
    /// Called once at the start of ``attachSession(_:)`` so that tmux events
    /// flowing through the shell channel are dispatched to the correct
    /// ``TerminalBuffer`` instances.
    private func wireCallbacks() {
        tmuxService.onPaneOutput = { [weak self] paneId, data in
            self?.paneBuffers[paneId]?.feedData(data)
            if self?.scrolledBackPanes.contains(paneId) == true {
                self?.paneHasNewOutput.insert(paneId)
            }
        }

        tmuxService.onLayoutChange = { [weak self] windowId, panes in
            guard let self else { return }
            self.currentPanes = panes
            // Create TerminalBuffer for any new panes.
            var newPaneIds: [String] = []
            for pane in panes {
                let paneId = "%\(pane.paneId)"
                if self.paneBuffers[paneId] == nil {
                    self.paneBuffers[paneId] = TerminalBuffer(
                        cols: pane.width, rows: pane.height
                    )
                    newPaneIds.append(paneId)
                } else {
                    // Resize existing buffer if dimensions changed.
                    self.paneBuffers[paneId]?.resize(
                        cols: pane.width, rows: pane.height
                    )
                }
            }
            // Remove buffers for panes that no longer exist.
            let activePaneIds = Set(panes.map { "%\($0.paneId)" })
            for key in self.paneBuffers.keys where !activePaneIds.contains(key) {
                self.paneBuffers.removeValue(forKey: key)
            }
            // Request initial screen content for newly created panes —
            // but NOT during the initial attach sequence.  The first
            // layout-change arrives at the placeholder 80×24 size before
            // the view has measured its real dimensions; capturing at this
            // size fills the buffer with a prompt that becomes stale once
            // the real resize triggers a SIGWINCH redraw, producing a
            // visible "double prompt."  The flag is cleared by the first
            // resizeTerminal() call from the GeometryReader.
            if !self.pendingInitialResize {
                for paneId in newPaneIds {
                    self.capturePaneQueue.append(paneId)
                    let cmd = "capture-pane -e -p -t \(paneId.shellEscaped())\n"
                    Task {
                        try? await self.sshServiceForWrites.writeToChannel(Data(cmd.utf8))
                        self.logger.info("Sent capture-pane for \(paneId)")
                    }
                }
            } else {
                self.logger.info("Skipping capture-pane for \(newPaneIds) — pending initial resize")
            }
        }

        tmuxService.onCommandResponse = { [weak self] response in
            guard let self else { return }

            // If a scrollback fetch is pending, deliver the response to it.
            if self.scrollbackContinuation != nil {
                self.deliverScrollbackResponse(response)
                return
            }

            guard let paneId = self.capturePaneQueue.first else {
                self.logger.info("Command response with no pending capture-pane")
                return
            }
            self.capturePaneQueue.removeFirst()
            self.logger.info("capture-pane response for \(paneId): \(response.count) chars")
            if !response.isEmpty {
                self.paneBuffers[paneId]?.feed(response)
            }
        }

        tmuxService.onExit = { [weak self] in
            guard let self else { return }
            // Only reconnect if we were attached (not manually detaching).
            guard case .attached = self.state else { return }
            Task { await self.reconnect() }
        }

        tmuxService.onError = { [weak self] message in
            // Log error but don't disconnect -- tmux errors can be non-fatal.
            self?.logger.error("TmuxControl error: \(message)")
        }
    }

    /// Re-query the remote server for the current list of tmux sessions
    /// and update the ``sessions`` array.
    ///
    /// Only works when no shell channel is active (execCommand requires
    /// blocking mode). Called during connect() and reconnect() before
    /// performAttach(). Skipped silently when a shell is active.
    func refreshSessions() async throws {
        guard activeChannel == nil else {
            logger.info("Skipping refreshSessions — shell channel active")
            return
        }
        let output = try await sshService.execCommand(
            "tmux list-sessions -F '#{session_id}:#{session_name}:#{session_windows}:#{session_activity}'"
        )
        sessions = TmuxControlService.parseFormattedSessionList(output)
    }
}
