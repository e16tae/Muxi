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
    private let tailscaleService = TailscaleService()

    /// Current Tailscale node state, observable by UI.
    private(set) var tailscaleState: TailscaleState = .disconnected

    /// The current connection state.
    private(set) var state: ConnectionState = .disconnected

    /// Debug: shows which step of the connection process is active.
    private(set) var connectingStatus: String = ""

    #if DEBUG
    /// Test-only: override the connection state for unit tests.
    func setStateForTesting(_ newState: ConnectionState) {
        state = newState
    }

    /// Test-only: trigger the onExit callback as if tmux sent `%exit`.
    func simulateOnExit() {
        tmuxService.onExit?()
    }

    /// Test-only: override the sessions array for unit tests.
    func setSessionsForTesting(_ newSessions: [TmuxSession]) {
        sessions = newSessions
    }

    func setWindowsForTesting(
        _ windows: [Window],
        activeId: WindowID? = nil,
        activePaneId: PaneID? = nil
    ) {
        currentWindows = windows
        if let activeId {
            let resolvedPaneId = activePaneId
                ?? windows.first(where: { $0.id == activeId })?.paneIds.first
                ?? PaneID("%0")
            windowPaneState = .active(
                WindowPaneState.ActiveState(
                    windowId: activeId,
                    panes: [],
                    activePaneId: resolvedPaneId,
                    isZoomed: false
                )
            )
        }
    }

    func setPaneBuffersForTesting(_ buffers: [PaneID: TerminalBuffer]) {
        paneBuffers = buffers
    }

    /// Test-only: wire up tmux callbacks so `simulateLayoutChange` works.
    func wireCallbacksForTesting() {
        wireCallbacks()
    }

    /// Test-only: simulate a `%layout-change` callback as if tmux sent it.
    func simulateLayoutChange(windowId: WindowID, panes: [Pane], isZoomed: Bool = false) {
        tmuxService.onLayoutChange?(windowId, panes, isZoomed)
    }

    /// Test-only: simulate a `%window-pane-changed` callback.
    func simulateWindowPaneChanged(windowId: WindowID, paneId: PaneID) {
        tmuxService.onWindowPaneChanged?(windowId, paneId)
    }

    /// Test-only: simulate a `%session-window-changed` callback.
    func simulateSessionWindowChanged(windowId: WindowID) {
        tmuxService.onSessionWindowChanged?(windowId)
    }

    #endif

    /// The server we are currently connected (or connecting) to.
    private(set) var currentServer: Server?

    /// The list of tmux sessions discovered on the remote server.
    private(set) var sessions: [TmuxSession] = []

    /// Per-pane terminal buffers, keyed by tmux pane ID.
    private(set) var paneBuffers: [PaneID: TerminalBuffer] = [:]

    /// Windows in the current session, tracked via tmux notifications.
    private(set) var currentWindows: [Window] = []

    // MARK: - Window/Pane State Machine

    /// Unified state for window/pane layout lifecycle.
    /// Replaces the former scattered properties (currentPanes, activePaneId,
    /// activeWindowId, switchingToWindowId, isZoomed, pendingAutoZoom).
    private(set) var windowPaneState: WindowPaneState = .awaitingLayout

    /// Current pane layout from tmux (computed from state machine).
    var currentPanes: [Pane] {
        switch windowPaneState {
        case .awaitingLayout, .switchingWindow:
            return []
        case .active(let s):
            return s.panes
        case .autoZooming:
            return []
        }
    }

    /// The currently active (focused) pane ID (computed from state machine).
    var activePaneId: PaneID? {
        get {
            switch windowPaneState {
            case .awaitingLayout:
                return nil
            case .active(let s):
                return s.activePaneId
            case .switchingWindow(let s):
                return s.optimisticPaneId
            case .autoZooming(let s):
                return s.activePaneId
            }
        }
        set {
            // Only allow setting in .active state
            if case .active(var s) = windowPaneState, let newId = newValue {
                s.activePaneId = newId
                windowPaneState = .active(s)
            }
        }
    }

    /// The currently active window ID (computed from state machine).
    var activeWindowId: WindowID? {
        switch windowPaneState {
        case .awaitingLayout:
            return nil
        case .active(let s):
            return s.windowId
        case .switchingWindow(let s):
            return s.targetWindowId
        case .autoZooming(let s):
            return s.windowId
        }
    }

    /// Whether the active pane is currently zoomed (computed from state machine).
    var isZoomed: Bool {
        if case .active(let s) = windowPaneState {
            return s.isZoomed
        }
        return false
    }

    /// Set during a window switch; cleared when the matching `%layout-change` arrives.
    var switchingToWindowId: WindowID? {
        if case .switchingWindow(let s) = windowPaneState {
            return s.targetWindowId
        }
        return nil
    }

    /// When true, auto-zoom fires on any unzoomed multi-pane layout.
    /// Set by the view layer based on horizontalSizeClass.
    var mobileAutoZoom: Bool = false {
        didSet {
            guard mobileAutoZoom, !oldValue else { return }
            guard case .active(let s) = windowPaneState,
                  !s.isZoomed, s.panes.count > 1 else { return }
            logger.debug("Proactive auto-zoom: mobileAutoZoom set with \(s.panes.count) panes")
            transitionToAutoZooming(from: s)
        }
    }

    /// Timeout task that clears auto-zoom state if zoomed `%layout-change`
    /// never arrives (command failure, network delay).
    private var autoZoomTimeoutTask: Task<Void, Never>?

    /// Debounced task that sends `list-panes` to refresh pill pane IDs.
    /// Needed when zoomed — `visible_layout` only shows the zoomed pane,
    /// so `%layout-change` alone can't update the full pane list.
    private var paneRefreshTask: Task<Void, Never>?

    #if DEBUG
    /// Test-only: check if currently in auto-zooming state.
    var pendingAutoZoomForTesting: Bool {
        if case .autoZooming = windowPaneState { return true }
        return false
    }
    #endif

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
    ///
    /// Non-ASCII data (Korean, CJK, emoji, etc.) uses `send-keys -l` (literal
    /// mode) so tmux transmits the complete character.  Hex mode (`0xXX`) sends
    /// individual bytes, which remote shells misinterpret as separate Latin-1
    /// characters when UTF-8 locale isn't configured.
    func sendKeysToPane(_ paneId: PaneID, data: Data) async throws {
        let command: String
        if data.contains(where: { $0 >= 0x80 }),
           let text = String(data: data, encoding: .utf8) {
            command = "send-keys -t \(paneId.rawValue.shellEscaped()) -l \(text.tmuxQuoted())\n"
        } else {
            let hexKeys = data.map { String(format: "0x%02x", $0) }.joined(separator: " ")
            command = "send-keys -t \(paneId.rawValue.shellEscaped()) \(hexKeys)\n"
        }
        try await sendControlCommand(command, type: .ignored)
    }

    /// Paste text to a pane via `set-buffer` + `paste-buffer`.
    func pasteToPane(_ paneId: PaneID, text: String) async throws {
        let escaped = text.tmuxQuoted()
        try await sendControlCommand(
            "set-buffer -b ios_paste -- \(escaped)\n", type: .ignored)
        try await sendControlCommand(
            "paste-buffer -b ios_paste -t \(paneId.rawValue.shellEscaped()) -d\n", type: .ignored)
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
        case capturePane(paneId: PaneID)
        /// `display-message -p -t %<id> '#{cursor_x}:#{cursor_y}'` — sync cursor after capture-pane.
        case cursorQuery(paneId: PaneID)
        /// `capture-pane -e -p -S -<N> -t %<id>` — deliver to scrollback continuation.
        case scrollbackCapture
        /// `list-sessions -F '...'` — refresh the session list.
        case listSessions
        /// `new-session -d -P -F '#{session_name}'` — parse created session name and switch to it.
        case createSession
        /// `list-windows -F '...'` — refresh the window list.
        case listWindows
        /// `list-panes -a -F '...'` — refresh pane-to-window mapping for all windows.
        case listPanes
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
    var scrolledBackPanes: Set<PaneID> = []

    /// Panes that received new output while in scrollback mode.
    var paneHasNewOutput: Set<PaneID> = []

    /// Captures the connection state at the moment the app enters background,
    /// so `handleForeground()` can auto-reconnect to the same server/session.
    private var backgroundState: BackgroundState = .none

    private enum BackgroundState {
        case none
        case awaitingReconnect(server: Server, session: String?)
    }

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

            // Determine SSH target: direct or via Tailscale local proxy
            var sshHost = server.host
            var sshPort = server.port

            if server.useTailscale {
                guard tailscaleState == .connected else {
                    logger.error("Tailscale not connected — cannot connect to server \(server.host)")
                    state = .disconnected
                    currentServer = nil
                    throw TailscaleError.notConnected
                }
                connectingStatus = "Tailscale dial..."
                let localPort = try await tailscaleService.dial(host: server.host, port: server.port)
                sshHost = "127.0.0.1"
                sshPort = localPort
                logger.info("Tailscale proxy: \(server.host):\(server.port) → 127.0.0.1:\(localPort)")
            }

            connectingStatus = "SSH handshake..."
            try await sshService.connect(
                host: sshHost,
                port: sshPort,
                username: server.username,
                auth: auth,
                expectedFingerprint: server.hostKeyFingerprint
            )
            connectingStatus = "SSH OK. tmux check..."
            logger.info("SSH connected, querying tmux sessions...")

            // Skip exec-based tmux check for Tailscale connections —
            // exec channels have latency issues through the local TCP proxy.
            // The shell channel (used by tmux -CC attach) works reliably.
            if !server.useTailscale {
                // Check tmux availability before querying sessions.
                try await checkTmuxAvailability()
            }

            let serverID = server.id.uuidString
            let targetSession: String

            if server.useTailscale {
                // Tailscale path: skip exec-based session listing (exec channels
                // have issues through the local TCP proxy). Use shell command:
                // "tmux -CC attach || tmux -CC new-session"
                // → attaches to most recent session if any exist, creates new if none.
                connectingStatus = "tmux attach..."
                targetSession = ""  // empty = use attach||new-session shell fallback
                logger.info("Tailscale: attach-or-create via shell fallback (skip exec)")
            } else {
                // Direct path: query tmux sessions via exec channel.
                let output = try await sshService.execCommand(
                    "timeout 5 tmux list-sessions -F '#{session_id}:#{session_name}:#{session_windows}:#{session_activity}' 2>/dev/null || true"
                )
                sessions = TmuxControlService.parseFormattedSessionList(output)
                logger.info("Found \(self.sessions.count) tmux sessions")

                if let lastUsed = lastSessionStore.lastSessionName(forServerID: serverID),
                   sessions.contains(where: { $0.name == lastUsed }) {
                    targetSession = lastUsed
                    logger.info("Resuming last-used session: \(lastUsed)")
                } else if let first = sessions.first {
                    targetSession = first.name
                    logger.info("Attaching to first session: \(targetSession)")
                } else {
                    logger.info("No sessions found, creating new session...")
                    let newSessionOutput = try await sshService.execCommand(
                        "tmux kill-server 2>/dev/null; tmux new-session -d -P -F '#{session_name}'"
                    )
                    targetSession = newSessionOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                    logger.info("Created new session: \(targetSession)")
                    let refreshed = try await sshService.execCommand(
                        "tmux list-sessions -F '#{session_id}:#{session_name}:#{session_windows}:#{session_activity}' 2>/dev/null || true"
                    )
                    sessions = TmuxControlService.parseFormattedSessionList(refreshed)
                }
            }

            try await performAttach(sessionName: targetSession, attachOrCreate: server.useTailscale)
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

    // MARK: - Tailscale Lifecycle

    /// Start the embedded Tailscale node.
    func startTailscale(controlURL: String, authKey: String, hostname: String) async {
        do {
            tailscaleState = .connecting
            try await tailscaleService.start(controlURL: controlURL, authKey: authKey, hostname: hostname)
            tailscaleState = .connected
            logger.info("Tailscale connected")
        } catch {
            tailscaleState = .error(error.localizedDescription)
            logger.error("Tailscale start failed: \(error)")
        }
    }

    /// Stop the embedded Tailscale node.
    func stopTailscale() async {
        await tailscaleService.stop()
        tailscaleState = .disconnected
        logger.info("Tailscale disconnected")
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
        sshService.disconnect()
        state = .disconnected
        currentServer = nil
        sessions = []
        cachedAuth = nil
        pendingCommands = []
        lastSentSize = (0, 0)
        pendingInitialResize = false

        currentWindows = []
        resetWindowPaneState()

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
            guard let server = currentServer else { return }
            backgroundState = .awaitingReconnect(server: server, session: sessionName)

            // Cancel monitor to prevent it from detecting our disconnect
            // and triggering its own reconnect.
            sshMonitorTask?.cancel()
            sshMonitorTask = nil

            // Clear UI state immediately (keep currentServer and cachedAuth for reconnect).
            activeChannel = nil
            tmuxService.resetLineBuffer()
            paneBuffers = [:]
            resetWindowPaneState()
            currentWindows = []
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
            guard let server = currentServer else { return }
            backgroundState = .awaitingReconnect(server: server, session: nil)

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
        guard case .awaitingReconnect(let server, let sessionName) = backgroundState else { return }
        backgroundState = .none

        // Re-query Keychain for credentials cleared during background.
        if cachedAuth == nil {
            do {
                cachedAuth = try resolveAuth(for: server)
            } catch {
                // User didn't save password — can't auto-reconnect.
                logger.info("Cannot re-query credentials from Keychain: \(error.localizedDescription)")
                state = .disconnected
                return
            }
        }

        // Restore state needed by reconnect().
        currentServer = server

        guard let sessionName else {
            // Was connecting/transitioning — just disconnect cleanly.
            return
        }

        state = .attached(sessionName: sessionName)

        Task {
            await reconnect()
        }
    }

    // MARK: - Session Management

    /// Core attach logic: wire callbacks, open shell, send tmux -CC attach.
    /// Callers must ensure previous channel is cleaned up before calling.
    private func performAttach(sessionName: String, attachOrCreate: Bool = false) async throws {
        wireCallbacks()

        let channel = try await sshService.startShell(onData: { [weak self] data in
            Task { @MainActor in
                self?.tmuxService.feed(data)
            }
        })
        activeChannel = channel

        let command: String
        if attachOrCreate {
            // Attach to most recent session, or create new if none exist.
            // No exec channel needed — works entirely through the shell.
            command = "tmux -CC attach 2>/dev/null || tmux -CC new-session\n"
        } else {
            command = "tmux -CC attach -t \(sessionName.shellEscaped())\n"
        }
        try await sshService.writeToChannel(Data(command.utf8))
        state = .attached(sessionName: sessionName)

        pendingInitialResize = true
        try await sendControlCommand("refresh-client -C 80,24\n", type: .ignored)

        // Tell tmux to switch to another session when the current one
        // is destroyed (e.g. user types `exit`) instead of detaching
        // the client.  This makes session exits seamless — tmux sends
        // %session-changed instead of %exit, so we stay attached.
        // %exit only fires when no sessions remain.
        try await sendControlCommand(
            "set-option -g detach-on-destroy off\n", type: .ignored)

        // Request window list so the toolbar can show window pills.
        requestWindowListRefresh()

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

        // Clear scrollback — onSessionChanged will reset windowPaneState.
        scrolledBackPanes = []
        paneHasNewOutput = []

        // Send only switch-client — onSessionChanged will send
        // refresh-client to trigger %layout-change for the new session.
        // Sending refresh-client here too causes a redundant SIGWINCH
        // that accumulates extra prompt lines in the pane buffer.
        try await sendControlCommand(
            "switch-client -t \(sessionName.shellEscaped())\n", type: .ignored)
    }

    /// Create a new tmux session and switch to it.
    ///
    /// When a shell is active (non-blocking mode), `execCommand` cannot open
    /// new channels. Instead, the create command is sent through the tmux
    /// control mode channel, and the session list is updated locally.
    func createAndSwitchToNewSession(name: String? = nil) async throws {
        guard case .attached = state else { return }

        if let name {
            // Custom name: create and switch immediately (name is known).
            logger.info("Creating new session '\(name)' via control channel")
            try await sendControlCommand(
                "new-session -d -s \(name.shellEscaped())\n", type: .ignored)
            if !sessions.contains(where: { $0.name == name }) {
                sessions.append(TmuxSession(
                    id: SessionID(""), name: name, windows: [], createdAt: Date(), lastActivity: Date()
                ))
            }
            try await switchSession(to: name)
        } else {
            // No name: let tmux assign the next number.
            // The response (via .createSession) contains the assigned name
            // and triggers switchSession automatically.
            logger.info("Creating new session with tmux default name")
            try await sendControlCommand(
                "new-session -d -P -F '#{session_name}'\n", type: .createSession)
        }
    }

    // MARK: - Window/Session Commands

    /// Switch to a specific window by ID.
    /// Optimistically updates local state and clears panes to show placeholder.
    func selectWindow(_ windowId: WindowID) async throws {
        guard case .attached = state else { return }
        guard windowId != activeWindowId else { return }

        prepareWindowSwitch(to: windowId)
        try await sendControlCommand(
            "select-window -t \(windowId.rawValue.shellEscaped())\n", type: .ignored)
        try await forceLayoutRefresh()
    }

    /// Switch to a specific window and pane.
    /// If the target is in a different window, applies optimistic update (clears panes).
    /// If the target is in the same window, only switches the active pane.
    func selectWindowAndPane(windowId: WindowID, paneId: PaneID) async throws {
        guard case .attached = state else { return }

        if windowId != activeWindowId {
            windowPaneState = .switchingWindow(
                WindowPaneState.SwitchingState(
                    targetWindowId: windowId,
                    optimisticPaneId: paneId
                )
            )
            autoZoomTimeoutTask?.cancel()
            paneRefreshTask?.cancel()
            scrolledBackPanes = []
            paneHasNewOutput = []
            try await sendControlCommand(
                "select-window -t \(windowId.rawValue.shellEscaped())\n", type: .ignored)
            try await sendControlCommand(
                "select-pane -t \(paneId.rawValue.shellEscaped())\n", type: .ignored)
            try await forceLayoutRefresh()
        } else {
            // Same-window pane switch.
            // -Z preserves zoom state (tmux 3.1+), avoiding the
            // unzoom→re-zoom dance that caused intermediate layout flicker.
            guard paneId != activePaneId else { return }
            activePaneId = paneId
            try await sendControlCommand(
                "select-pane -t \(paneId.rawValue.shellEscaped()) -Z\n", type: .ignored)
        }
    }

    // MARK: - Window Switch Helpers

    /// Optimistically reset local state for a cross-window switch.
    private func prepareWindowSwitch(to windowId: WindowID) {
        windowPaneState = .switchingWindow(
            WindowPaneState.SwitchingState(targetWindowId: windowId)
        )
        autoZoomTimeoutTask?.cancel()
        paneRefreshTask?.cancel()
        scrolledBackPanes = []
        paneHasNewOutput = []
    }

    /// Transition from active to auto-zooming state.
    private func transitionToAutoZooming(from activeState: WindowPaneState.ActiveState) {
        windowPaneState = .autoZooming(
            WindowPaneState.AutoZoomState(
                windowId: activeState.windowId,
                unzoomedPanes: activeState.panes,
                activePaneId: activeState.activePaneId
            )
        )
        Task {
            try? await self.sendControlCommand("resize-pane -Z\n", type: .ignored)
        }
        autoZoomTimeoutTask?.cancel()
        autoZoomTimeoutTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if case .autoZooming(let s) = self.windowPaneState {
                self.applyLayout(
                    windowId: s.windowId,
                    panes: s.unzoomedPanes,
                    activePaneId: s.activePaneId,
                    isZoomed: false
                )
            }
        }
    }

    /// Reset window/pane state to awaitingLayout.
    /// Called during disconnect, session switch, and reconnect.
    private func resetWindowPaneState() {
        windowPaneState = .awaitingLayout
        autoZoomTimeoutTask?.cancel()
        paneRefreshTask?.cancel()
        scrolledBackPanes = []
        paneHasNewOutput = []
    }

    /// Handle a `%layout-change` notification from tmux.
    /// Routes through the state machine to determine the correct action.
    private func handleLayoutChange(windowId: WindowID, panes: [Pane], isZoomed: Bool) {
        switch windowPaneState {
        case .switchingWindow(let s):
            // During a window switch, ignore layout-change from non-target windows.
            guard windowId == s.targetWindowId else { return }
            // Target window's layout arrived — resolve the transition.
            let activePaneId = s.optimisticPaneId ?? panes.first?.id
            guard let activePaneId else { return }
            applyLayout(windowId: windowId, panes: panes, activePaneId: activePaneId, isZoomed: isZoomed)

        case .autoZooming(let s):
            guard windowId == s.windowId else { return }
            if isZoomed {
                // Zoomed layout arrived — transition to active.
                autoZoomTimeoutTask?.cancel()
                applyLayout(windowId: windowId, panes: panes, activePaneId: s.activePaneId, isZoomed: true)
            }
            // Ignore unzoomed layouts while auto-zooming (waiting for zoom to take effect).

        case .awaitingLayout:
            // First layout-change after attach — transition to active.
            guard let firstPaneId = panes.first?.id else { return }
            applyLayout(windowId: windowId, panes: panes, activePaneId: firstPaneId, isZoomed: isZoomed)

        case .active(let s):
            // Only process layout for the active window (or initial nil).
            guard windowId == s.windowId else {
                // Non-active window: update its pane IDs (but not when zoomed).
                if !isZoomed,
                   let idx = currentWindows.firstIndex(where: { $0.id == windowId }) {
                    currentWindows[idx].paneIds = panes.map(\.id)
                }
                return
            }

            // Auto-zoom: suppress intermediate unzoomed layout on mobile.
            if mobileAutoZoom && !isZoomed && panes.count > 1 {
                // Update window metadata only (pills need pane IDs).
                for i in currentWindows.indices {
                    currentWindows[i].isActive = (currentWindows[i].id == windowId)
                }
                if let idx = currentWindows.firstIndex(where: { $0.id == windowId }) {
                    currentWindows[idx].paneIds = panes.map(\.id)
                }
                transitionToAutoZooming(from: WindowPaneState.ActiveState(
                    windowId: windowId,
                    panes: panes,
                    activePaneId: s.activePaneId,
                    isZoomed: false
                ))
                return
            }

            // Clear auto-zoom timeout when zoomed layout arrives.
            if isZoomed {
                logger.debug("Zoomed layout arrived, clearing auto-zoom timeout")
                autoZoomTimeoutTask?.cancel()
            }

            // Normal layout update.
            applyLayout(windowId: windowId, panes: panes, activePaneId: s.activePaneId, isZoomed: isZoomed)
        }
    }

    /// Apply a layout to the state machine and update pane buffers.
    /// Common path for all state transitions that result in `.active`.
    private func applyLayout(windowId: WindowID, panes: [Pane], activePaneId: PaneID, isZoomed: Bool) {
        // Resolve the active pane: if the requested one is gone, pick the first.
        let paneIds = Set(panes.map(\.id))
        let resolvedActivePaneId = paneIds.contains(activePaneId)
            ? activePaneId
            : (panes.first?.id ?? activePaneId)

        windowPaneState = .active(
            WindowPaneState.ActiveState(
                windowId: windowId,
                panes: panes,
                activePaneId: resolvedActivePaneId,
                isZoomed: isZoomed
            )
        )

        // Mark this window as active in currentWindows.
        for i in currentWindows.indices {
            currentWindows[i].isActive = (currentWindows[i].id == windowId)
        }
        // Update pane IDs for this window.
        // When zoomed, visible_layout contains only the zoomed pane —
        // don't overwrite the full pane list so pills remain selectable.
        if !isZoomed {
            if let idx = currentWindows.firstIndex(where: { $0.id == windowId }) {
                currentWindows[idx].paneIds = panes.map(\.id)
            }
        } else {
            schedulePaneRefresh(for: windowId)
        }

        // Create or resize TerminalBuffer for each pane.
        // Track which panes need a capture-pane refresh.
        var paneIdsToCapture: [PaneID] = []
        for pane in panes {
            if paneBuffers[pane.id] == nil {
                paneBuffers[pane.id] = TerminalBuffer(
                    cols: pane.frame.width, rows: pane.frame.height
                )
                paneIdsToCapture.append(pane.id)
            } else {
                let oldCols = paneBuffers[pane.id]!.cols
                let oldRows = paneBuffers[pane.id]!.rows
                paneBuffers[pane.id]?.resize(
                    cols: pane.frame.width, rows: pane.frame.height
                )
                // Capture-pane is needed when:
                // 1. Zoomed panes carry stale content from their unzoomed
                //    dimensions.  In control mode tmux doesn't redraw the
                //    screen on zoom switch — only the shell's partial
                //    SIGWINCH redraw arrives via %output.
                // 2. Buffer dimensions changed — our local VT parser copies
                //    existing cells but new rows/cols stay empty.  tmux has
                //    the authoritative reflowed content.
                let sizeChanged = pane.frame.width != oldCols || pane.frame.height != oldRows
                if isZoomed || sizeChanged {
                    paneIdsToCapture.append(pane.id)
                }
            }
        }
        // Remove buffers for panes that no longer exist.
        // When zoomed, don't delete buffers for hidden panes.
        if !isZoomed {
            for key in paneBuffers.keys where !paneIds.contains(key) {
                paneBuffers.removeValue(forKey: key)
            }
        }

        // Refresh screen content for new panes and zoomed existing panes.
        if !pendingInitialResize {
            for paneId in paneIdsToCapture {
                Task {
                    try? await self.sendControlCommand(
                        "capture-pane -e -p -t \(paneId.rawValue.shellEscaped())\n",
                        type: .capturePane(paneId: paneId))
                    try? await self.sendControlCommand(
                        "display-message -p -t \(paneId.rawValue.shellEscaped()) '#{cursor_x}:#{cursor_y}'\n",
                        type: .cursorQuery(paneId: paneId))
                }
            }
        }
    }

    /// Force tmux to send %layout-change by re-sending the client size.
    /// select-window only triggers %window-changed (not parsed by our C parser).
    private func forceLayoutRefresh() async throws {
        let (cols, rows) = lastSentSize
        guard cols > 0, rows > 0 else { return }
        try await sendControlCommand(
            "refresh-client -C \(cols),\(rows)\n", type: .ignored)
    }

    /// Rename the specified tmux session.
    func renameSession(_ sessionName: String, to newName: String) async throws {
        guard case .attached = state else { return }
        try await sendControlCommand(
            "rename-session -t \(sessionName.shellEscaped()) \(newName.shellEscaped())\n",
            type: .ignored)
        // Update local sessions array
        if let index = sessions.firstIndex(where: { $0.name == sessionName }) {
            sessions[index].name = newName
        }
        // Update state if we renamed the current session
        if case .attached(let current) = state, current == sessionName {
            state = .attached(sessionName: newName)
        }
    }

    /// Kill the specified tmux session by name.
    func killSession(_ sessionName: String) async throws {
        guard case .attached = state else { return }
        try await sendControlCommand(
            "kill-session -t \(sessionName.shellEscaped())\n", type: .ignored)
        sessions.removeAll { $0.name == sessionName }
    }

    /// Rename the specified window.
    func renameWindow(_ windowId: WindowID, to newName: String) async throws {
        guard case .attached = state else { return }
        try await sendControlCommand(
            "rename-window -t \(windowId.rawValue.shellEscaped()) \(newName.shellEscaped())\n",
            type: .ignored)
        if let index = currentWindows.firstIndex(where: { $0.id == windowId }) {
            currentWindows[index].name = newName
        }
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
                id: SessionID(""), name: name, windows: [], createdAt: Date(), lastActivity: Date()
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
        pendingCommands = []
        resetWindowPaneState()
        currentWindows = []

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
    func fetchScrollback(paneId: PaneID, lineCount: Int = 500) async throws -> String {
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
                        "capture-pane -e -p -S -\(lineCount) -t \(paneId.rawValue.shellEscaped())\n",
                        type: .scrollbackCapture)
                    self.logger.info("Sent scrollback capture-pane for \(paneId.rawValue)")
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
            output = try await sshService.execCommand("bash -lc 'tmux -V'")
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

    // MARK: - Window State Helpers (internal for testability)

    /// Handle a window close notification.
    func handleWindowClose(_ windowId: WindowID) {
        logger.info("Window closed: \(windowId)")
        let wasActive = (activeWindowId == windowId)
        currentWindows.removeAll { $0.id == windowId }
        if wasActive {
            // Clear pane state so onLayoutChange creates fresh buffers.
            // tmux skips %layout-change when refresh-client -C reports the
            // same dimensions, so nudge the size to force a real event.
            paneBuffers = [:]
            resetWindowPaneState()
            Task {
                let (cols, rows) = self.lastSentSize
                guard cols > 0, rows > 0 else { return }
                try? await self.sendControlCommand(
                    "refresh-client -C \(cols),\(rows + 1)\n", type: .ignored)
                try? await self.sendControlCommand(
                    "refresh-client -C \(cols),\(rows)\n", type: .ignored)
            }
        }
    }

    /// Handle a window rename notification.
    func handleWindowRenamed(_ windowId: WindowID, name: String) {
        logger.info("Window renamed: \(windowId) → \(name)")
        if let index = currentWindows.firstIndex(where: { $0.id == windowId }) {
            currentWindows[index].name = name
        }
    }

    /// Handle the list-windows command response.
    func handleListWindowsResponse(_ response: String) {
        let parsed = Self.parseWindowList(response)
        if !parsed.isEmpty {
            // Preserve existing paneIds for windows that carry over.
            // list-windows doesn't include pane info, so without this
            // the pills briefly show 0 panes until list-panes arrives.
            var newWindows = parsed
            for i in newWindows.indices {
                if let existing = currentWindows.first(where: { $0.id == newWindows[i].id }) {
                    newWindows[i].paneIds = existing.paneIds
                }
            }
            currentWindows = newWindows
            // Note: activeWindowId is NOT updated here. The state machine
            // owns activeWindowId via windowPaneState — if the previously
            // active window was removed, the next %layout-change will
            // transition the state machine to the correct window.
            updateWindowPaneMapping()
        }
    }

    /// Handle the `list-panes -a` response and populate every window's paneIds.
    func handleListPanesResponse(_ response: String) {
        let mapping = Self.parseListPanes(response)
        for i in currentWindows.indices {
            if let panes = mapping[currentWindows[i].id] {
                currentWindows[i].paneIds = panes
            }
        }
    }

    /// Request a window list refresh via the control channel.
    /// Sends `list-windows` followed by `list-panes -a` so that every
    /// window's ``Window/paneIds`` is populated.
    private func requestWindowListRefresh() {
        Task {
            try? await sendControlCommand(
                "list-windows -F '#{window_id}\t#{window_index}\t#{window_name}\t#{window_active}'\n",
                type: .listWindows)
            try? await sendControlCommand(
                "list-panes -a -F '#{window_id}\t#{pane_id}'\n",
                type: .listPanes)
        }
    }

    /// Schedule a debounced `list-panes` refresh for a specific window.
    /// Used when a zoomed `%layout-change` arrives — `visible_layout`
    /// only contains the zoomed pane, so the pill pane list may be stale
    /// after pane additions or removals.
    private func schedulePaneRefresh(for windowId: WindowID) {
        paneRefreshTask?.cancel()
        paneRefreshTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            try? await self.sendControlCommand(
                "list-panes -t \(windowId.rawValue.shellEscaped()) -F '#{window_id}\t#{pane_id}'\n",
                type: .listPanes)
        }
    }

    /// Sync ``currentPanes`` into the active window's ``Window/paneIds``.
    /// Called after ``handleListWindowsResponse`` replaces ``currentWindows``
    /// so the active window's pane pills stay current.  Skipped when
    /// ``currentPanes`` is empty (e.g., during a window transition) to avoid
    /// overwriting pane IDs that were just preserved from the previous list.
    private func updateWindowPaneMapping() {
        guard !currentPanes.isEmpty,
              let activeId = activeWindowId,
              let idx = currentWindows.firstIndex(where: { $0.id == activeId })
        else { return }
        currentWindows[idx].paneIds = currentPanes.map(\.id)
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

        tmuxService.onLayoutChange = { [weak self] windowId, panes, isZoomed in
            guard let self else { return }
            self.handleLayoutChange(windowId: windowId, panes: panes, isZoomed: isZoomed)
        }

        tmuxService.onWindowPaneChanged = { [weak self] windowId, paneId in
            guard let self else { return }
            guard windowId == self.activeWindowId else { return }
            // Update active pane ID within the state machine.
            if case .active(var s) = self.windowPaneState {
                s.activePaneId = paneId
                self.windowPaneState = .active(s)
            }
        }

        tmuxService.onSessionWindowChanged = { [weak self] windowId in
            guard let self else { return }
            guard windowId != self.activeWindowId else { return }
            self.logger.info("Session window changed to \(windowId.rawValue)")
            self.prepareWindowSwitch(to: windowId)
            Task {
                do {
                    try await self.forceLayoutRefresh()
                } catch {
                    self.logger.error("Failed to refresh layout after session-window-changed: \(error)")
                }
                self.requestWindowListRefresh()
            }
        }

        tmuxService.onWindowAdd = { [weak self] windowId in
            guard let self else { return }
            self.logger.info("Window added: \(windowId)")
            self.requestWindowListRefresh()
        }

        tmuxService.onWindowClose = { [weak self] windowId in
            guard let self else { return }
            self.handleWindowClose(windowId)
        }

        tmuxService.onWindowRenamed = { [weak self] windowId, name in
            guard let self else { return }
            self.handleWindowRenamed(windowId, name: name)
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
                if !response.isEmpty, let buffer = self.paneBuffers[paneId] {
                    // Reset in-place so TerminalView's reference and onUpdate stay valid.
                    buffer.resetContent()
                    var trimmed = response
                    while trimmed.hasSuffix("\n") {
                        trimmed = String(trimmed.dropLast())
                    }
                    let normalized = trimmed.replacingOccurrences(of: "\n", with: "\r\n")
                    buffer.feed(normalized)
                }
            case .cursorQuery(let paneId):
                // Response format: "col:row" (0-based).
                let parts = response.trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(separator: ":")
                if parts.count == 2,
                   let col = Int(parts[0]),
                   let row = Int(parts[1]) {
                    self.paneBuffers[paneId]?.setCursor(row: row, col: col)
                    self.paneBuffers[paneId]?.onUpdate?()
                }
            case .scrollbackCapture:
                self.deliverScrollbackResponse(response)
            case .listSessions:
                let parsed = TmuxControlService.parseFormattedSessionList(response)
                self.logger.info("Sessions refreshed: \(parsed.count) sessions (raw: \(response.prefix(200)))")
                if parsed.isEmpty && !self.sessions.isEmpty {
                    self.logger.warning("list-sessions returned empty but we had \(self.sessions.count) sessions — keeping existing list")
                } else {
                    self.sessions = parsed
                }
            case .createSession:
                let name = response.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else {
                    self.logger.warning("new-session returned empty name")
                    break
                }
                self.logger.info("Created session via control mode: \(name)")
                if !self.sessions.contains(where: { $0.name == name }) {
                    self.sessions.append(TmuxSession(
                        id: SessionID(""), name: name, windows: [],
                        createdAt: Date(), lastActivity: Date()
                    ))
                }
                Task { try? await self.switchSession(to: name) }
            case .listWindows:
                self.handleListWindowsResponse(response)
            case .listPanes:
                self.handleListPanesResponse(response)
            case .ignored:
                break
            }
        }

        tmuxService.onSessionChanged = { [weak self] sessionId, name in
            guard let self else { return }
            self.logger.info("Session changed to '\(name)' (\(sessionId))")
            self.state = .attached(sessionName: name)
            // Clear all pane state from the previous session so
            // onLayoutChange creates fresh buffers.  Without this,
            // matching pane IDs (e.g. %0) reuse the old buffer and
            // briefly show stale content like "logout".
            self.paneBuffers = [:]
            self.currentWindows = []
            self.resetWindowPaneState()
            // Save as last-used session.
            if let serverID = self.currentServer?.id.uuidString {
                self.lastSessionStore.save(sessionName: name, forServerID: serverID)
            }
            // Force tmux to send %layout-change for the new session's
            // window.  Without this, the cleared paneBuffers/currentPanes
            // leave the UI with no panes to render.
            Task {
                let (cols, rows) = self.lastSentSize
                let size = (cols > 0 && rows > 0) ? "\(cols),\(rows)" : "80,24"
                try? await self.sendControlCommand(
                    "refresh-client -C \(size)\n", type: .ignored)
                self.requestWindowListRefresh()
            }
        }

        tmuxService.onSessionsChanged = { [weak self] in
            guard let self else { return }
            Task {
                try? await self.sendControlCommand(
                    "list-sessions -F '#{session_id}:#{session_name}:#{session_windows}:#{session_activity}'\n",
                    type: .listSessions)
            }
        }

        tmuxService.onExit = { [weak self] in
            guard let self else { return }
            guard case .attached = self.state else { return }
            // With detach-on-destroy off, %exit only fires when no
            // sessions remain.  Just disconnect back to server list.
            self.disconnect()
        }

        tmuxService.onError = { [weak self] message in
            // Log error but don't disconnect -- tmux errors can be non-fatal.
            self?.logger.error("TmuxControl error: \(message)")
        }
    }

    // MARK: - Window List Parsing

    /// Parse the output of `list-windows -F '#{window_id}\t#{window_index}\t#{window_name}\t#{window_active}'`.
    static func parseWindowList(_ output: String) -> [Window] {
        output.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n")
            .compactMap { line in
                let parts = line.trimmingCharacters(in: .whitespaces)
                    .split(separator: "\t", maxSplits: 3)
                guard parts.count >= 4 else { return nil }
                let id = WindowID(String(parts[0]))
                let name = String(parts[2])
                let isActive = parts[3] == "1"
                return Window(id: id, name: name, paneIds: [], isActive: isActive)
            }
    }

    /// Parse the output of `list-panes -a -F '#{window_id}\t#{pane_id}'`
    /// into a mapping from window ID to ordered pane IDs.
    static func parseListPanes(_ output: String) -> [WindowID: [PaneID]] {
        var mapping: [WindowID: [PaneID]] = [:]
        for line in output.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { continue }
            mapping[WindowID(String(parts[0])), default: []].append(PaneID(String(parts[1])))
        }
        return mapping
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
