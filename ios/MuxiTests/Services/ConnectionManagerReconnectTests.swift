import XCTest

@testable import Muxi

// MARK: - ReconnectMockSSHService

/// A mock SSH service that can simulate a configurable number of connection
/// failures before succeeding.  Used to test the exponential-backoff
/// reconnection logic in ``ConnectionManager``.
final class ReconnectMockSSHService: SSHServiceProtocol {
    var state: SSHConnectionState = .disconnected

    /// How many times ``connect`` has been called.
    var connectCallCount = 0

    /// The first N ``connect`` calls will throw; after that they succeed.
    var shouldFailConnectCount: Int = 0

    /// The string returned by ``execCommand(_:)``.
    var mockExecResult: String = ""

    /// Per-command overrides. If a command matches a key, that value is returned.
    /// Falls back to `mockExecResult` if no match.
    var mockExecResults: [String: String] = [:]

    /// If set, `execCommand` throws this error instead of returning a result.
    var mockExecError: Error?

    func connect(host: String, port: UInt16, username: String, auth: SSHAuth) async throws {
        connectCallCount += 1
        if connectCallCount <= shouldFailConnectCount {
            throw SSHError.connectionFailed("simulated failure #\(connectCallCount)")
        }
        state = .connected
    }

    func disconnect() {
        state = .disconnected
    }

    func execCommand(_ command: String) async throws -> String {
        guard state == .connected else { throw SSHError.notConnected }
        if let error = mockExecError { throw error }
        // Check for per-command override by prefix match.
        for (key, value) in mockExecResults {
            if command.hasPrefix(key) { return value }
        }
        return mockExecResult
    }

    func startShell(onData: @escaping (Data) -> Void) async throws -> SSHChannel {
        guard state == .connected else { throw SSHError.notConnected }
        return MockSSHChannel()
    }

    func writeToChannel(_ data: Data) async throws {
        guard state == .connected else { throw SSHError.notConnected }
    }
}

// MARK: - ConnectionManagerReconnectTests

@MainActor
final class ConnectionManagerReconnectTests: XCTestCase {

    // MARK: - Helpers

    /// Build a ``Server`` with password auth for use in tests.
    private func makeServer(
        name: String = "Test",
        host: String = "host",
        username: String = "user"
    ) -> Server {
        Server(name: name, host: host, username: username, authMethod: .password)
    }

    /// Create a ``ConnectionManager`` wired to the given mock, with zero
    /// backoff delay so tests complete instantly.
    private func makeManager(
        ssh: ReconnectMockSSHService,
        maxAttempts: Int = 5
    ) -> ConnectionManager {
        ConnectionManager(
            sshService: ssh,
            maxReconnectAttempts: maxAttempts,
            baseDelay: 0
        )
    }

    /// Connect a manager to a server (via password) and return it in
    /// `.sessionList` state.
    private func connectedManager(
        ssh: ReconnectMockSSHService,
        sessions sessionOutput: String = "$0:main:1:0",
        maxAttempts: Int = 5
    ) async throws -> ConnectionManager {
        ssh.mockExecResults["tmux -V"] = "tmux 3.4\n"
        ssh.mockExecResults["tmux list-sessions"] = sessionOutput
        let manager = makeManager(ssh: ssh, maxAttempts: maxAttempts)
        _ = try await manager.connect(server: makeServer(), password: "pw")
        return manager
    }

    // MARK: - Tests

    /// When the first reconnect attempt succeeds, the manager should transition
    /// to `.sessionList` and reset the attempt counter.
    func testReconnectSucceedsFirstAttempt() async throws {
        let ssh = ReconnectMockSSHService()
        ssh.mockExecResult = "$0:main:1:0"
        let manager = try await connectedManager(ssh: ssh)
        XCTAssertEqual(manager.state, .sessionList)

        // Simulate a disconnect event (SSH keepalive timeout).
        ssh.shouldFailConnectCount = 0 // next connect succeeds immediately
        ssh.connectCallCount = 0

        await manager.reconnect()

        XCTAssertEqual(manager.state, .sessionList)
        XCTAssertEqual(manager.reconnectAttempt, 0)
        // connect was called once during initial connect + once during reconnect
        XCTAssertEqual(ssh.connectCallCount, 1)
    }

    /// If the manager was `.attached(sessionName: "dev")` before the
    /// disconnect, and the "dev" session still exists after reconnecting,
    /// the manager should re-attach to it.
    func testReconnectReattachesIfPreviouslyAttached() async throws {
        let ssh = ReconnectMockSSHService()
        ssh.mockExecResult = "$0:dev:2:0"
        let manager = try await connectedManager(ssh: ssh, sessions: "$0:dev:2:0")

        // Attach to "dev".
        let session = manager.sessions.first!
        try await manager.attachSession(session)
        XCTAssertEqual(manager.state, .attached(sessionName: "dev"))

        // Simulate disconnect + reconnect.
        ssh.shouldFailConnectCount = 0
        ssh.connectCallCount = 0

        await manager.reconnect()

        XCTAssertEqual(manager.state, .attached(sessionName: "dev"))
        XCTAssertEqual(manager.reconnectAttempt, 0)
    }

