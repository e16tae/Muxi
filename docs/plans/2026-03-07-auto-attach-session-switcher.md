# Auto-Attach & Session Switcher Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Skip the session list screen — auto-attach to the last-used (or first) session on connect, and provide a toolbar dropdown for switching sessions without leaving the terminal.

**Architecture:** Remove the `.sessionList` intermediate state from `ConnectionState`. The `connect()` method now goes directly to `.attached` by auto-selecting a session. Session switching uses detach+reattach internally. A `UserDefaults`-backed store remembers the last session per server.

**Tech Stack:** SwiftUI (Menu, toolbar), UserDefaults, Swift Testing, existing tmux control mode infrastructure.

---

## State Machine Change

```
BEFORE: disconnected → connecting → sessionList → attached → reconnecting
AFTER:  disconnected → connecting → attached → reconnecting
```

- `.sessionList` state is removed entirely
- `connect()` auto-selects and attaches in one step
- `detach()` becomes full disconnect (back to server list)
- New `switchSession(to:)` for in-terminal session changing

---

### Task 1: LastSessionStore — Per-Server Session Persistence

**Files:**
- Create: `ios/Muxi/Services/LastSessionStore.swift`
- Test: `ios/MuxiTests/LastSessionStoreTests.swift`

**Step 1: Write the failing tests**

```swift
import Testing
@testable import Muxi
import Foundation

@Suite("LastSessionStore")
struct LastSessionStoreTests {
    let store = LastSessionStore(defaults: UserDefaults(suiteName: "test.LastSessionStore")!)

    init() {
        // Clean slate for each test
        store.defaults.removePersistentDomain(forName: "test.LastSessionStore")
    }

    @Test("Returns nil for unknown server")
    func unknownServer() {
        #expect(store.lastSessionName(forServerID: "unknown") == nil)
    }

    @Test("Saves and retrieves session name")
    func saveAndRetrieve() {
        let serverID = "server-1"
        store.save(sessionName: "main", forServerID: serverID)
        #expect(store.lastSessionName(forServerID: serverID) == "main")
    }

    @Test("Overwrites previous value")
    func overwrite() {
        let serverID = "server-1"
        store.save(sessionName: "main", forServerID: serverID)
        store.save(sessionName: "dev", forServerID: serverID)
        #expect(store.lastSessionName(forServerID: serverID) == "dev")
    }

    @Test("Isolates per server")
    func perServer() {
        store.save(sessionName: "main", forServerID: "s1")
        store.save(sessionName: "work", forServerID: "s2")
        #expect(store.lastSessionName(forServerID: "s1") == "main")
        #expect(store.lastSessionName(forServerID: "s2") == "work")
    }

    @Test("Clears session for server")
    func clear() {
        store.save(sessionName: "main", forServerID: "s1")
        store.clear(forServerID: "s1")
        #expect(store.lastSessionName(forServerID: "s1") == nil)
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `cd ios && swift test --package-path MuxiCore 2>&1 || true`
Then: `xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MuxiTests/LastSessionStoreTests -quiet 2>&1 | tail -20`
Expected: FAIL — `LastSessionStore` not found

**Step 3: Implement LastSessionStore**

```swift
import Foundation

/// Persists the last-used tmux session name per server in UserDefaults.
/// On reconnect or fresh connect, the app uses this to auto-attach
/// to the session the user was last working in.
struct LastSessionStore {
    let defaults: UserDefaults

    private static let keyPrefix = "lastSession."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func lastSessionName(forServerID serverID: String) -> String? {
        defaults.string(forKey: Self.keyPrefix + serverID)
    }

    func save(sessionName: String, forServerID serverID: String) {
        defaults.set(sessionName, forKey: Self.keyPrefix + serverID)
    }

