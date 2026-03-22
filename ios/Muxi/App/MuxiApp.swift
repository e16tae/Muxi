import SwiftData
import SwiftUI

@main
struct MuxiApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var connectionManager: ConnectionManager
    @State private var tailscaleAccountManager: TailscaleAccountManager

    let modelContainer: ModelContainer = {
        do {
            return try ModelContainer(
                for: Server.self,
                migrationPlan: ServerMigrationPlan.self
            )
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }()

    init() {
        let accountManager = TailscaleAccountManager()
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
