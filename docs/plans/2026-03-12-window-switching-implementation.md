# Window Switching Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix window switching so tapping a different window pill immediately transitions the terminal view with a contextual placeholder.

**Architecture:** Optimistic local state update in `ConnectionManager` (clear `currentPanes`, set `activeWindowId`) + stale `%layout-change` guard + contextual placeholder message in `TerminalSessionView`.

**Tech Stack:** Swift, SwiftUI, XCTest

**Spec:** `docs/plans/2026-03-12-window-switching-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `ios/Muxi/Services/ConnectionManager.swift` | Modify | Add `switchingToWindowId`, update `selectWindow()`/`selectWindowAndPane()`, add guard in `onLayoutChange` |
| `ios/Muxi/Views/Terminal/TerminalSessionView.swift` | Modify | Branch placeholder message, simplify `onSelectWindowAndPane` callback |
| `ios/MuxiTests/Services/WindowTrackingTests.swift` | Modify | Add tests for optimistic update, same-window no-op, stale layout-change guard |

---

## Task 1: Add `switchingToWindowId` property and optimistic update in `selectWindow()`

**Files:**
- Modify: `ios/Muxi/Services/ConnectionManager.swift:92` (add property after `activeWindowId`)
- Modify: `ios/Muxi/Services/ConnectionManager.swift:669-673` (update `selectWindow()`)
- Test: `ios/MuxiTests/Services/WindowTrackingTests.swift`

- [ ] **Step 1: Write failing tests for optimistic window switch**

Add to `WindowTrackingTests.swift` after the existing `testSelectWindowRequiresAttachedState` test (line 138):

```swift
func testSelectWindowOptimisticUpdate() async throws {
    let manager = makeConnectedManager()
    manager.setWindowsForTesting([
        .init(id: "@0", name: "bash", paneIds: ["%0"], isActive: true),
        .init(id: "@1", name: "vim", paneIds: ["%1"], isActive: false),
    ], activeId: "@0")
    manager.setStateForTesting(.attached(sessionName: "work"))
    manager.activePaneId = "%0"

    try await manager.selectWindow("@1")

    // Optimistic: activeWindowId switches immediately
    XCTAssertEqual(manager.activeWindowId, "@1")
    // Panes cleared to trigger placeholder
    XCTAssertTrue(manager.currentPanes.isEmpty)
    // activePaneId cleared
    XCTAssertNil(manager.activePaneId)
    // Transition flag set
    XCTAssertEqual(manager.switchingToWindowId, "@1")
}

