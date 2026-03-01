import XCTest

@testable import Muxi

final class SSHServiceTests: XCTestCase {

    // MARK: - Connection State

    func testConnectionStateTransitions() {
        let service = MockSSHService()
        XCTAssertEqual(service.state, .disconnected)

        service.simulateConnect()
        XCTAssertEqual(service.state, .connected)

        service.simulateDisconnect()
        XCTAssertEqual(service.state, .disconnected)
    }

    func testConnectSetsStateToConnected() async throws {
        let service = MockSSHService()
        try await service.connect(
            host: "example.com",
            port: 22,
            username: "user",
            auth: .password("pass")
        )
        XCTAssertEqual(service.state, .connected)
    }

    func testDisconnectSetsStateToDisconnected() async throws {
        let service = MockSSHService()
        try await service.connect(
            host: "example.com",
            port: 22,
            username: "user",
            auth: .password("pass")
        )
        service.disconnect()
        XCTAssertEqual(service.state, .disconnected)
    }

    // MARK: - Exec

    func testExecCommand() async throws {
        let service = MockSSHService()
        service.simulateConnect()
        service.mockExecResult = "session1: 2 windows\nsession2: 1 windows\n"

        let result = try await service.execCommand("tmux list-sessions")
        XCTAssertTrue(result.contains("session1"))
    }

    func testExecWhenDisconnected() async {
        let service = MockSSHService()
        do {
            _ = try await service.execCommand("ls")
            XCTFail("Should throw when disconnected")
        } catch {
            XCTAssertTrue(error is SSHError)
        }
    }

    // MARK: - Shell

    func testStartShellReturnsChannel() async throws {
        let service = MockSSHService()
        service.simulateConnect()

        let channel = try await service.startShell(onData: { _ in })
        XCTAssertNotNil(channel)
    }

    func testStartShellWhenDisconnected() async {
        let service = MockSSHService()
        do {
            _ = try await service.startShell(onData: { _ in })
            XCTFail("Should throw when disconnected")
        } catch {
            XCTAssertTrue(error is SSHError)
        }
    }

    // MARK: - Error State

    func testErrorStateEquality() {
        let state1 = SSHConnectionState.error("timeout")
        let state2 = SSHConnectionState.error("timeout")
        let state3 = SSHConnectionState.error("refused")

        XCTAssertEqual(state1, state2)
        XCTAssertNotEqual(state1, state3)
    }
}

// MARK: - MockSSHService

/// Mock implementation of ``SSHServiceProtocol`` for unit testing.
class MockSSHService: SSHServiceProtocol {
    var state: SSHConnectionState = .disconnected
    var mockExecResult: String = ""

    func connect(host: String, port: UInt16, username: String, auth: SSHAuth) async throws {
        state = .connected
    }

    func disconnect() {
        state = .disconnected
    }

    func execCommand(_ command: String) async throws -> String {
        guard state == .connected else { throw SSHError.notConnected }
        return mockExecResult
    }

    func startShell(onData: @escaping (Data) -> Void) async throws -> SSHChannel {
        guard state == .connected else { throw SSHError.notConnected }
        return MockSSHChannel()
    }

    // MARK: Test Helpers

    func simulateConnect() { state = .connected }
    func simulateDisconnect() { state = .disconnected }
}

// MARK: - MockSSHChannel

/// Mock implementation of ``SSHChannel`` for unit testing.
class MockSSHChannel: SSHChannel {
    func write(_ data: Data) throws {}
    func close() {}
    func resize(cols: Int, rows: Int) throws {}
}
