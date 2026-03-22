import Foundation
import SwiftData
import Testing

@testable import Muxi

// MARK: - Server Creation Tests

@Suite("Server Model Tests")
struct ServerModelTests {

    @Test("Server creation with password auth uses correct defaults")
    func serverCreationWithPasswordAuth() {
        let server = Server(
            name: "My Server",
            host: "example.com",
            username: "admin",
            authMethod: .password
        )

        #expect(server.name == "My Server")
        #expect(server.host == "example.com")
        #expect(server.port == 22)
        #expect(server.username == "admin")
        #expect(server.authMethod == .password)
        #expect(server.agentForwarding == false)
    }

    @Test("Server creation with key auth stores key ID")
    func serverCreationWithKeyAuth() {
        let keyId = UUID()
        let server = Server(
            name: "Key Server",
            host: "10.0.0.1",
            port: 2222,
            username: "deploy",
            authMethod: .key(keyId: keyId),
            agentForwarding: true
        )

        #expect(server.name == "Key Server")
        #expect(server.host == "10.0.0.1")
        #expect(server.port == 2222)
        #expect(server.username == "deploy")
        #expect(server.authMethod == .key(keyId: keyId))
        #expect(server.agentForwarding == true)
    }

    @Test("isTailscale defaults to false with nil tailscaleDeviceID")
    func isTailscaleDefault() {
        let server = Server(name: "test", host: "10.0.0.1", username: "root", authMethod: .password)
        #expect(server.isTailscale == false)
        #expect(server.tailscaleDeviceID == nil)
    }

    // MARK: - SwiftData Persistence

    @Test("Server persists and fetches from in-memory SwiftData container")
    func serverPersistenceInSwiftData() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Server.self, configurations: config)
        let context = ModelContext(container)

        let serverId = UUID()
        let server = Server(
            id: serverId,
            name: "Persisted",
            host: "db.local",
            port: 5432,
            username: "root",
            authMethod: .password
        )

        context.insert(server)
        try context.save()

        let descriptor = FetchDescriptor<Server>()
        let fetched = try context.fetch(descriptor)

        #expect(fetched.count == 1)
        let first = try #require(fetched.first)
        #expect(first.id == serverId)
        #expect(first.name == "Persisted")
        #expect(first.host == "db.local")
        #expect(first.port == 5432)
        #expect(first.username == "root")
        #expect(first.authMethod == .password)
    }

    // MARK: - AuthMethod Codable Round-Trip

    @Test("AuthMethod.password encodes and decodes correctly")
    func authMethodPasswordCodableRoundTrip() throws {
        let original: AuthMethod = .password
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AuthMethod.self, from: data)
        #expect(decoded == original)
    }

    @Test("AuthMethod.key encodes and decodes correctly")
    func authMethodKeyCodableRoundTrip() throws {
        let keyId = UUID()
        let original: AuthMethod = .key(keyId: keyId)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AuthMethod.self, from: data)
        #expect(decoded == original)
    }
}

// MARK: - SSHKey Tests

@Suite("SSHKey Tests")
struct SSHKeyTests {

    @Test("SSHKey stores metadata correctly")
    func sshKeyCreation() {
        let id = UUID()
        let key = SSHKey(id: id, name: "deploy-key", type: .ed25519)

        #expect(key.id == id)
        #expect(key.name == "deploy-key")
        #expect(key.type == .ed25519)
    }

    @Test("SSHKey Codable round-trip preserves values")
    func sshKeyCodableRoundTrip() throws {
        let original = SSHKey(id: UUID(), name: "rsa-key", type: .rsa)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SSHKey.self, from: data)
        #expect(decoded == original)
    }
}
