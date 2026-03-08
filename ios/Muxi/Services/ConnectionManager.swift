import Foundation
import os

// MARK: - ConnectionState

/// Represents the high-level state of a ``ConnectionManager`` session.
///
/// The typical lifecycle progresses:
///   `.disconnected` -> `.connecting` -> `.sessionList` -> `.attached`
///
/// `.reconnecting` is reserved for future automatic reconnect logic.
enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case sessionList
    case attached(sessionName: String)
    case reconnecting
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

    /// The current connection state.
    private(set) var state: ConnectionState = .disconnected

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

    /// Cached credentials from the last successful ``connect(server:password:)``
    /// call, reused by ``reconnect()`` so we do not need to hit the Keychain
    /// again when re-establishing a dropped connection.
    private var cachedAuth: SSHAuth?

    /// Queue of pane IDs waiting for ``capture-pane`` response.
    /// Each ``capture-pane -e -p -t %<id>`` triggers a %begin/%end block;
    /// responses are matched to panes in FIFO order.
    private var capturePaneQueue: [String] = []

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
        maxReconnectAttempts: Int = 5,
        baseDelay: TimeInterval = 1.0
    ) {
        self.sshService = sshService ?? SSHService()
        self.maxReconnectAttempts = maxReconnectAttempts
        self.baseDelay = baseDelay
    }

    // MARK: - Connect

    /// Establish an SSH connection to the given server and query its tmux
    /// sessions.
    ///
    /// - Parameters:
    ///   - server: The server profile to connect to.
    ///   - password: An optional password.  When `nil` and the server's
    ///     ``AuthMethod`` is `.password`, the password is retrieved from the
    ///     Keychain.
    /// - Returns: The list of tmux sessions found on the server.
    func connect(server: Server, password: String? = nil) async throws -> [TmuxSession] {
        guard state == .disconnected else { return sessions }
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

            // Query tmux sessions via a formatted list-sessions command.
            let output = try await sshService.execCommand(
                "tmux list-sessions -F '#{session_id}:#{session_name}:#{session_windows}:#{session_activity}'"
            )
            sessions = TmuxControlService.parseFormattedSessionList(output)
            logger.info("Found \(self.sessions.count) tmux sessions")
            state = .sessionList
            return sessions
        } catch let error as SSHHostKeyError {
            try await handleHostKeyError(error, server: server, password: password)
            return sessions
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
                pendingFingerprintAction = { trusted in
                    continuation.resume(returning: trusted)
                }
            }

            pendingFingerprint = nil
            pendingFingerprintAction = nil

            if accepted {
                // Save the trusted fingerprint and retry the connection.
                server.hostKeyFingerprint = fingerprint
                logger.info("User accepted fingerprint, retrying connection")
                state = .disconnected  // Reset so connect() guard passes
                _ = try await connect(server: server, password: password)
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
                pendingFingerprintAction = { trusted in
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
                _ = try await connect(server: server, password: password)
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
        capturePaneQueue = []
        lastSentSize = (0, 0)
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

            // Send detach THEN disconnect — ordering guaranteed within same Task.
            // Without this, disconnect() could tear down the channel before detach is sent.
            Task {
                try? await sshService.writeToChannel(Data("detach\n".utf8))
                sshService.disconnect()
            }
        } else if state == .sessionList || state == .connecting {
            lastBackgroundServer = currentServer
            lastBackgroundSession = nil
            disconnectedByBackground = true

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

        guard let server = lastBackgroundServer ?? currentServer,
              cachedAuth != nil else {
            lastBackgroundServer = nil
            lastBackgroundSession = nil
            return
        }

        // Restore state needed by reconnect().
        currentServer = server
        let sessionName = lastBackgroundSession

        if let sessionName {
            state = .attached(sessionName: sessionName)
        } else {
            state = .sessionList
        }

        lastBackgroundServer = nil
        lastBackgroundSession = nil

        Task {
            await reconnect()
        }
    }

    // MARK: - Session Management

    /// Attach to a tmux session by name.
    ///
    /// Opens an interactive SSH shell channel running
    /// `tmux -CC attach -t <name>` and pipes output through
    /// ``TmuxControlService/feed(_:)``.
    func attachSession(_ session: TmuxSession) async throws {
        guard state == .sessionList else {
            logger.warning("attachSession called but state is not .sessionList (state=\(String(describing: self.state)))")
            return
        }
        logger.info("Attaching to session: \(session.name)")

        // Wire tmux callbacks before starting the shell.
        wireCallbacks()

        // Start an interactive shell, feeding data to the tmux parser.
        logger.info("Starting SSH shell...")
        let channel = try await sshService.startShell(onData: { [weak self] data in
            Task { @MainActor in
                self?.tmuxService.feed(data)
            }
        })
        logger.info("Shell started, sending tmux -CC attach command...")

        activeChannel = channel

        // Send tmux -CC attach command through the shell (actor-routed).
        let command = "tmux -CC attach -t \(session.name.shellEscaped())\n"
        try await sshService.writeToChannel(Data(command.utf8))
        logger.info("tmux attach command sent, transitioning to .attached")

        state = .attached(sessionName: session.name)

        // Send a small initial size to trigger %layout-change.
        // The TerminalSessionView will send the correct size once
        // it knows its actual dimensions via GeometryReader.
        let refreshCmd = "refresh-client -C 80,24\n"
        try await sshService.writeToChannel(Data(refreshCmd.utf8))
        logger.info("Sent initial refresh-client, awaiting view-based resize")

        // Monitor SSH connection — trigger reconnect if the read loop
        // ends without a tmux %exit (e.g. network drop).
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

    /// Detach from the current tmux session, returning to the session list.
    func detach() {
        sshMonitorTask?.cancel()
        sshMonitorTask = nil
        // Send detach command if channel is active (actor-routed).
        Task {
            try? await sshService.writeToChannel(Data("detach\n".utf8))
        }
        activeChannel = nil  // Don't close — SSHService owns the channel lifecycle
        tmuxService.resetLineBuffer()
        paneBuffers = [:]
        currentPanes = []
        state = .sessionList
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
        logger.info("Resizing terminal to \(cols)x\(rows)")
        let cmd = "refresh-client -C \(cols),\(rows)\n"
        Task {
            try? await sshService.writeToChannel(Data(cmd.utf8))
        }
    }

    // MARK: - tmux Session CRUD

    /// Create a new detached tmux session with the given name on the remote
    /// server, then refresh the session list.
    func createTmuxSession(name: String) async throws {
        guard state == .sessionList else { return }
        _ = try await sshService.execCommand("tmux new-session -d -s \(name.shellEscaped())")
        try await refreshSessions()
    }

    /// Kill the specified tmux session on the remote server, then refresh
    /// the session list.
    func deleteTmuxSession(_ session: TmuxSession) async throws {
        guard state == .sessionList else { return }
        _ = try await sshService.execCommand("tmux kill-session -t \(session.name.shellEscaped())")
        try await refreshSessions()
    }

    // MARK: - Reconnect

    /// Attempt to re-establish a dropped SSH connection using exponential
    /// backoff.
    ///
    /// If the manager was attached to a tmux session before the disconnect,
    /// and that session still exists on the server, the manager automatically
    /// re-attaches.  Otherwise it falls back to `.sessionList`.
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

                // Refresh the session list from the server.
                try await refreshSessions()

                // Re-attach if we were attached before and the session still
                // exists on the server.
                if let sessionName = previousSessionName,
                   let session = sessions.first(where: { $0.name == sessionName }) {
                    // Temporarily move to sessionList so attachSession's
                    // guard passes, then attempt to re-attach.
                    state = .sessionList
                    do {
                        try await attachSession(session)
                    } catch {
                        // Shell/attach failed but SSH is connected; stay on session list.
                        state = .sessionList
                    }
                } else {
                    state = .sessionList
                }

                reconnectAttempt = 0
                return // Success
            } catch {
                // Exponential backoff before next attempt.
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
            // Request initial screen content for newly created panes.
            // capture-pane -e includes ANSI escapes, -p prints to stdout
            // which tmux returns inside a %begin/%end block.
            for paneId in newPaneIds {
                self.capturePaneQueue.append(paneId)
                let cmd = "capture-pane -e -p -t \(paneId.shellEscaped())\n"
                Task {
                    try? await self.sshServiceForWrites.writeToChannel(Data(cmd.utf8))
                    self.logger.info("Sent capture-pane for \(paneId)")
                }
            }
        }

        tmuxService.onCommandResponse = { [weak self] response in
            guard let self else { return }
            guard let paneId = self.capturePaneQueue.first else {
                self.logger.info("Command response with no pending capture-pane")
                return
            }
            self.capturePaneQueue.removeFirst()
            self.logger.info("capture-pane response for \(paneId): \(response.count) chars")
            // Feed the captured content (with ANSI escapes) into the buffer.
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
    func refreshSessions() async throws {
        let output = try await sshService.execCommand(
            "tmux list-sessions -F '#{session_id}:#{session_name}:#{session_windows}:#{session_activity}'"
        )
        sessions = TmuxControlService.parseFormattedSessionList(output)
    }
}