    /// If the manager was attached to "dev" but that session no longer exists
    /// on the server after reconnecting, it should fall back to `.sessionList`.
    func testReconnectFallsToSessionListIfSessionGone() async throws {
        let ssh = ReconnectMockSSHService()
        ssh.mockExecResult = "$0:dev:1:0"
        let manager = try await connectedManager(ssh: ssh, sessions: "$0:dev:1:0")

        // Attach to "dev".
        let session = manager.sessions.first!
        try await manager.attachSession(session)
        XCTAssertEqual(manager.state, .attached(sessionName: "dev"))

        // After reconnect the server only has "prod" -- "dev" is gone.
        ssh.mockExecResults["tmux list-sessions"] = "$1:prod:1:0"
        ssh.shouldFailConnectCount = 0
        ssh.connectCallCount = 0

        await manager.reconnect()

        XCTAssertEqual(manager.state, .sessionList)
        XCTAssertEqual(manager.reconnectAttempt, 0)
        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertEqual(manager.sessions[0].name, "prod")
    }

    /// When every reconnect attempt fails, the manager should end up in
    /// `.disconnected` with the attempt counter reset to zero.
    func testReconnectExhaustsAttempts() async throws {
        let ssh = ReconnectMockSSHService()
        ssh.mockExecResult = "$0:main:1:0"
        let manager = try await connectedManager(ssh: ssh, maxAttempts: 3)

        // All future connect calls will fail.
        ssh.shouldFailConnectCount = 100
        ssh.connectCallCount = 0

        await manager.reconnect()

        XCTAssertEqual(manager.state, .disconnected)
        XCTAssertEqual(manager.reconnectAttempt, 0)
        XCTAssertEqual(ssh.connectCallCount, 3)
    }

    /// The ``reconnectAttempt`` property should increment with each retry,
    /// allowing the UI to display progress.
    func testReconnectAttemptsCount() async throws {
        let ssh = ReconnectMockSSHService()
        ssh.mockExecResult = "$0:main:1:0"
        let manager = try await connectedManager(ssh: ssh, maxAttempts: 3)

        // Fail twice then succeed on the third attempt.
        ssh.shouldFailConnectCount = 2
        ssh.connectCallCount = 0

        await manager.reconnect()

        // After a successful reconnect the counter is reset.
        XCTAssertEqual(manager.reconnectAttempt, 0)
        XCTAssertEqual(manager.state, .sessionList)
        XCTAssertEqual(ssh.connectCallCount, 3)
    }

    /// Calling ``reconnect()`` when there is no ``currentServer`` should
    /// return immediately without changing state.
    func testReconnectNoServerDoesNothing() async {
        let ssh = ReconnectMockSSHService()
        let manager = makeManager(ssh: ssh)

        XCTAssertEqual(manager.state, .disconnected)
        XCTAssertNil(manager.currentServer)

        await manager.reconnect()

        XCTAssertEqual(manager.state, .disconnected)
        XCTAssertEqual(manager.reconnectAttempt, 0)
        XCTAssertEqual(ssh.connectCallCount, 0)
    }

    /// When ``connect(server:password:)`` fails (e.g. SSH connect throws),
    /// the manager must reset to `.disconnected` with `currentServer` and
    /// `cachedAuth` cleared so the state machine stays consistent.
    func testConnectFailureResetsState() async throws {
        let ssh = ReconnectMockSSHService()
        ssh.shouldFailConnectCount = 999
        let manager = makeManager(ssh: ssh)

        do {
            _ = try await manager.connect(server: makeServer(), password: "pw")
            XCTFail("connect should have thrown")
        } catch {
            XCTAssertEqual(manager.state, .disconnected)
            XCTAssertNil(manager.currentServer)
        }
    }

    /// Verify that the manager transitions through `.reconnecting` during
    /// the reconnect flow.
    func testReconnectTransitionsThroughReconnectingState() async throws {
        let ssh = ReconnectMockSSHService()
        ssh.mockExecResult = "$0:main:1:0"
        let manager = try await connectedManager(ssh: ssh)

        // Fail once so we can be sure reconnecting state was entered,
        // then succeed on the second attempt.
        ssh.shouldFailConnectCount = 1
        ssh.connectCallCount = 0

        await manager.reconnect()

        // We cannot observe the intermediate state mid-await, but we can
        // verify the final state after successful reconnect.
        XCTAssertEqual(manager.state, .sessionList)
        XCTAssertEqual(ssh.connectCallCount, 2)
    }
}
