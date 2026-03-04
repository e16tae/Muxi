import XCTest

@testable import Muxi

@MainActor
final class ConnectionManagerTests: XCTestCase {

    // MARK: - Helpers

    /// Build a ``Server`` with password auth for use in tests.
    private func makeServer(
        name: String = "Test",
        host: String = "host",
        username: String = "user"
    ) -> Server {
        Server(name: name, host: host, username: username, authMethod: .password)
    }

    // MARK: - Initial State

    func testInitialState() {
        let manager = ConnectionManager(sshService: MockSSHService())
        XCTAssertEqual(manager.state, .disconnected)
        XCTAssertNil(manager.currentServer)
        XCTAssertTrue(manager.sessions.isEmpty)
    }

    // MARK: - Connect Flow

    func testConnectFlow() async throws {
        let ssh = MockSSHService()
        ssh.mockExecResults["tmux -V"] = "tmux 3.4\n"
        ssh.mockExecResults["tmux list-sessions"] = "$0:main:2:1740700800"
        let manager = ConnectionManager(sshService: ssh)

        let sessions = try await manager.connect(
            server: makeServer(),
            password: "p"
        )

        XCTAssertEqual(manager.state, .sessionList)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].name, "main")
    }

    func testConnectSetsCurrentServer() async throws {
        let ssh = MockSSHService()
        ssh.mockExecResults["tmux -V"] = "tmux 3.4\n"
        ssh.mockExecResults["tmux list-sessions"] = "$0:dev:1:0"
        let manager = ConnectionManager(sshService: ssh)
        let server = makeServer(name: "MyServer", host: "10.0.0.1")

        _ = try await manager.connect(server: server, password: "pw")

        XCTAssertEqual(manager.currentServer?.name, "MyServer")
        XCTAssertEqual(manager.currentServer?.host, "10.0.0.1")
    }

    func testConnectParsesMultipleSessions() async throws {
        let ssh = MockSSHService()
        ssh.mockExecResults["tmux -V"] = "tmux 3.4\n"
        ssh.mockExecResults["tmux list-sessions"] = """
            $0:main:2:1740700800
            $1:dev:1:1740700900
            $2:staging:3:1740701000
            """
        let manager = ConnectionManager(sshService: ssh)

        let sessions = try await manager.connect(
            server: makeServer(),
            password: "p"
        )

        XCTAssertEqual(sessions.count, 3)
        XCTAssertEqual(sessions[0].name, "main")
        XCTAssertEqual(sessions[1].name, "dev")
        XCTAssertEqual(sessions[2].name, "staging")
        XCTAssertEqual(manager.sessions.count, 3)
    }

    func testConnectWithEmptySessionList() async throws {
        let ssh = MockSSHService()
        ssh.mockExecResults["tmux -V"] = "tmux 3.4\n"
        ssh.mockExecResults["tmux list-sessions"] = ""
        let manager = ConnectionManager(sshService: ssh)

        let sessions = try await manager.connect(
            server: makeServer(),
            password: "p"
        )

        XCTAssertEqual(sessions.count, 0)
        XCTAssertEqual(manager.state, .sessionList)
    }

    // MARK: - Disconnect

    func testDisconnect() async throws {
        let ssh = MockSSHService()
        ssh.mockExecResults["tmux -V"] = "tmux 3.4\n"
        ssh.mockExecResults["tmux list-sessions"] = "$0:test:1:0"
        let manager = ConnectionManager(sshService: ssh)
        _ = try await manager.connect(server: makeServer(), password: "p")

        manager.disconnect()

        XCTAssertEqual(manager.state, .disconnected)
        XCTAssertNil(manager.currentServer)
        XCTAssertTrue(manager.sessions.isEmpty)
    }

    func testDisconnectWhenAlreadyDisconnected() {
        let manager = ConnectionManager(sshService: MockSSHService())
        // Should not crash when disconnecting from an already-disconnected state.
        manager.disconnect()
        XCTAssertEqual(manager.state, .disconnected)
    }

    // MARK: - Attach / Detach

    func testAttachSession() async throws {
        let ssh = MockSSHService()
        ssh.mockExecResults["tmux -V"] = "tmux 3.4\n"
        ssh.mockExecResults["tmux list-sessions"] = "$0:work:1:0"
        let manager = ConnectionManager(sshService: ssh)
        let sessions = try await manager.connect(server: makeServer(), password: "p")

        try await manager.attachSession(sessions[0])

        XCTAssertEqual(manager.state, .attached(sessionName: "work"))
    }

    func testDetach() async throws {
        let ssh = MockSSHService()
        ssh.mockExecResults["tmux -V"] = "tmux 3.4\n"
        ssh.mockExecResults["tmux list-sessions"] = "$0:work:1:0"
        let manager = ConnectionManager(sshService: ssh)
        let sessions = try await manager.connect(server: makeServer(), password: "p")
        try await manager.attachSession(sessions[0])

        manager.detach()

        XCTAssertEqual(manager.state, .sessionList)
    }

    // MARK: - Attach with Shell Channel

    func testAttachSessionCallsStartShell() async throws {
        let ssh = MockSSHService()
        ssh.mockExecResults["tmux -V"] = "tmux 3.4\n"
        ssh.mockExecResults["tmux list-sessions"] = "$0:work:1:0"
        let manager = ConnectionManager(sshService: ssh)
        let sessions = try await manager.connect(server: makeServer(), password: "p")

        try await manager.attachSession(sessions[0])

        XCTAssertEqual(manager.state, .attached(sessionName: "work"))
        XCTAssertNotNil(manager.activeChannel)
    }

    func testDisconnectCleansUpChannel() async throws {
        let ssh = MockSSHService()
        ssh.mockExecResults["tmux -V"] = "tmux 3.4\n"
        ssh.mockExecResults["tmux list-sessions"] = "$0:work:1:0"
        let manager = ConnectionManager(sshService: ssh)
        let sessions = try await manager.connect(server: makeServer(), password: "p")
        try await manager.attachSession(sessions[0])

        manager.disconnect()

        XCTAssertNil(manager.activeChannel)
        XCTAssertTrue(manager.paneBuffers.isEmpty)
        XCTAssertTrue(manager.currentPanes.isEmpty)
    }

    func testDetachResetsToSessionList() async throws {
        let ssh = MockSSHService()
        ssh.mockExecResults["tmux -V"] = "tmux 3.4\n"
        ssh.mockExecResults["tmux list-sessions"] = "$0:work:1:0"
        let manager = ConnectionManager(sshService: ssh)
        let sessions = try await manager.connect(server: makeServer(), password: "p")
        try await manager.attachSession(sessions[0])

        manager.detach()

        XCTAssertEqual(manager.state, .sessionList)
        XCTAssertNil(manager.activeChannel)
        XCTAssertTrue(manager.paneBuffers.isEmpty)
    }

    // MARK: - tmux Detection

    func testConnectThrowsWhenTmuxNotInstalled() async {
        let ssh = MockSSHService()
        ssh.mockExecResults["tmux -V"] = "bash: tmux: command not found\n"
        let manager = ConnectionManager(sshService: ssh)

        do {
            _ = try await manager.connect(server: makeServer(), password: "p")
            XCTFail("Expected TmuxError.notInstalled")
        } catch let error as TmuxError {
            XCTAssertEqual(error, .notInstalled)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
        XCTAssertEqual(manager.state, .disconnected)
    }

    func testConnectThrowsWhenTmuxVersionTooOld() async {
        let ssh = MockSSHService()
        ssh.mockExecResults["tmux -V"] = "tmux 1.6\n"
        let manager = ConnectionManager(sshService: ssh)

        do {
            _ = try await manager.connect(server: makeServer(), password: "p")
            XCTFail("Expected TmuxError.versionTooOld")
        } catch let error as TmuxError {
            if case .versionTooOld(let detected) = error {
                XCTAssertEqual(detected, "1.6")
            } else {
                XCTFail("Wrong TmuxError case: \(error)")
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
        XCTAssertEqual(manager.state, .disconnected)
    }

    func testConnectSucceedsWithValidTmuxVersion() async throws {
        let ssh = MockSSHService()
        ssh.mockExecResults["tmux -V"] = "tmux 3.4\n"
        ssh.mockExecResults["tmux list-sessions"] = "$0:main:2:1740700800"
        let manager = ConnectionManager(sshService: ssh)

        let sessions = try await manager.connect(server: makeServer(), password: "p")
        XCTAssertEqual(manager.state, .sessionList)
        XCTAssertEqual(sessions.count, 1)
    }

    func testConnectThrowsWhenExecCommandFails() async {
        let ssh = MockSSHService()
        ssh.mockExecError = SSHError.channelError("exec failed")
        let manager = ConnectionManager(sshService: ssh)

        do {
            _ = try await manager.connect(server: makeServer(), password: "p")
            XCTFail("Expected error")
        } catch let error as TmuxError {
            XCTAssertEqual(error, .notInstalled)
        } catch {
            // Other SSH errors may also be thrown — acceptable
        }
    }

    // MARK: - Scrollback Fetch

    func testFetchScrollbackSuccessReturnsResponse() async throws {
        let ssh = MockSSHService()
        ssh.mockExecResults["tmux -V"] = "tmux 3.4\n"
        ssh.mockExecResults["tmux list-sessions"] = "$0:test:1:0"
        let manager = ConnectionManager(sshService: ssh)
        _ = try await manager.connect(server: makeServer(), password: "p")
        // State is .sessionList — fetchScrollback accepts this state.

        let fetchTask = Task {
            try await manager.fetchScrollback(paneId: "%0")
        }

        // Give the fetch task time to send the command and set up continuation.
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms

        // Simulate tmux responding with scrollback content.
        manager.deliverScrollbackResponse("line1\nline2\nline3")

        let result = try await fetchTask.value
        XCTAssertEqual(result, "line1\nline2\nline3")
    }

    func testFetchScrollbackEmptyResponseReturnsEmptyString() async throws {
        let ssh = MockSSHService()
        ssh.mockExecResults["tmux -V"] = "tmux 3.4\n"
        ssh.mockExecResults["tmux list-sessions"] = "$0:test:1:0"
        let manager = ConnectionManager(sshService: ssh)
        _ = try await manager.connect(server: makeServer(), password: "p")

        let fetchTask = Task {
            try await manager.fetchScrollback(paneId: "%0")
        }

        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        manager.deliverScrollbackResponse("")

        let result = try await fetchTask.value
        XCTAssertEqual(result, "")
    }

    func testFetchScrollbackThrowsWhenDisconnected() async {
        let manager = ConnectionManager(sshService: MockSSHService())
        XCTAssertEqual(manager.state, .disconnected)

        do {
            _ = try await manager.fetchScrollback(paneId: "%0")
            XCTFail("Expected ScrollbackError.notAttached")
        } catch let error as ScrollbackError {
            XCTAssertEqual(error, .notAttached)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testFetchScrollbackThrowsWhenFetchAlreadyInProgress() async throws {
        let ssh = MockSSHService()
        ssh.mockExecResults["tmux -V"] = "tmux 3.4\n"
        ssh.mockExecResults["tmux list-sessions"] = "$0:test:1:0"
        let manager = ConnectionManager(sshService: ssh)
        _ = try await manager.connect(server: makeServer(), password: "p")

        // Start first fetch but do not deliver response yet.
        let firstTask = Task {
            try await manager.fetchScrollback(paneId: "%0")
        }
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms — let first task set continuation

        // Second fetch should fail immediately.
        do {
            _ = try await manager.fetchScrollback(paneId: "%0")
            XCTFail("Expected ScrollbackError.fetchInProgress")
        } catch let error as ScrollbackError {
            XCTAssertEqual(error, .fetchInProgress)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }

        // Clean up: deliver response to unblock the first task.
        manager.deliverScrollbackResponse("done")
        _ = try await firstTask.value
    }

    // MARK: - State Equality

    func testConnectionStateEquality() {
        XCTAssertEqual(ConnectionState.disconnected, ConnectionState.disconnected)
        XCTAssertEqual(ConnectionState.connecting, ConnectionState.connecting)
        XCTAssertEqual(ConnectionState.sessionList, ConnectionState.sessionList)
        XCTAssertEqual(
            ConnectionState.attached(sessionName: "a"),
            ConnectionState.attached(sessionName: "a")
        )
        XCTAssertNotEqual(
            ConnectionState.attached(sessionName: "a"),
            ConnectionState.attached(sessionName: "b")
        )
        XCTAssertNotEqual(ConnectionState.disconnected, ConnectionState.connecting)
    }
}
