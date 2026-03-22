import XCTest
@testable import Muxi

/// Mock SSHService for Tailscale-specific tests.
private final class TailscaleMockSSHService: SSHServiceProtocol {
    var state: SSHConnectionState = .disconnected
    var lastTailscaleFD: Int32?

    func connect(host: String, port: UInt16, username: String, auth: SSHAuth, expectedFingerprint: String? = nil, tailscaleFD: Int32? = nil) async throws {
        lastTailscaleFD = tailscaleFD
        state = .connected
    }

    func disconnect() { state = .disconnected }
    func execCommand(_ command: String) async throws -> String { "" }
    func startShell(onData: @escaping (Data) -> Void) async throws -> SSHChannel {
        fatalError("Not used in these tests")
    }
    func writeToChannel(_ data: Data) async throws {}
    func closeShell() async {}
}

@MainActor
final class ConnectionManagerTailscaleTests: XCTestCase {

    func testConnectWithTailscaleBlockedWhenNotConnected() async {
        let mockSSH = TailscaleMockSSHService()
        let cm = ConnectionManager(sshService: mockSSH)

        let server = Server(name: "ts-server", host: "100.64.0.1", username: "root", authMethod: .password)
        server.tailscaleDeviceID = "node-test"

        do {
            try await cm.connect(server: server, password: "test")
            XCTFail("Expected TailscaleError.notConnected")
        } catch let error as TailscaleError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertNil(mockSSH.lastTailscaleFD, "SSH should not be called when Tailscale is not connected")
    }

    func testConnectWithoutTailscalePassesNilFD() async throws {
        let mockSSH = TailscaleMockSSHService()
        let cm = ConnectionManager(sshService: mockSSH)

        let server = Server(name: "direct-server", host: "192.168.1.1", username: "root", authMethod: .password)
        // tailscaleDeviceID is nil by default — direct connection

        do {
            try await cm.connect(server: server, password: "test")
        } catch {
            // Expected — mock doesn't support full flow
        }
        XCTAssertNil(mockSSH.lastTailscaleFD, "Direct connection should pass nil tailscaleFD")
    }
}