    func clear(forServerID serverID: String) {
        defaults.removeObject(forKey: Self.keyPrefix + serverID)
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MuxiTests/LastSessionStoreTests -quiet 2>&1 | tail -20`
Expected: All 5 tests PASS

**Step 5: Commit**

```bash
git add ios/Muxi/Services/LastSessionStore.swift ios/MuxiTests/LastSessionStoreTests.swift
git commit -m "feat: add LastSessionStore for per-server session persistence"
```

---

### Task 2: ConnectionState — Remove `.sessionList`

**Files:**
- Modify: `ios/Muxi/Services/ConnectionManager.swift` (state enum, lines 12-18)

**Step 1: Remove `.sessionList` from the enum**

Change `ConnectionState` from:
```swift
enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case sessionList
    case attached(sessionName: String)
    case reconnecting
}
```

To:
```swift
enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case attached(sessionName: String)
    case reconnecting
}
```

**Step 2: Fix all compilation errors**

The compiler will show every reference to `.sessionList`. Fix each one:

- `connect()`: Remove `state = .sessionList` — will be replaced in Task 3
- `detach()`: Change `state = .sessionList` → `disconnect()` call — will be updated in Task 4
- `attachSession()`: Remove `guard state == .sessionList` — will be refactored in Task 3
- `reconnect()`: Remove `.sessionList` transition — will be updated in Task 5
- `ContentView.swift`: Remove `case .sessionList:` — will be updated in Task 6

**Note:** This task intentionally breaks compilation. Tasks 3-6 fix it incrementally. If you prefer, combine Tasks 2-6 into a single step. The separation here is for clarity.

**Step 3: Commit (only if compiles)**

```bash
git add ios/Muxi/Services/ConnectionManager.swift
git commit -m "refactor: remove .sessionList from ConnectionState"
```

---

### Task 3: ConnectionManager — Auto-Attach on Connect

**Files:**
- Modify: `ios/Muxi/Services/ConnectionManager.swift`

**Step 1: Add `lastSessionStore` property**

At the top of `ConnectionManager`, add:
```swift
let lastSessionStore = LastSessionStore()
```

**Step 2: Extract `performAttach()` from `attachSession()`**

Create a private method that contains the core attach logic (currently in `attachSession()`), without the `.sessionList` state guard:

```swift
/// Core attach logic — wire callbacks, open shell, send tmux attach command.
/// Callers must ensure cleanup of previous channel before calling.
private func performAttach(sessionName: String) async throws {
    wireCallbacks()
    let channel = try await sshService.startShell(onData: { [weak self] data in
        Task { @MainActor in
            self?.tmuxService.feed(data)
        }
    })
    activeChannel = channel
    let escapedName = sessionName.shellEscaped()
    try await sshServiceForWrites.writeToChannel(
        Data("tmux -CC attach -t \(escapedName)\n".utf8)
    )
    state = .attached(sessionName: sessionName)
    pendingInitialResize = true
    try await sshServiceForWrites.writeToChannel(
        Data("refresh-client -C 80,24\n".utf8)
    )
    startSSHMonitor()
}
```

Refactor the existing `attachSession(_:)` to call `performAttach()`:
```swift
func attachSession(_ session: TmuxSession) async throws {
    await detachTask?.value
    try await performAttach(sessionName: session.name)
    // Save as last-used session
    if let serverID = currentServer?.id.uuidString {
        lastSessionStore.save(sessionName: session.name, forServerID: serverID)
    }
}
```

**Step 3: Modify `connect()` to auto-attach**

Replace the end of `connect()` (where it sets `state = .sessionList` and returns sessions) with auto-select logic:

```swift
func connect(server: Server, password: String? = nil) async throws {
    guard state == .disconnected else { return }
    state = .connecting
    currentServer = server
    // ... existing SSH connect + tmux check + session query logic ...

    let sessions = TmuxControlService.parseFormattedSessionList(output)
    self.sessions = sessions

    // Auto-select session: last-used > first available > create new
    let targetSession: String
    let serverID = server.id.uuidString

    if let lastUsed = lastSessionStore.lastSessionName(forServerID: serverID),
       sessions.contains(where: { $0.name == lastUsed }) {
        targetSession = lastUsed
    } else if let first = sessions.first {
        targetSession = first.name
    } else {
        // No sessions — create one
        let escapedName = "main".shellEscaped()
        _ = try await sshService.execCommand("tmux new-session -d -s \(escapedName)")
        targetSession = "main"
        // Re-query sessions to populate self.sessions
        let refreshed = try await sshService.execCommand(
            "tmux list-sessions -F '#{session_id}:#{session_name}:#{session_windows}:#{session_activity}'"
        )
        self.sessions = TmuxControlService.parseFormattedSessionList(refreshed)
    }

    try await performAttach(sessionName: targetSession)

    // Save the attached session
    lastSessionStore.save(sessionName: targetSession, forServerID: serverID)
}
```

**Step 4: Build to verify**

Run: `xcodebuild build -project Muxi.xcodeproj -scheme Muxi -destination 'generic/platform=iOS Simulator' -quiet 2>&1 | grep error:`
Expected: Remaining errors are in ContentView.swift (`.sessionList` references) — fixed in Task 6

**Step 5: Commit**

```bash
git add ios/Muxi/Services/ConnectionManager.swift
git commit -m "feat: auto-attach to session on connect, skip session list"
```

---

### Task 4: ConnectionManager — switchSession() and Detach-as-Disconnect

**Files:**
- Modify: `ios/Muxi/Services/ConnectionManager.swift`

**Step 1: Add `switchSession(to:)` method**

```swift
/// Switch to a different tmux session from within the terminal.
/// Detaches the current control mode client and reattaches to the new session.
func switchSession(to sessionName: String) async throws {
    guard case .attached = state else { return }

    // Clean up current session
    sshMonitorTask?.cancel()
    sshMonitorTask = nil
    tmuxService.reset()
    paneBuffers.removeAll()
    currentPanes.removeAll()
    scrolledBackPanes.removeAll()
    paneHasNewOutput.removeAll()

    if let channel = activeChannel {
        activeChannel = nil
        Task { try? await channel.close() }
    }
    // Small delay to let channel close propagate
    try await Task.sleep(for: .milliseconds(100))

    // Attach to new session
    try await performAttach(sessionName: sessionName)

    // Save as last-used
    if let serverID = currentServer?.id.uuidString {
        lastSessionStore.save(sessionName: sessionName, forServerID: serverID)
    }
}
```

**Step 2: Add `refreshSessionList()` for dropdown population**

```swift
/// Re-query tmux sessions from the server. Used to populate the session switcher.
func refreshSessionList() async throws -> [TmuxSession] {
    let output = try await sshService.execCommand(
        "tmux list-sessions -F '#{session_id}:#{session_name}:#{session_windows}:#{session_activity}'"
    )
    let refreshed = TmuxControlService.parseFormattedSessionList(output)
    self.sessions = refreshed
    return refreshed
}
```

**Step 3: Add `createAndSwitchToNewSession(name:)` for "+" button**

```swift
/// Create a new tmux session and switch to it.
func createAndSwitchToNewSession(name: String) async throws {
    let escapedName = name.shellEscaped()
    _ = try await sshService.execCommand("tmux new-session -d -s \(escapedName)")
    try await refreshSessionList()
    try await switchSession(to: name)
}
```

**Step 4: Update `detach()` to fully disconnect**

Change `detach()` to call `disconnect()`:
```swift
/// Disconnect from the server entirely (returns to server list).
func detach() {
    disconnect()
}
```

Or simply replace all `detach()` call sites with `disconnect()` and remove `detach()`.

**Step 5: Build to verify**

Run: `xcodebuild build -project Muxi.xcodeproj -scheme Muxi -destination 'generic/platform=iOS Simulator' -quiet 2>&1 | grep error:`

**Step 6: Commit**

```bash
git add ios/Muxi/Services/ConnectionManager.swift
git commit -m "feat: add session switching and convert detach to full disconnect"
```

---

### Task 5: ConnectionManager — Update Reconnect & Lifecycle

**Files:**
- Modify: `ios/Muxi/Services/ConnectionManager.swift` (reconnect method ~lines 434-504, handleBackground/handleForeground)

**Step 1: Update `reconnect()` to skip `.sessionList`**

In the reconnect loop, after refreshing sessions and finding the previous session still exists, directly call `performAttach()` instead of transitioning through `.sessionList` + `attachSession()`:

```swift
// Inside reconnect(), replace:
//   state = .sessionList
//   try await attachSession(matchingSession)
// With:
try await performAttach(sessionName: previousSessionName)
if let serverID = currentServer?.id.uuidString {
    lastSessionStore.save(sessionName: previousSessionName, forServerID: serverID)
}
```

If the previous session doesn't exist, fall back to first available session:
```swift
if sessions.contains(where: { $0.name == previousSessionName }) {
    try await performAttach(sessionName: previousSessionName)
} else if let first = sessions.first {
    try await performAttach(sessionName: first.name)
    if let serverID = currentServer?.id.uuidString {
        lastSessionStore.save(sessionName: first.name, forServerID: serverID)
    }
} else {
    // No sessions at all — disconnect
    state = .disconnected
    return
}
```

**Step 2: Verify `handleBackground()` and `handleForeground()` still work**

`handleBackground()` stores the session name and calls disconnect — this should work as-is since `.attached(sessionName:)` hasn't changed.

`handleForeground()` calls `reconnect()` — updated above.

**Step 3: Build and run tests**

Run: `xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet 2>&1 | tail -20`

**Step 4: Commit**

```bash
git add ios/Muxi/Services/ConnectionManager.swift
git commit -m "fix: update reconnect flow to skip removed sessionList state"
```

---

### Task 6: TerminalSessionView — Session Switcher Dropdown

**Files:**
- Modify: `ios/Muxi/Views/Terminal/TerminalSessionView.swift` (toolbar section)

**Step 1: Add session list state and refresh**

Add state properties to TerminalSessionView:
```swift
@State private var availableSessions: [TmuxSession] = []
@State private var showNewSessionAlert = false
@State private var newSessionName = ""
```

**Step 2: Replace static session name with Menu dropdown**

In the toolbar HStack, replace the static `Text(sessionName)` with:

```swift
Menu {
    ForEach(availableSessions) { session in
        Button {
            Task {
                try? await connectionManager.switchSession(to: session.name)
            }
        } label: {
            HStack {
                Text(session.name)
                if session.name == sessionName {
                    Image(systemName: "checkmark")
                }
            }
        }
    }

    Divider()

    Button {
        showNewSessionAlert = true
    } label: {
        Label("New Session", systemImage: "plus")
    }
} label: {
    HStack(spacing: MuxiTokens.Spacing.xs) {
        Text(sessionName)
            .font(MuxiTokens.Typography.title)
            .foregroundStyle(MuxiTokens.Colors.textPrimary)
        Image(systemName: "chevron.down")
            .font(.caption)
            .foregroundStyle(MuxiTokens.Colors.textSecondary)
    }
}
.onAppear {
    Task { availableSessions = (try? await connectionManager.refreshSessionList()) ?? [] }
}
```

**Step 3: Add new session alert**

Add to the view's modifier chain:
```swift
.alert("New Session", isPresented: $showNewSessionAlert) {
    TextField("Session name", text: $newSessionName)
    Button("Create") {
        let name = newSessionName.trimmingCharacters(in: .whitespaces)
        newSessionName = ""
        guard !name.isEmpty else { return }
        Task { try? await connectionManager.createAndSwitchToNewSession(name: name) }
    }
    Button("Cancel", role: .cancel) { newSessionName = "" }
}
```

**Step 4: Refresh sessions when Menu opens**

SwiftUI `Menu` doesn't have an `onOpen` callback. Add a `.task` modifier that refreshes periodically or on appear:
```swift
.task(id: sessionName) {
    availableSessions = (try? await connectionManager.refreshSessionList()) ?? []
}
```

This refreshes whenever the session name changes (i.e., after a switch).

**Step 5: Update Detach button label to "Disconnect"**

```swift
Button("Disconnect") {
    connectionManager.disconnect()
}
```

**Step 6: Build and install on simulator**

Run:
```bash
xcodebuild build -project Muxi.xcodeproj -scheme Muxi -destination 'generic/platform=iOS Simulator' -quiet 2>&1 | grep error:
```

**Step 7: Commit**

```bash
git add ios/Muxi/Views/Terminal/TerminalSessionView.swift
git commit -m "feat: add session switcher dropdown in terminal toolbar"
```

---

### Task 7: ContentView — Remove Session List Screen

**Files:**
- Modify: `ios/Muxi/App/ContentView.swift`

**Step 1: Remove `.sessionList` case from body switch**

Delete the entire `case .sessionList:` block and the `sessionListNavigation` computed property (lines ~179-202).

**Step 2: Remove `sessionListViewModel` state property**

Delete `@State private var sessionListViewModel: SessionListViewModel?` and all references to it (in `disconnect()` calls, `.onAppear`, etc.).

**Step 3: Simplify the state switch**

The ContentView body switch becomes:
```swift
switch connectionManager.state {
case .disconnected:
    serverListNavigation

case .connecting:
    serverListNavigation
        .overlay { connectingOverlay }

case .attached(let sessionName):
    TerminalSessionView(
        connectionManager: connectionManager,
        sessionName: sessionName,
        themeManager: themeManager
    )
    .onAppear {
        previousAttachedSession = sessionName
    }

case .reconnecting:
    if let previousSession = previousAttachedSession {
        TerminalSessionView(
            connectionManager: connectionManager,
            sessionName: previousSession,
            themeManager: themeManager
        )
    }
    ReconnectingOverlay(
        attempt: connectionManager.reconnectAttempt,
        maxAttempts: connectionManager.maxReconnectAttempts,
        onCancel: {
            connectionManager.disconnect()
            previousAttachedSession = nil
        }
    )
}
```

**Step 4: Build to verify**

Run: `xcodebuild build -project Muxi.xcodeproj -scheme Muxi -destination 'generic/platform=iOS Simulator' -quiet 2>&1 | grep error:`
Expected: Clean build, no errors

**Step 5: Commit**

```bash
git add ios/Muxi/App/ContentView.swift
git commit -m "refactor: remove session list screen from ContentView"
```

---

### Task 8: Cleanup — Remove SessionListView & ViewModel

**Files:**
- Delete: `ios/Muxi/Views/SessionList/SessionListView.swift`
- Delete: `ios/Muxi/Views/SessionList/SessionRowView.swift` (if exists)
- Delete: `ios/Muxi/ViewModels/SessionListViewModel.swift`
- Delete: `ios/MuxiTests/SessionListViewModelTests.swift` (if exists)
- Modify: `ios/project.yml` (only if sources are explicitly listed — currently uses directory glob, so deletion suffices)

**Step 1: Delete the files**

```bash
rm -f ios/Muxi/Views/SessionList/SessionListView.swift
rm -f ios/Muxi/Views/SessionList/SessionRowView.swift
rm -f ios/Muxi/ViewModels/SessionListViewModel.swift
rm -f ios/MuxiTests/SessionListViewModelTests.swift
```

Check if the SessionList directory is now empty and remove it:
```bash
rmdir ios/Muxi/Views/SessionList 2>/dev/null || true
```

**Step 2: Remove `createTmuxSession(name:)` and `deleteTmuxSession(_:)` from ConnectionManager if only used by SessionListViewModel**

Check references first. If `createAndSwitchToNewSession()` (Task 4) replaces `createTmuxSession()`, the old method can be removed. Keep `deleteTmuxSession()` if the dropdown might need it later, or remove if unused.

**Step 3: Regenerate Xcode project**

```bash
cd ios && xcodegen generate
```

**Step 4: Build and run all tests**

```bash
xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet 2>&1 | tail -30
```
Expected: All tests pass, no references to deleted files

**Step 5: Commit**

```bash
git add -A
git commit -m "refactor: remove SessionListView and ViewModel (replaced by toolbar dropdown)"
```

---

### Task 9: Integration Verification

**Steps:**

1. **Build clean**: `xcodebuild clean build -project Muxi.xcodeproj -scheme Muxi -destination 'generic/platform=iOS Simulator' -quiet`
2. **Run all tests**: `xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet`
3. **Install on simulator**: `xcrun simctl install booted <app-path> && xcrun simctl launch booted com.muxi.app`
4. **Manual verification checklist**:
   - [ ] Tap server → connects → terminal appears directly (no session list screen)
   - [ ] Toolbar shows session name with chevron dropdown
   - [ ] Tapping dropdown shows available sessions with checkmark on current
   - [ ] "New Session" creates and switches to a new session
   - [ ] Selecting a different session switches to it
   - [ ] "Disconnect" returns to server list
   - [ ] Keyboard toggle button still works
   - [ ] Reconnecting after connection drop goes directly to terminal
   - [ ] Re-opening app after background resume reconnects to last session
   - [ ] Connecting to a server remembers the last-used session

5. **Final commit** (if any fixes needed)

```bash
git add -A
git commit -m "test: verify auto-attach and session switcher integration"
```

---

## File Change Summary

| Action | File | Description |
|--------|------|-------------|
| Create | `ios/Muxi/Services/LastSessionStore.swift` | UserDefaults wrapper for last session per server |
| Create | `ios/MuxiTests/LastSessionStoreTests.swift` | Unit tests for LastSessionStore |
| Modify | `ios/Muxi/Services/ConnectionManager.swift` | Remove `.sessionList`, add auto-attach, `switchSession()`, `performAttach()` |
| Modify | `ios/Muxi/Views/Terminal/TerminalSessionView.swift` | Session switcher Menu dropdown, "Disconnect" button |
| Modify | `ios/Muxi/App/ContentView.swift` | Remove `.sessionList` case and related code |
| Delete | `ios/Muxi/Views/SessionList/SessionListView.swift` | Replaced by toolbar dropdown |
| Delete | `ios/Muxi/Views/SessionList/SessionRowView.swift` | Replaced by toolbar dropdown |
| Delete | `ios/Muxi/ViewModels/SessionListViewModel.swift` | Logic moved to ConnectionManager |
| Delete | `ios/MuxiTests/SessionListViewModelTests.swift` | Tests for removed code |
