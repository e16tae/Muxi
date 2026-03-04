import XCTest

@testable import Muxi

@MainActor
final class SessionListViewModelTests: XCTestCase {

    // MARK: - Helpers

    /// A mock SSH service that records executed commands for assertion.
    private class TrackingSSHService: MockSSHService {
        var executedCommands: [String] = []

        override func execCommand(_ command: String) async throws -> String {
            executedCommands.append(command)
            return try await super.execCommand(command)
        }
    }

    private func makeSession(
        id: String = "$0",
        name: String = "main"
    ) -> TmuxSession {
        TmuxSession(
            id: id,
            name: name,
            windows: [],
            createdAt: Date(),
            lastActivity: Date()
        )
    }

    // MARK: - Create Session

    func testCreateSession() async throws {
        let ssh = TrackingSSHService()
        ssh.simulateConnect()
        ssh.mockExecResult = ""

        let manager = ConnectionManager(sshService: ssh)
        let vm = SessionListViewModel(connectionManager: manager)

        await vm.createSession(name: "work")

        XCTAssertTrue(
            ssh.executedCommands.contains(where: { $0.contains("tmux new-session -d -s 'work'") }),
            "Expected new-session command, got: \(ssh.executedCommands)"
        )
    }

    // MARK: - Delete Session

    func testDeleteSession() async throws {
        let ssh = TrackingSSHService()
        ssh.simulateConnect()
        ssh.mockExecResults["tmux -V"] = "tmux 3.4\n"
        ssh.mockExecResults["tmux list-sessions"] = "$0:work:1:0"

        let manager = ConnectionManager(sshService: ssh)
        // Connect first to populate sessions.
        let server = Server(name: "T", host: "h", username: "u", authMethod: .password)
        _ = try await manager.connect(server: server, password: "p")

        let session = manager.sessions[0]
        ssh.executedCommands.removeAll()
        ssh.mockExecResult = ""

        let vm = SessionListViewModel(connectionManager: manager)
        await vm.deleteSession(session)

        XCTAssertTrue(
            ssh.executedCommands.contains(where: { $0.contains("tmux kill-session -t 'work'") }),
            "Expected kill-session command, got: \(ssh.executedCommands)"
        )
    }

    // MARK: - Refresh Sessions

    func testRefreshSessions() async throws {
        let ssh = TrackingSSHService()
        ssh.simulateConnect()
        ssh.mockExecResults["tmux -V"] = "tmux 3.4\n"
        ssh.mockExecResults["tmux list-sessions"] = "$0:alpha:1:0"

        let manager = ConnectionManager(sshService: ssh)
        let server = Server(name: "T", host: "h", username: "u", authMethod: .password)
        _ = try await manager.connect(server: server, password: "p")

        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertEqual(manager.sessions[0].name, "alpha")

        // Simulate a new session appearing on the server.
        ssh.mockExecResults["tmux list-sessions"] = "$0:alpha:1:0\n$1:beta:2:0"
        ssh.executedCommands.removeAll()

        let vm = SessionListViewModel(connectionManager: manager)
        await vm.refreshSessions()

        XCTAssertTrue(
            ssh.executedCommands.contains(where: { $0.contains("tmux list-sessions") }),
            "Expected list-sessions command, got: \(ssh.executedCommands)"
        )
        XCTAssertEqual(vm.sessions.count, 2)
        XCTAssertEqual(vm.sessions[1].name, "beta")
    }

    // MARK: - Attach Session

    func testAttachSession() async throws {
        let ssh = TrackingSSHService()
        ssh.simulateConnect()
        ssh.mockExecResults["tmux -V"] = "tmux 3.4\n"
        ssh.mockExecResults["tmux list-sessions"] = "$0:dev:1:0"

        let manager = ConnectionManager(sshService: ssh)
        let server = Server(name: "T", host: "h", username: "u", authMethod: .password)
        _ = try await manager.connect(server: server, password: "p")

        let session = manager.sessions[0]
        let vm = SessionListViewModel(connectionManager: manager)

        await vm.attachSession(session)

        XCTAssertEqual(manager.state, .attached(sessionName: "dev"))
    }

    // MARK: - Command Injection Prevention

    func testCreateSessionRejectsMaliciousName() async {
        let ssh = TrackingSSHService()
        ssh.simulateConnect()
        ssh.mockExecResult = ""

        let manager = ConnectionManager(sshService: ssh)
        let vm = SessionListViewModel(connectionManager: manager)

        await vm.createSession(name: "test; echo pwned")

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertTrue(
            vm.errorMessage?.contains("may only contain") == true,
            "Expected validation error, got: \(vm.errorMessage ?? "nil")"
        )
        // The malicious command must never reach the SSH service.
        XCTAssertTrue(
            ssh.executedCommands.isEmpty,
            "No commands should be sent for an invalid name, got: \(ssh.executedCommands)"
        )
    }

    func testCreateSessionRejectsEmptyName() async {
        let ssh = TrackingSSHService()
        ssh.simulateConnect()
        ssh.mockExecResult = ""

        let manager = ConnectionManager(sshService: ssh)
        let vm = SessionListViewModel(connectionManager: manager)

        await vm.createSession(name: "   ")

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertTrue(
            vm.errorMessage?.contains("cannot be empty") == true,
            "Expected empty-name error, got: \(vm.errorMessage ?? "nil")"
        )
        XCTAssertTrue(ssh.executedCommands.isEmpty)
    }

    func testShellEscapingInCreateSession() async throws {
        let ssh = TrackingSSHService()
        ssh.simulateConnect()
        ssh.mockExecResult = ""

        let manager = ConnectionManager(sshService: ssh)
        let vm = SessionListViewModel(connectionManager: manager)

        // A valid name that should pass validation and be shell-escaped.
        await vm.createSession(name: "my_session.1")

        XCTAssertNil(vm.errorMessage, "Valid name should not produce an error")
        XCTAssertTrue(
            ssh.executedCommands.contains(where: { $0.contains("tmux new-session -d -s 'my_session.1'") }),
            "Expected shell-escaped command, got: \(ssh.executedCommands)"
        )
    }

    // MARK: - Error Handling

    func testCreateSessionErrorSetsMessage() async {
        let ssh = TrackingSSHService()
        // Do NOT simulate connect -- execCommand will throw SSHError.notConnected
        let manager = ConnectionManager(sshService: ssh)
        let vm = SessionListViewModel(connectionManager: manager)

        await vm.createSession(name: "fail")

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertTrue(
            vm.errorMessage?.contains("Failed to create session") == true,
            "Error message was: \(vm.errorMessage ?? "nil")"
        )
    }
}
