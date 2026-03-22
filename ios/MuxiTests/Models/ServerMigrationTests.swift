import Foundation
import SwiftData
import Testing

@testable import Muxi

@Suite("Server Model V2")
struct ServerMigrationTests {
    @Test("Server with tailscaleDeviceID is Tailscale server")
    func tailscaleDeviceIDIndicatesTailscale() {
        let server = Server(name: "ts", host: "100.64.0.1", username: "root", authMethod: .password)
        server.tailscaleDeviceID = "node-abc123"
        server.tailscaleDeviceName = "my-server"
        #expect(server.tailscaleDeviceID != nil)
        #expect(server.tailscaleDeviceName == "my-server")
    }

    @Test("Server without tailscaleDeviceID is direct server")
    func noTailscaleDeviceIDMeansDirect() {
        let server = Server(name: "direct", host: "192.168.1.1", username: "root", authMethod: .password)
        #expect(server.tailscaleDeviceID == nil)
        #expect(server.tailscaleDeviceName == nil)
    }

    @Test("isTailscale computed property")
    func isTailscaleComputed() {
        let server = Server(name: "ts", host: "100.64.0.1", username: "root", authMethod: .password)
        #expect(server.isTailscale == false)
        server.tailscaleDeviceID = "node-123"
        #expect(server.isTailscale == true)
    }
}
