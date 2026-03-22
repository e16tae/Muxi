import SwiftData
import SwiftUI

@main
struct MuxiApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var connectionManager = ConnectionManager()

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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(connectionManager)
                .preferredColorScheme(.dark)
                .tint(MuxiTokens.Colors.accentDefault)
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .background:
                        connectionManager.handleBackground()
                    case .active:
                        connectionManager.handleForeground()
                    case .inactive:
                        break
                    @unknown default:
                        break
                    }
                }
        }
        .modelContainer(modelContainer)
    }
}
