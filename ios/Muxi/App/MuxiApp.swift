import SwiftData
import SwiftUI

@main
struct MuxiApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .tint(MuxiTokens.Colors.accentDefault)
        }
        .modelContainer(for: [Server.self])
    }
}
