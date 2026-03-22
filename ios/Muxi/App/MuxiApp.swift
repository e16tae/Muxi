import SwiftData
import SwiftUI

@main
struct MuxiApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var connectionManager: ConnectionManager
    @State private var tailscaleAccountManager: TailscaleAccountManager

    let modelContainer: ModelContainer = {
        // First try with migration plan (handles V1→V2 for versioned stores)
        do {
            return try ModelContainer(
                for: Server.self,
                migrationPlan: ServerMigrationPlan.self
            )
        } catch {
            // Existing store created without VersionedSchema — try lightweight migration
            // (SwiftData can auto-add nullable columns and ignore removed ones)
            do {
                return try ModelContainer(for: Server.self)
            } catch {
                // Store is truly corrupt — delete and recreate as last resort
                let storeURL = URL.applicationSupportDirectory.appending(path: "default.store")
                for suffix in ["", "-wal", "-shm"] {
                    try? FileManager.default.removeItem(
                        at: storeURL.deletingLastPathComponent().appending(path: "default.store\(suffix)")
                    )
                }
                do {
                    return try ModelContainer(for: Server.self)
                } catch {
                    fatalError("Failed to create ModelContainer after store reset: \(error)")
                }
            }
        }
    }()

    init() {
        let accountManager = TailscaleAccountManager()
        accountManager.migrateIfNeeded()
        _connectionManager = State(initialValue: ConnectionManager(tailscaleAccountManager: accountManager))
        _tailscaleAccountManager = State(initialValue: accountManager)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(connectionManager)
                .environment(tailscaleAccountManager)
                .preferredColorScheme(.dark)
                .tint(MuxiTokens.Colors.accentDefault)
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .background:
                        tailscaleAccountManager.lastConnected =
                            (connectionManager.tailscaleState == .connected)
                        connectionManager.handleBackground()
                    case .active:
                        Task {
                            await autoReconnectTailscaleIfNeeded()
                            connectionManager.handleForeground()
                        }
                    case .inactive:
                        break
                    @unknown default:
                        break
                    }
                }
        }
        .modelContainer(modelContainer)
    }

    private func autoReconnectTailscaleIfNeeded() async {
        guard tailscaleAccountManager.lastConnected,
              tailscaleAccountManager.isConfigured,
              connectionManager.tailscaleState != .connected,
              let account = tailscaleAccountManager.account else { return }
        let authKey: String
        if account.provider == .official {
            authKey = "" // Uses persisted node identity
        } else {
            authKey = tailscaleAccountManager.preAuthKey() ?? ""
        }
        await connectionManager.startTailscale(
            controlURL: account.controlURL,
            authKey: authKey,
            hostname: account.hostname
        )
    }
}
