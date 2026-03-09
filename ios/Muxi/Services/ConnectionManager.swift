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

    /// The currently active (focused) pane ID, e.g. "%0".
    /// Managed directly by ConnectionManager to avoid SwiftUI onChange timing issues.
    var activePaneId: String?

    /// The SSH service (exposed for actor-routed channel writes).
    private var sshServiceForWrites: SSHServiceProtocol { sshService }

    // MARK: - Tmux Command Sending

    /// Send a tmux command through the control-mode channel and register
    /// its expected `%begin/%end` response type in the pending queue.
    private func sendControlCommand(_ command: String, type: PendingCommand) async throws {
        pendingCommands.append(type)
        try await sshServiceForWrites.writeToChannel(Data(command.utf8))
    }

    /// Send raw key data to a pane via `send-keys`.
    func sendKeysToPane(_ paneId: String, data: Data) async throws {
        let hexKeys = data.map { String(format: "0x%02x", $0) }.joined(separator: " ")
        let command = "send-keys -t \(paneId.shellEscaped()) \(hexKeys)\n"
        try await sendControlCommand(command, type: .ignored)
    }

    /// Paste text to a pane via `set-buffer` + `paste-buffer`.
    func pasteToPane(_ paneId: String, text: String) async throws {
        let escaped = text.tmuxQuoted()
        try await sendControlCommand(
            "set-buffer -b ios_paste -- \(escaped)\n", type: .ignored)
        try await sendControlCommand(
            "paste-buffer -b ios_paste -t \(paneId.shellEscaped()) -d\n", type: .ignored)
    }

    /// Send an arbitrary tmux command (quick actions, etc.).
    func sendTmuxCommand(_ command: String) async throws {
        try await sendControlCommand(command + "\n", type: .ignored)
    }

    /// The active SSH shell channel (for tmux control mode).
    private(set) var activeChannel: SSHChannel?

    /// Monitors SSH connection health and triggers reconnect on drop.
    private var sshMonitorTask: Task<Void, Never>?
    private var detachTask: Task<Void, Never>?

    /// Cached credentials from the last successful ``connect(server:password:)``
    /// call, reused by ``reconnect()`` so we do not need to hit the Keychain
    /// again when re-establishing a dropped connection.
    private var cachedAuth: SSHAuth?

    /// Tracks the type of each pending tmux command whose `%begin/%end`
    /// response has not yet arrived.  Every command sent through the
    /// control-mode channel generates a `%begin/%end` block; this queue
    /// tells ``onCommandResponse`` how to route each response.
    enum PendingCommand {
        /// `capture-pane -e -p -t %<id>` — feed response into pane buffer.
        case capturePane(paneId: String)
        /// `capture-pane -e -p -S -<N> -t %<id>` — deliver to scrollback continuation.
        case scrollbackCapture
        /// Any command whose response we don't need (send-keys, refresh-client, etc.).
        case ignored
    }
    private var pendingCommands: [PendingCommand] = []

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

    // MARK: - Host Key Verification (TOFU)

    /// The fingerprint awaiting user approval on first connection.
    /// Non-nil triggers the TOFU confirmation UI.
    var pendingFingerprint: String?

    /// Callback invoked with `true` (trust) or `false` (reject) after
    /// the user responds to the TOFU fingerprint prompt.
    var pendingFingerprintAction: ((Bool) -> Void)?

    /// Whether the fingerprint mismatch alert should be shown.
    var showFingerprintMismatchAlert = false

    /// The expected and actual fingerprints when a mismatch is detected.
    var mismatchFingerprint: (expected: String, actual: String)?

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
                auth: auth,
                expectedFingerprint: server.hostKeyFingerprint
            )
            logger.info("SSH connected, querying tmux sessions...")

            // Check tmux availability before querying sessions.
            try await checkTmuxAvailability()

            // Query tmux sessions. Use server-side timeout to guard against
            // a stuck tmux server socket (the command hangs if the tmux
            // server process is zombie/unresponsive).
            let output = try await sshService.execCommand(
                "timeout 5 tmux list-sessions -F '#{session_id}:#{session_name}:#{session_windows}:#{session_activity}' 2>/dev/null || true"
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
                // No sessions or tmux server was stuck — kill stale server and create fresh.
                logger.info("No sessions found, creating new session...")
                _ = try await sshService.execCommand("tmux kill-server 2>/dev/null; tmux new-session -d -s \("main".shellEscaped())")
                targetSession = "main"
                logger.info("Created new session: main")
                // Refresh to populate sessions array
                let refreshed = try await sshService.execCommand(
                    "tmux list-sessions -F '#{session_id}:#{session_name}:#{session_windows}:#{session_activity}' 2>/dev/null || true"
                )
                sessions = TmuxControlService.parseFormattedSessionList(refreshed)
            }

            try await performAttach(sessionName: targetSession)
            lastSessionStore.save(sessionName: targetSession, forServerID: serverID)

        } catch let error as SSHHostKeyError {
            try await handleHostKeyError(error, server: server, password: password)
        } catch {
            logger.error("Connection failed: \(error)")
            state = .disconnected
            currentServer = nil
            cachedAuth = nil
            throw error
        }
    }

    /// Handle host key verification errors during the connect flow.
    ///
    /// For first connections (TOFU), this suspends until the user accepts or
    /// rejects the fingerprint. For mismatches, it shows a warning alert and
    /// suspends similarly.
    private func handleHostKeyError(
        _ error: SSHHostKeyError,
        server: Server,
        password: String?
    ) async throws {
        switch error {
        case .fingerprintVerificationNeeded(let fingerprint):
            logger.info("First connection — awaiting user fingerprint verification")

            let accepted = await withCheckedContinuation { continuation in
                pendingFingerprint = fingerprint
                var resumed = false
                pendingFingerprintAction = { trusted in
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(returning: trusted)
                }
            }

            pendingFingerprint = nil
            pendingFingerprintAction = nil

            if accepted {
                // Save the trusted fingerprint and retry the connection.
                // SSHService.connect() internally calls performDisconnect()
                // when state != .disconnected, so no external disconnect needed.
                // DO NOT call sshService.disconnect() here — it fires an
                // unstructured Task that races with the reconnect.
                server.hostKeyFingerprint = fingerprint
                logger.info("User accepted fingerprint, retrying connection")
                state = .disconnected  // Reset so connect() guard passes
                try await connect(server: server, password: password)
            } else {
                logger.info("User rejected fingerprint")
                state = .disconnected
                currentServer = nil
                cachedAuth = nil
                throw SSHHostKeyError.fingerprintVerificationNeeded(fingerprint: fingerprint)
            }

        case .fingerprintMismatch(let expected, let actual):
            logger.warning("Host key mismatch detected — possible MITM attack")

            let accepted = await withCheckedContinuation { continuation in
                mismatchFingerprint = (expected: expected, actual: actual)
                showFingerprintMismatchAlert = true
                var resumed = false
                pendingFingerprintAction = { trusted in
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(returning: trusted)
                }
            }

            showFingerprintMismatchAlert = false
            mismatchFingerprint = nil
            pendingFingerprintAction = nil

            if accepted {
                // User accepted the new key — save it and retry.
                server.hostKeyFingerprint = actual
                logger.info("User accepted new fingerprint after mismatch warning")
                state = .disconnected  // Reset so connect() guard passes
                try await connect(server: server, password: password)
            } else {
                logger.info("User rejected mismatched fingerprint — disconnecting")
                state = .disconnected
                currentServer = nil
                cachedAuth = nil
                throw SSHHostKeyError.fingerprintMismatch(expected: expected, actual: actual)
            }

        case .hostKeyNotAvailable:
            logger.error("Host key not available after handshake")
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
        pendingCommands = []
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
            pendingCommands = []
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
            pendingCommands = []
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
        try await sendControlCommand("refresh-client -C 80,24\n", type: .ignored)

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
        guard currentSession != sessionName else { return }
        logger.info("Switching session: '\(currentSession)' → '\(sessionName)'")

        // Cancel any pending scrollback fetch to avoid leaking the continuation.
        if let continuation = scrollbackContinuation {
            scrollbackContinuation = nil
            continuation.resume(throwing: ScrollbackError.notAttached)
        }

        // Clear scrollback and active pane — onLayoutChange will set the new active pane.
        scrolledBackPanes = []
        paneHasNewOutput = []
        activePaneId = nil

        // Send switch-client followed by refresh-client to ensure the new
        // session's window is resized to match our terminal dimensions.
        try await sendControlCommand(
            "switch-client -t \(sessionName.shellEscaped())\n", type: .ignored)
        let (cols, rows) = lastSentSize
        if cols > 0, rows > 0 {
            try await sendControlCommand(
                "refresh-client -C \(cols),\(rows)\n", type: .ignored)
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
        logger.info("Creating new session '\(name)' via control channel")
        try await sendControlCommand(
            "new-session -d -s \(name.shellEscaped())\n", type: .ignored)

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
        Task {
            try? await self.sendControlCommand(
                "refresh-client -C \(cols),\(rows)\n", type: .ignored)
        }
    }

    // MARK: - tmux Session CRUD

    /// Create a new detached tmux session with the given name on the remote
    /// server. Uses the tmux control mode channel (execCommand doesn't work
    /// while a shell is active due to non-blocking mode).
    func createTmuxSession(name: String) async throws {
        guard case .attached = state else { return }
        try await sendControlCommand(
            "new-session -d -s \(name.shellEscaped())\n", type: .ignored)
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
        try await sendControlCommand(
            "kill-session -t \(session.name.shellEscaped())\n", type: .ignored)
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

        // Clean up stale references from the previous connection.
        // activeChannel must be nil so refreshSessions() can run
        // execCommand() (it guards on activeChannel == nil).
        // Without this, reconnect would skip the session query and
        // try to re-attach to a session that may no longer exist,
        // causing an infinite %exit → reconnect loop.
        sshMonitorTask?.cancel()
        sshMonitorTask = nil
        activeChannel = nil
        tmuxService.resetLineBuffer()

        for attempt in 1...maxReconnectAttempts {
            reconnectAttempt = attempt
            do {
                // Re-establish SSH connection using cached credentials.
                // Pass the stored fingerprint so we skip the TOFU prompt
                // during reconnect (the user already trusted this server).
                try await sshService.connect(
                    host: server.host,
                    port: server.port,
                    username: server.username,
                    auth: auth,
                    expectedFingerprint: server.hostKeyFingerprint
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
            Task {
                do {
                    try await self.sendControlCommand(
                        "capture-pane -e -p -S -\(lineCount) -t \(paneId.shellEscaped())\n",
                        type: .scrollbackCapture)
                    self.logger.info("Sent scrollback capture-pane for \(paneId)")
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
            let currentPaneIds = Set(panes.map { "%\($0.paneId)" })
            for key in self.paneBuffers.keys where !currentPaneIds.contains(key) {
                self.paneBuffers.removeValue(forKey: key)
            }
            // Update activePaneId: if the current active pane is gone, pick the first new one.
            if let active = self.activePaneId, !currentPaneIds.contains(active) {
                self.activePaneId = panes.first.map { "%\($0.paneId)" }
            } else if self.activePaneId == nil, let first = panes.first {
                self.activePaneId = "%\(first.paneId)"
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
                    Task {
                        try? await self.sendControlCommand(
                            "capture-pane -e -p -t \(paneId.shellEscaped())\n",
                            type: .capturePane(paneId: paneId))
                    }
                }
            }
        }

        tmuxService.onCommandResponse = { [weak self] response in
            guard let self else { return }
            guard let pending = self.pendingCommands.first else {
                self.logger.info("Unexpected command response (\(response.count) chars)")
                return
            }
            self.pendingCommands.removeFirst()

            switch pending {
            case .capturePane(let paneId):
                if !response.isEmpty, let oldBuffer = self.paneBuffers[paneId] {
                    // Replace with a fresh buffer to avoid mixing with
                    // %output data that arrived between buffer creation
                    // and this capture-pane response.
                    let fresh = TerminalBuffer(cols: oldBuffer.cols, rows: oldBuffer.rows)
                    // capture-pane -e -p uses bare \n between lines, but the
                    // VT parser's \n only increments cursor_row (no CR).
                    // Normalize to \r\n so each line starts at column 0.
                    let normalized = response.replacingOccurrences(of: "\n", with: "\r\n")
                    fresh.feed(normalized)
                    self.paneBuffers[paneId] = fresh
                }
            case .scrollbackCapture:
                self.deliverScrollbackResponse(response)
            case .ignored:
                break
            }
        }

        tmuxService.onSessionChanged = { [weak self] sessionId, name in
            guard let self else { return }
            self.logger.info("Session changed to '\(name)' (\(sessionId))")
            self.state = .attached(sessionName: name)
            // Save as last-used session.
            if let serverID = self.currentServer?.id.uuidString {
                self.lastSessionStore.save(sessionName: name, forServerID: serverID)
            }
            // refresh-client is sent in switchSession() right after switch-client,
            // so no need to send it again here.
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
            "timeout 5 tmux list-sessions -F '#{session_id}:#{session_name}:#{session_windows}:#{session_activity}' 2>/dev/null || true"
        )
        sessions = TmuxControlService.parseFormattedSessionList(output)
    }
}
