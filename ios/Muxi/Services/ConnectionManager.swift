import Foundation

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
    private let sshService: SSHServiceProtocol
    private let tmuxService = TmuxControlService()
    private let keychainService = KeychainService()

    /// The current connection state.
    private(set) var state: ConnectionState = .disconnected

    /// The server we are currently connected (or connecting) to.
    private(set) var currentServer: Server?

    /// The list of tmux sessions discovered on the remote server.
    private(set) var sessions: [TmuxSession] = []

    /// Cached credentials from the last successful ``connect(server:password:)``
    /// call, reused by ``reconnect()`` so we do not need to hit the Keychain
    /// again when re-establishing a dropped connection.
    private var cachedAuth: SSHAuth?

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

        do {
            let auth = try resolveAuth(for: server, password: password)
            cachedAuth = auth

            try await sshService.connect(
                host: server.host,
                port: server.port,
                username: server.username,
                auth: auth
            )

            // Query tmux sessions via a formatted list-sessions command.
            let output = try await sshService.execCommand(
                "tmux list-sessions -F '#{session_id}:#{session_name}:#{session_windows}:#{session_activity}'"
            )
            sessions = TmuxControlService.parseFormattedSessionList(output)
            state = .sessionList
            return sessions
        } catch {
            state = .disconnected
            currentServer = nil
            cachedAuth = nil
            throw error
        }
    }

    // MARK: - Disconnect

    /// Tear down the SSH connection and reset all state.
    func disconnect() {
        sshService.disconnect()
        state = .disconnected
        currentServer = nil
        sessions = []
        cachedAuth = nil
    }

    // MARK: - Session Management

    /// Attach to a tmux session by name.
    ///
    /// In the full implementation this will start a shell channel running
    /// `tmux -CC attach -t <name>` and pipe output through
    /// ``TmuxControlService/handleLine(_:)``.
    func attachSession(_ session: TmuxSession) async throws {
        guard state == .sessionList else { return }
        state = .attached(sessionName: session.name)
        // TODO: start shell with `tmux -CC attach -t <name>`
        // and pipe output through tmuxService.handleLine()
    }

    /// Detach from the current tmux session, returning to the session list.
    func detach() {
        state = .sessionList
    }

    // MARK: - tmux Session CRUD

    /// Create a new detached tmux session with the given name on the remote
    /// server, then refresh the session list.
    func createTmuxSession(name: String) async throws {
        _ = try await sshService.execCommand("tmux new-session -d -s \(shellEscaped(name))")
        try await refreshSessions()
    }

    /// Kill the specified tmux session on the remote server, then refresh
    /// the session list.
    func deleteTmuxSession(_ session: TmuxSession) async throws {
        _ = try await sshService.execCommand("tmux kill-session -t \(shellEscaped(session.name))")
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
                try await sshService.connect(
                    host: server.host,
                    port: server.port,
                    username: server.username,
                    auth: auth
                )

                // Refresh the session list from the server.
                try await refreshSessions()

                // Re-attach if we were attached before and the session still
                // exists on the server.
                if let sessionName = previousSessionName,
                   let session = sessions.first(where: { $0.name == sessionName }) {
                    state = .attached(sessionName: session.name)
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

    // MARK: - Shell Safety

    /// Wraps a string in single quotes with proper escaping so it is safe
    /// to interpolate into a shell command.  Any embedded single-quote
    /// characters are escaped using the `'\''` idiom.
    private func shellEscaped(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
