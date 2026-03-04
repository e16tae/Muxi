# App Lifecycle Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Gracefully disconnect SSH on background, auto-reconnect + re-attach on foreground return.

**Architecture:** `MuxiApp` observes `ScenePhase`. On `.background`, `ConnectionManager.handleBackground()` cancels the monitor task, saves last connection info, sends tmux detach, and disconnects. On `.active`, `handleForeground()` auto-reconnects using existing `reconnect()` logic if the disconnect was caused by backgrounding.

**Tech Stack:** SwiftUI ScenePhase, ConnectionManager (@MainActor @Observable)

---

### Task 1: Add lifecycle properties to ConnectionManager

**Files:**
- Modify: `ios/Muxi/Services/ConnectionManager.swift`

**Step 1: Add three new properties**

After `private var capturePaneQueue: [String] = []` (line 70), add:

```swift
/// Whether the last disconnect was caused by the app going to background.
/// When true, `handleForeground()` will auto-reconnect.
private(set) var disconnectedByBackground = false

/// The server from the last background disconnect, used for auto-reconnect.
private var lastBackgroundServer: Server?

/// The tmux session name from the last background disconnect.
private var lastBackgroundSession: String?
```

**Step 2: Build to verify**

Run: `xcodebuild build -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,id=7CB9F63E-39E2-43DE-BB29-F21330EE099B' 2>&1 | grep -E '(BUILD|error:)'`
Expected: BUILD SUCCEEDED.

**Step 3: Commit**

```bash
git add ios/Muxi/Services/ConnectionManager.swift
git commit -m "feat: add lifecycle tracking properties to ConnectionManager"
```

---

### Task 2: Implement `handleBackground()`

**Files:**
- Modify: `ios/Muxi/Services/ConnectionManager.swift`

**Step 1: Add `handleBackground()` method**

After the `disconnect()` method (after line 160), add:

```swift
// MARK: - App Lifecycle

/// Called when the app enters background. Saves connection state,
/// cancels the SSH monitor, sends tmux detach, and disconnects.
/// The `disconnectedByBackground` flag tells `handleForeground()`
/// to auto-reconnect when the app returns.
func handleBackground() {
    // Only act if we have an active connection.
    guard state == .attached(sessionName: "") || currentServer != nil else {
        // Check properly — need to extract session name if attached.
        return
    }

    // Save connection info for reconnect.
    if case .attached(let sessionName) = state {
        lastBackgroundServer = currentServer
        lastBackgroundSession = sessionName
        disconnectedByBackground = true

        // Cancel monitor to prevent it from detecting our disconnect
        // and triggering its own reconnect.
        sshMonitorTask?.cancel()
        sshMonitorTask = nil

        // Send tmux detach — single fast write, completes before suspension.
        Task {
            try? await sshService.writeToChannel(Data("detach\n".utf8))
        }

        // Tear down the connection.
        activeChannel = nil
        tmuxService.resetLineBuffer()
        paneBuffers = [:]
        currentPanes = []
        sshService.disconnect()
        state = .disconnected
        sessions = []
        capturePaneQueue = []
        lastSentSize = (0, 0)
        // Note: do NOT clear currentServer or cachedAuth — needed for reconnect.
    } else if state == .sessionList || state == .connecting {
        // Connected but not attached — just disconnect cleanly.
        lastBackgroundServer = currentServer
        lastBackgroundSession = nil
        disconnectedByBackground = true

        sshMonitorTask?.cancel()
        sshMonitorTask = nil
        sshService.disconnect()
        state = .disconnected
        sessions = []
        capturePaneQueue = []
        lastSentSize = (0, 0)
    }
    // If already disconnected, do nothing.
}
```

**Step 2: Build to verify**

Run: `xcodebuild build -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,id=7CB9F63E-39E2-43DE-BB29-F21330EE099B' 2>&1 | grep -E '(BUILD|error:)'`
Expected: BUILD SUCCEEDED.

**Step 3: Commit**

```bash
git add ios/Muxi/Services/ConnectionManager.swift
git commit -m "feat: add handleBackground() for graceful SSH disconnect"
```

---

### Task 3: Implement `handleForeground()`

**Files:**
- Modify: `ios/Muxi/Services/ConnectionManager.swift`

**Step 1: Add `handleForeground()` method**

After `handleBackground()`, add:

```swift
/// Called when the app returns to foreground. Auto-reconnects if the
/// previous disconnect was caused by backgrounding.
func handleForeground() {
    guard disconnectedByBackground else { return }
    disconnectedByBackground = false

    guard let server = lastBackgroundServer ?? currentServer,
          let auth = cachedAuth else {
        // No saved connection info — user will reconnect manually.
        lastBackgroundServer = nil
        lastBackgroundSession = nil
        return
    }

    // Restore state needed by reconnect().
    currentServer = server

    // Extract session name before reconnect clears it.
    let sessionName = lastBackgroundSession

    // Set state to .attached so reconnect() knows to re-attach.
    if let sessionName {
        state = .attached(sessionName: sessionName)
    } else {
        state = .sessionList
    }

    lastBackgroundServer = nil
    lastBackgroundSession = nil

    Task {
        await reconnect()
    }
}
```

**Step 2: Build to verify**

Run: `xcodebuild build -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,id=7CB9F63E-39E2-43DE-BB29-F21330EE099B' 2>&1 | grep -E '(BUILD|error:)'`
Expected: BUILD SUCCEEDED.

**Step 3: Commit**

```bash
git add ios/Muxi/Services/ConnectionManager.swift
git commit -m "feat: add handleForeground() for auto-reconnect on resume"
```

---

### Task 4: Add ScenePhase observation to MuxiApp

**Files:**
- Modify: `ios/Muxi/App/MuxiApp.swift`

**Step 1: Add scenePhase observation**

Replace the entire `MuxiApp.swift` with:

```swift
import SwiftData
import SwiftUI

@main
struct MuxiApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var connectionManager = ConnectionManager()

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
        .modelContainer(for: [Server.self])
    }
}
```

**Important**: Check how `ConnectionManager` is currently created and passed to `ContentView`. If `ContentView` creates its own `ConnectionManager` via `@State`, you need to update `ContentView` to receive it via `@Environment` instead. Read `ContentView.swift` first to understand the current pattern, and adapt accordingly. The key requirement is that `MuxiApp` and `ContentView` share the SAME `ConnectionManager` instance.

**Step 2: Build to verify**

Run: `xcodebuild build -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,id=7CB9F63E-39E2-43DE-BB29-F21330EE099B' 2>&1 | grep -E '(BUILD|error:)'`
Expected: BUILD SUCCEEDED.

**Step 3: Run all tests to verify no regressions**

Run: `xcodebuild test -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,id=7CB9F63E-39E2-43DE-BB29-F21330EE099B' 2>&1 | grep -E '(Executed|FAIL)'`
Expected: All tests pass, no new failures.

**Step 4: Commit**

```bash
git add ios/Muxi/App/MuxiApp.swift ios/Muxi/App/ContentView.swift
git commit -m "feat: observe ScenePhase for background/foreground lifecycle"
```
