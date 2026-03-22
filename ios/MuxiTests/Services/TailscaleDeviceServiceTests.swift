import Testing
import Foundation

@testable import Muxi

@Suite("TailscaleDeviceService")
struct TailscaleDeviceServiceTests {

    @Test("Parse official Tailscale API response")
    func parseOfficialResponse() throws {
        let json = """
        {
            "devices": [
                {
                    "id": "node-abc123",
                    "hostname": "my-server",
                    "addresses": ["100.64.0.1", "fd7a:115c:a1e0::1"],
                    "os": "linux",
                    "online": true,
                    "lastSeen": "2026-03-22T10:00:00Z"
                },
                {
                    "id": "node-def456",
                    "hostname": "my-laptop",
                    "addresses": ["100.64.0.2"],
                    "os": "macOS",
                    "online": false,
                    "lastSeen": "2026-03-21T08:00:00Z"
                }
            ]
        }
        """.data(using: .utf8)!
        let devices = try TailscaleDeviceService.parseOfficialResponse(json)
        #expect(devices.count == 2)
        #expect(devices[0].id == "node-abc123")
        #expect(devices[0].name == "my-server")
        #expect(devices[0].isOnline == true)
        #expect(devices[0].os == "linux")
        #expect(devices[0].ipv4Address == "100.64.0.1")
    }

    @Test("Parse Headscale API response with snake_case keys")
    func parseHeadscaleResponse() throws {
        let json = """
        {
            "machines": [
                {
                    "id": "1",
                    "given_name": "web-server",
                    "ip_addresses": ["100.64.0.10", "fd7a:115c:a1e0::a"],
                    "online": true,
                    "last_seen": "2026-03-22T10:00:00Z"
                }
            ]
        }
        """.data(using: .utf8)!
        let devices = try TailscaleDeviceService.parseHeadscaleResponse(json)
        #expect(devices.count == 1)
        #expect(devices[0].id == "1")
        #expect(devices[0].name == "web-server")
        #expect(devices[0].ipv4Address == "100.64.0.10")
    }

    @Test("Parse Headscale response with integer id")
    func parseHeadscaleIntegerId() throws {
        let json = """
        {
            "machines": [
                {
                    "id": 42,
                    "given_name": "db-server",
                    "ip_addresses": ["100.64.0.20"],
                    "online": true,
                    "last_seen": "2026-03-22T10:00:00Z"
                }
            ]
        }
        """.data(using: .utf8)!
        let devices = try TailscaleDeviceService.parseHeadscaleResponse(json)
        #expect(devices.count == 1)
        #expect(devices[0].id == "42")
    }

    @Test("IPv4 address selection prefers IPv4 over IPv6")
    func ipv4Selection() {
        let device = TailscaleDevice(
            id: "1",
            name: "test",
            addresses: ["fd7a:115c:a1e0::1", "100.64.0.5"],
            isOnline: true,
            os: nil,
            lastSeen: nil
        )
        #expect(device.ipv4Address == "100.64.0.5")
    }

    @Test("IPv4 address falls back to first address if no IPv4")
    func ipv4Fallback() {
        let device = TailscaleDevice(
            id: "1",
            name: "test",
            addresses: ["fd7a:115c:a1e0::1"],
            isOnline: true,
            os: nil,
            lastSeen: nil
        )
        #expect(device.ipv4Address == "fd7a:115c:a1e0::1")
    }

    @Test("Empty addresses returns nil ipv4Address")
    func emptyAddresses() {
        let device = TailscaleDevice(
            id: "1",
            name: "test",
            addresses: [],
            isOnline: true,
            os: nil,
            lastSeen: nil
        )
        #expect(device.ipv4Address == nil)
    }

    @Test("Fractional-second ISO8601 dates are parsed correctly")
    func fractionalSecondDates() throws {
        let json = """
        {
            "devices": [
                {
                    "id": "node-frac",
                    "hostname": "frac-server",
                    "addresses": ["100.64.0.1"],
                    "os": "linux",
                    "online": true,
                    "lastSeen": "2026-03-22T10:00:00.123456Z"
                }
            ]
        }
        """.data(using: .utf8)!
        let devices = try TailscaleDeviceService.parseOfficialResponse(json)
        #expect(devices[0].lastSeen != nil)
    }
}
