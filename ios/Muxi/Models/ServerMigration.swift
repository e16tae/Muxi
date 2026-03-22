import Foundation
import SwiftData

// MARK: - Schema V1 (current)

enum ServerSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [ServerV1.self] }

    @Model
    final class ServerV1 {
        @Attribute(.unique) var id: UUID
        var name: String
        var host: String
        var port: UInt16
        var username: String
        var authMethod: AuthMethod
        var agentForwarding: Bool
        var hostKeyFingerprint: String?
        var useTailscale: Bool = false

        init(id: UUID = UUID(), name: String, host: String, port: UInt16 = 22,
             username: String, authMethod: AuthMethod, agentForwarding: Bool = false,
             hostKeyFingerprint: String? = nil) {
            self.id = id; self.name = name; self.host = host; self.port = port
            self.username = username; self.authMethod = authMethod
            self.agentForwarding = agentForwarding; self.hostKeyFingerprint = hostKeyFingerprint
        }
    }
}

// MARK: - Schema V2 (Tailscale UX redesign)

enum ServerSchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] { [Server.self] }
}

// MARK: - Migration Plan

enum ServerMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [ServerSchemaV1.self, ServerSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [migrateV1toV2]
    }

    static let migrateV1toV2 = MigrationStage.custom(
        fromVersion: ServerSchemaV1.self,
        toVersion: ServerSchemaV2.self,
        willMigrate: { context in
            // willMigrate runs on V1 schema. Read useTailscale and mark for migration
            // via UserDefaults, since V1 properties won't be accessible in didMigrate.
            let v1Servers = try context.fetch(FetchDescriptor<ServerSchemaV1.ServerV1>())
            for server in v1Servers where server.useTailscale {
                UserDefaults.standard.set(true, forKey: "migration.tailscale.\(server.id.uuidString)")
            }
        },
        didMigrate: { context in
            // didMigrate runs on V2 schema. Read UserDefaults markers and apply to V2 model.
            let servers = try context.fetch(FetchDescriptor<Server>())
            for server in servers {
                let key = "migration.tailscale.\(server.id.uuidString)"
                if UserDefaults.standard.bool(forKey: key) {
                    server.tailscaleDeviceID = "migrated-\(server.host)"
                    server.tailscaleDeviceName = server.host
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
            try context.save()
        }
    )
}
