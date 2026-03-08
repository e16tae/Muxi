import XCTest

@testable import Muxi

// MARK: - HostKeyMockSSHService

/// A mock SSH service that simulates host key verification behavior.
/// On first connection (nil expectedFingerprint), throws `fingerprintVerificationNeeded`.
/// On subsequent connections with matching fingerprint, connects successfully.
/// On mismatched fingerprint, throws `fingerprintMismatch`.
final class HostKeyMockSSHService: SSHServiceProtocol {
    var state: SSHConnectionState = .disconnected

    /// The fingerprint this mock "server" presents.
    var serverFingerprint: String = "SHA256:n4bQgYhMfWWaL+qgxVrQFaO/TxsrC4Is0V1sFbDwCgg="

    /// Per-command overrides for execCommand.
    var mockExecResults: [String: String] = [:]

    /// Tracks how many times connect was called.
    var connectCallCount = 0

    func connect(
        host: String,
        port: UInt16,
        username: String,
        auth: SSHAuth,
        expectedFingerprint: String? = nil
    ) async throws {
        connectCallCount += 1

        if let expected = expectedFingerprint {
            if expected != serverFingerprint {
                throw SSHHostKeyError.fingerprintMismatch(
                    expected: expected, actual: serverFingerprint
                )
            }
        } else {
            throw SSHHostKeyError.fingerprintVerificationNeeded(
                fingerprint: serverFingerprint
            )
        }

        state = .connected
    }

    func disconnect() {
        state = .disconnected
    }

    func execCommand(_ command: String) async throws -> String {
        guard state == .connected else { throw SSHError.notConnected }
        for (key, value) in mockExecResults {
            if command.hasPrefix(key) { return value }
        }
        return ""
    }

    func startShell(onData: @escaping (Data) -> Void) async throws -> SSHChannel {
        guard state == .connected else { throw SSHError.notConnected }
        return MockSSHChannel()
    }

    func writeToChannel(_ data: Data) async throws {
        guard state == .connected else { throw SSHError.notConnected }
    }
}

// MARK: - ConnectionManagerHostKeyTests

@MainActor
final class ConnectionManagerHostKeyTests: XCTestCase {

    // MARK: - Helpers

    private func makeServer(
        name: String = "Test",
        host: String = "host",
        username: String = "user",
        fingerprint: String? = nil
    ) -> Server {
        Server(
            name: name, host: host, username: username,
            authMethod: .password,
            hostKeyFingerprint: fingerprint
        )
    }

    // MARK: - First Connection (TOFU)

    func testFirstConnectionPromptsFingerprintVerification() async throws {
        let ssh = HostKeyMockSSHService()
        ssh.mockExecResults["tmux -V"] = "tmux 3.4\n"
        ssh.mockExecResults["tmux list-sessions"] = "$0:main:1:0"
        let manager = ConnectionManager(sshService: ssh)
        let server = makeServer()

        // Start the connection in a background task — it will suspend
        // waiting for user approval.
        let connectTask = Task {
            _ = try await manager.connect(server: server, password: "p")
        }

        // Wait briefly for the connection to reach the fingerprint prompt.
        try await Task.sleep(for: .milliseconds(100))

        // Verify the pending fingerprint is set.
        XCTAssertNotNil(manager.pendingFingerprint)
        XCTAssertEqual(manager.pendingFingerprint, ssh.serverFingerprint)
        XCTAssertNotNil(manager.pendingFingerprintAction)

        // Simulate user trusting the fingerprint.
        manager.pendingFingerprintAction?(true)

        // Wait for the connection to complete.
        try await connectTask.value

        XCTAssertEqual(manager.state, .sessionList)
        XCTAssertEqual(server.hostKeyFingerprint, ssh.serverFingerprint)
        XCTAssertNil(manager.pendingFingerprint)
    }

    func testFirstConnectionRejectionDisconnects() async throws {
        let ssh = HostKeyMockSSHService()
        let manager = ConnectionManager(sshService: ssh)
        let server = makeServer()

        let connectTask = Task<Void, Error> {
            _ = try await manager.connect(server: server, password: "p")
        }

        try await Task.sleep(for: .milliseconds(100))

        XCTAssertNotNil(manager.pendingFingerprint)

        // Simulate user rejecting the fingerprint.
        manager.pendingFingerprintAction?(false)

        do {
            try await connectTask.value
            XCTFail("Expected SSHHostKeyError")
        } catch is SSHHostKeyError {
            // Expected
        }

        XCTAssertEqual(manager.state, .disconnected)
        XCTAssertNil(server.hostKeyFingerprint)
    }

    // MARK: - Known Host (Matching Fingerprint)

    func testKnownHostConnectsDirectly() async throws {
        let ssh = HostKeyMockSSHService()
        ssh.mockExecResults["tmux -V"] = "tmux 3.4\n"
        ssh.mockExecResults["tmux list-sessions"] = "$0:main:1:0"
        let manager = ConnectionManager(sshService: ssh)
        let server = makeServer(fingerprint: ssh.serverFingerprint)

        let sessions = try await manager.connect(server: server, password: "p")

        XCTAssertEqual(manager.state, .sessionList)
        XCTAssertEqual(sessions.count, 1)
        // No fingerprint prompt needed.
        XCTAssertNil(manager.pendingFingerprint)
    }

    // MARK: - Fingerprint Mismatch

    func testFingerprintMismatchShowsWarning() async throws {
        let ssh = HostKeyMockSSHService()
        ssh.serverFingerprint = "SHA256:newkey123"
        ssh.mockExecResults["tmux -V"] = "tmux 3.4\n"
        ssh.mockExecResults["tmux list-sessions"] = "$0:main:1:0"
        let manager = ConnectionManager(sshService: ssh)
        let server = makeServer(fingerprint: "SHA256:oldkey456")

        let connectTask = Task<Void, Error> {
            _ = try await manager.connect(server: server, password: "p")
        }

        try await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(manager.showFingerprintMismatchAlert)
        XCTAssertNotNil(manager.mismatchFingerprint)
        XCTAssertEqual(manager.mismatchFingerprint?.expected, "SHA256:oldkey456")
        XCTAssertEqual(manager.mismatchFingerprint?.actual, "SHA256:newkey123")

        // Simulate user accepting the new key.
        manager.pendingFingerprintAction?(true)

        try await connectTask.value

        XCTAssertEqual(manager.state, .sessionList)
        XCTAssertEqual(server.hostKeyFingerprint, "SHA256:newkey123")
    }

    func testFingerprintMismatchRejectionDisconnects() async throws {
        let ssh = HostKeyMockSSHService()
        ssh.serverFingerprint = "SHA256:newkey123"
        let manager = ConnectionManager(sshService: ssh)
        let server = makeServer(fingerprint: "SHA256:oldkey456")

        let connectTask = Task<Void, Error> {
            _ = try await manager.connect(server: server, password: "p")
        }

        try await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(manager.showFingerprintMismatchAlert)

        // Simulate user rejecting the new key.
        manager.pendingFingerprintAction?(false)

        do {
            try await connectTask.value
            XCTFail("Expected SSHHostKeyError")
        } catch is SSHHostKeyError {
            // Expected
        }

        XCTAssertEqual(manager.state, .disconnected)
        // Fingerprint should NOT have been updated.
        XCTAssertEqual(server.hostKeyFingerprint, "SHA256:oldkey456")
    }
}
