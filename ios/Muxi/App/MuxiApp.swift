import SwiftData
import SwiftUI

@main
struct MuxiApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [Server.self])
    }
}
