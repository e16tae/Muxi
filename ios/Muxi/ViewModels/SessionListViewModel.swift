import Foundation

/// Drives the tmux session list screen, translating user actions into
/// ``ConnectionManager`` calls and exposing observable state for the view.
@MainActor
@Observable
final class SessionListViewModel {
    /// Pattern restricting tmux session names to safe characters only.
    private static let validNamePattern = /^[a-zA-Z0-9_.\-]+$/

    private let connectionManager: ConnectionManager

    /// An optional user-facing error message shown as an alert.
    var errorMessage: String?

    /// The list of tmux sessions on the remote server.
    var sessions: [TmuxSession] {
        connectionManager.sessions
    }

    init(connectionManager: ConnectionManager) {
        self.connectionManager = connectionManager
    }

    // MARK: - Actions

    /// Create a new detached tmux session with the given name.
    ///
    /// The name is trimmed of whitespace and validated against
    /// ``validNamePattern`` before being sent to the server.
    func createSession(name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            errorMessage = "Session name cannot be empty."
            return
        }
        guard trimmed.wholeMatch(of: Self.validNamePattern) != nil else {
            errorMessage = "Session name may only contain letters, numbers, underscores, dots, and hyphens."
            return
        }
        do {
            try await connectionManager.createTmuxSession(name: trimmed)
        } catch {
            errorMessage = "Failed to create session: \(error.localizedDescription)"
        }
    }

    /// Delete a tmux session from the remote server.
    func deleteSession(_ session: TmuxSession) async {
        do {
            try await connectionManager.deleteTmuxSession(session)
        } catch {
            errorMessage = "Failed to delete session: \(error.localizedDescription)"
        }
    }

    /// Refresh the session list from the remote server.
    func refreshSessions() async {
        do {
            try await connectionManager.refreshSessions()
        } catch {
            errorMessage = "Failed to refresh sessions: \(error.localizedDescription)"
        }
    }

    /// Attach to a tmux session, transitioning the connection state to
    /// `.attached`.
    func attachSession(_ session: TmuxSession) async {
        do {
            try await connectionManager.attachSession(session)
        } catch {
            errorMessage = "Failed to attach session: \(error.localizedDescription)"
        }
    }
}