func testSelectWindowSameWindowIsNoop() async throws {
    let manager = makeConnectedManager()
    manager.setWindowsForTesting([
        .init(id: "@0", name: "bash", paneIds: ["%0"], isActive: true),
    ], activeId: "@0")
    manager.setStateForTesting(.attached(sessionName: "work"))
    manager.activePaneId = "%0"

    try await manager.selectWindow("@0")

    // No change — same window
    XCTAssertEqual(manager.activeWindowId, "@0")
    XCTAssertEqual(manager.activePaneId, "%0")
    XCTAssertNil(manager.switchingToWindowId)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/lmuffin/Documents/Workspace/Muxi/ios && xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' -only-testing:MuxiTests/WindowTrackingTests 2>&1 | tail -20`

Expected: Compilation error — `switchingToWindowId` does not exist.

- [ ] **Step 3: Add `switchingToWindowId` property**

In `ConnectionManager.swift`, after line 92 (`private(set) var activeWindowId: String?`), add:

```swift
/// Set during a window switch; cleared when the matching `%layout-change` arrives.
private(set) var switchingToWindowId: String?
```

- [ ] **Step 4: Update `selectWindow()` with optimistic state**

Replace `ConnectionManager.swift` lines 668-673:

```swift
/// Switch to a specific window by ID.
/// Optimistically updates local state and clears panes to show placeholder.
func selectWindow(_ windowId: String) async throws {
    guard case .attached = state else { return }
    guard windowId != activeWindowId else { return }

    // Optimistic update
    switchingToWindowId = windowId
    activeWindowId = windowId
    currentPanes = []
    activePaneId = nil
    scrolledBackPanes = []

    try await sendControlCommand(
        "select-window -t \(windowId.shellEscaped())\n", type: .ignored)
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd /Users/lmuffin/Documents/Workspace/Muxi/ios && xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' -only-testing:MuxiTests/WindowTrackingTests 2>&1 | tail -20`

Expected: All tests PASS (including existing tests).

- [ ] **Step 6: Commit**

```bash
git add ios/Muxi/Services/ConnectionManager.swift ios/MuxiTests/Services/WindowTrackingTests.swift
git commit -m "feat: optimistic state update in selectWindow()"
```

---

## Task 2: Update `selectWindowAndPane()` and add `onLayoutChange` guard

**Files:**
- Modify: `ios/Muxi/Services/ConnectionManager.swift:676-682` (update `selectWindowAndPane()`)
- Modify: `ios/Muxi/Services/ConnectionManager.swift:1008-1010` (add guard in `onLayoutChange`)
- Test: `ios/MuxiTests/Services/WindowTrackingTests.swift`

- [ ] **Step 1: Write failing tests**

Add to `WindowTrackingTests.swift`:

```swift
func testSelectWindowAndPaneOptimisticUpdate() async throws {
    let manager = makeConnectedManager()
    manager.setWindowsForTesting([
        .init(id: "@0", name: "bash", paneIds: ["%0"], isActive: true),
        .init(id: "@1", name: "vim", paneIds: ["%1"], isActive: false),
    ], activeId: "@0")
    manager.setStateForTesting(.attached(sessionName: "work"))
    manager.activePaneId = "%0"

    try await manager.selectWindowAndPane(windowId: "@1", paneId: "%1")

    XCTAssertEqual(manager.activeWindowId, "@1")
    XCTAssertTrue(manager.currentPanes.isEmpty)
    XCTAssertNil(manager.activePaneId)
    XCTAssertEqual(manager.switchingToWindowId, "@1")
}

func testSelectWindowAndPaneSameWindowOnlyChangesPane() async throws {
    let manager = makeConnectedManager()
    manager.setWindowsForTesting([
        .init(id: "@0", name: "bash", paneIds: ["%0", "%1"], isActive: true),
    ], activeId: "@0")
    manager.setStateForTesting(.attached(sessionName: "work"))
    manager.activePaneId = "%0"

    try await manager.selectWindowAndPane(windowId: "@0", paneId: "%1")

    // Same window — no placeholder, just pane switch
    XCTAssertEqual(manager.activeWindowId, "@0")
    XCTAssertEqual(manager.activePaneId, "%1")
    XCTAssertNil(manager.switchingToWindowId)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/lmuffin/Documents/Workspace/Muxi/ios && xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' -only-testing:MuxiTests/WindowTrackingTests 2>&1 | tail -20`

Expected: FAIL — `selectWindowAndPane` does not clear panes or set `switchingToWindowId`.

- [ ] **Step 3: Update `selectWindowAndPane()`**

Replace `ConnectionManager.swift` lines 675-682:

```swift
/// Switch to a specific window and pane.
/// If the target is in a different window, applies optimistic update (clears panes).
/// If the target is in the same window, only switches the active pane.
func selectWindowAndPane(windowId: String, paneId: String) async throws {
    guard case .attached = state else { return }

    if windowId != activeWindowId {
        // Cross-window switch — optimistic update
        switchingToWindowId = windowId
        activeWindowId = windowId
        currentPanes = []
        activePaneId = nil
        scrolledBackPanes = []

        try await sendControlCommand(
            "select-window -t \(windowId.shellEscaped())\n", type: .ignored)
        try await sendControlCommand(
            "select-pane -t \(paneId.shellEscaped())\n", type: .ignored)
    } else {
        // Same-window pane switch — immediate
        activePaneId = paneId
        try await sendControlCommand(
            "select-pane -t \(paneId.shellEscaped())\n", type: .ignored)
    }
}
```

- [ ] **Step 4: Add `onLayoutChange` guard for stale layout-change**

In `ConnectionManager.swift`, at the top of the `onLayoutChange` callback (line 1008-1009), add a guard:

```swift
tmuxService.onLayoutChange = { [weak self] windowId, panes in
    guard let self else { return }

    // During a window switch, ignore layout-change from non-target windows.
    if let target = self.switchingToWindowId, windowId != target {
        return
    }
    // Clear transition flag — target window's layout arrived.
    self.switchingToWindowId = nil

    self.currentPanes = panes
    // ... rest of existing code unchanged ...
```

- [ ] **Step 5: Add test helpers to ConnectionManager**

In `ConnectionManager.swift`, inside the `#if DEBUG` block (after `setWindowsForTesting`, around line 69), add:

```swift
/// Test-only: wire up tmux callbacks so `simulateLayoutChange` works.
func wireCallbacksForTesting() {
    wireCallbacks()
}

/// Test-only: simulate a `%layout-change` callback as if tmux sent it.
func simulateLayoutChange(windowId: String, panes: [TmuxControlService.ParsedPane]) {
    tmuxService.onLayoutChange?(windowId, panes)
}
```

- [ ] **Step 6: Write tests for stale layout-change guard and full lifecycle**

Add to `WindowTrackingTests.swift`:

```swift
func testLayoutChangeGuardIgnoresStaleWindow() async throws {
    let manager = makeConnectedManager()
    manager.wireCallbacksForTesting()
    manager.setWindowsForTesting([
        .init(id: "@0", name: "bash", paneIds: ["%0"], isActive: true),
        .init(id: "@1", name: "vim", paneIds: ["%1"], isActive: false),
    ], activeId: "@0")
    manager.setStateForTesting(.attached(sessionName: "work"))
    manager.activePaneId = "%0"

    // Begin switch to @1
    try await manager.selectWindow("@1")
    XCTAssertEqual(manager.switchingToWindowId, "@1")

    // Stale layout-change from @0 arrives — should be ignored
    let stalePanes = [TmuxControlService.ParsedPane(x: 0, y: 0, width: 80, height: 24, paneId: 0)]
    manager.simulateLayoutChange(windowId: "@0", panes: stalePanes)

    // Still transitioning — stale panes NOT applied
    XCTAssertTrue(manager.currentPanes.isEmpty)
    XCTAssertEqual(manager.switchingToWindowId, "@1")
}

func testLayoutChangeResolvesTransition() async throws {
    let manager = makeConnectedManager()
    manager.wireCallbacksForTesting()
    manager.setWindowsForTesting([
        .init(id: "@0", name: "bash", paneIds: ["%0"], isActive: true),
        .init(id: "@1", name: "vim", paneIds: ["%1"], isActive: false),
    ], activeId: "@0")
    manager.setStateForTesting(.attached(sessionName: "work"))
    manager.activePaneId = "%0"

    // Begin switch to @1
    try await manager.selectWindow("@1")

    // Matching layout-change arrives
    let targetPanes = [TmuxControlService.ParsedPane(x: 0, y: 0, width: 80, height: 24, paneId: 1)]
    manager.simulateLayoutChange(windowId: "@1", panes: targetPanes)

    // Transition resolved
    XCTAssertNil(manager.switchingToWindowId)
    XCTAssertEqual(manager.currentPanes.count, 1)
    XCTAssertEqual(manager.activePaneId, "%1")
    XCTAssertEqual(manager.activeWindowId, "@1")
}
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `cd /Users/lmuffin/Documents/Workspace/Muxi/ios && xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' -only-testing:MuxiTests/WindowTrackingTests 2>&1 | tail -20`

Expected: All tests PASS.

- [ ] **Step 8: Commit**

```bash
git add ios/Muxi/Services/ConnectionManager.swift ios/MuxiTests/Services/WindowTrackingTests.swift
git commit -m "feat: optimistic update in selectWindowAndPane() + onLayoutChange guard"
```

---

## Task 3: Update TerminalSessionView placeholder and callbacks

**Files:**
- Modify: `ios/Muxi/Views/Terminal/TerminalSessionView.swift:112-118` (simplify `onSelectWindowAndPane`)
- Modify: `ios/Muxi/Views/Terminal/TerminalSessionView.swift:284-295` (branch placeholder message)

- [ ] **Step 1: Update `placeholderView` with contextual message**

Replace `TerminalSessionView.swift` lines 284-295:

```swift
private var placeholderView: some View {
    VStack {
        Spacer()
        ProgressView()
        Text(connectionManager.switchingToWindowId != nil
            ? "Switching window..."
            : "Attaching to \(sessionName)...")
            .font(MuxiTokens.Typography.caption)
            .foregroundStyle(MuxiTokens.Colors.textSecondary)
            .padding(.top, MuxiTokens.Spacing.sm)
        Spacer()
    }
    .frame(maxWidth: .infinity)
}
```

- [ ] **Step 2: Simplify `onSelectWindowAndPane` callback**

Replace `TerminalSessionView.swift` lines 112-118:

```swift
onSelectWindowAndPane: { windowId, paneId in
    isKeyboardActive = true
    Task {
        try? await connectionManager.selectWindowAndPane(
            windowId: windowId, paneId: paneId)
    }
},
```

(Removed `connectionManager.activePaneId = paneId` — now managed by CM.)

- [ ] **Step 3: Build and run all tests**

Run: `cd /Users/lmuffin/Documents/Workspace/Muxi/ios && xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' 2>&1 | tail -30`

Expected: All tests PASS, build succeeds.

- [ ] **Step 4: Commit**

```bash
git add ios/Muxi/Views/Terminal/TerminalSessionView.swift
git commit -m "ui: contextual placeholder message + simplify window/pane callbacks"
```
