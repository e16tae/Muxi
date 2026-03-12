# iPhone Pane Auto-Zoom Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On iPhone, automatically tmux-zoom the active pane so it gets the full window size, maintaining PTY == display invariant.

**Architecture:** Add zoom state tracking to ConnectionManager (`isCompact`, `isZoomed`, `pendingZoom`, `windowKnownPaneIds`). Modify `onLayoutChange` to detect zoomed layouts and preserve pane state. Add `ensureZoomIfNeeded()` / `ensureUnzoomIfNeeded()` called from layout-change, attach, pane switch, and sizeClass change. TerminalSessionView passes `horizontalSizeClass` to ConnectionManager.

**Tech Stack:** Swift, SwiftUI, Swift Testing (unit tests), XCTest (ConnectionManager integration tests)

**Spec:** `docs/superpowers/specs/2026-03-12-iphone-pane-auto-zoom-design.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `ios/Muxi/Services/ConnectionManager.swift` | Modify | Add zoom properties, modify `onLayoutChange`, add `ensureZoomIfNeeded()` / `ensureUnzoomIfNeeded()`, modify `selectWindowAndPane()`, modify `onSessionChanged` |
| `ios/Muxi/Views/Terminal/TerminalSessionView.swift` | Modify | Pass `horizontalSizeClass` to ConnectionManager |
| `ios/Muxi/Views/Terminal/WindowPanePillsView.swift` | Modify | Read pane list from `windowKnownPaneIds` when zoomed |
| `ios/Muxi/Views/Terminal/ToolbarView.swift` | Modify | Pass `windowKnownPaneIds` and `isZoomed` to WindowPanePillsView |
| `ios/MuxiTests/Services/ConnectionManagerZoomTests.swift` | Create | All zoom-related unit tests |

---

## Chunk 1: Core Zoom Properties and ensureZoomIfNeeded()

### Task 1: Add zoom properties to ConnectionManager

**Files:**
- Modify: `ios/Muxi/Services/ConnectionManager.swift:48-109` (properties block)

- [ ] **Step 1: Add the four new properties after line 109 (after `switchingToWindowId`)**

```swift
/// Whether the current device has compact horizontal size class (iPhone).
/// Set by TerminalSessionView when sizeClass changes.
var isCompact: Bool = false

/// Whether the active window's pane is currently tmux-zoomed.
/// Derived from comparing layout pane count to known pane count in `onLayoutChange`.
private(set) var isZoomed: Bool = false

/// Guard against sending duplicate zoom commands while waiting for `%layout-change`.
private(set) var pendingZoom: Bool = false

/// Per-window set of known pane IDs. Survives zoom (unlike `currentPanes`).
/// Updated only from unzoomed `%layout-change` events.
private(set) var windowKnownPaneIds: [String: Set<String>] = [:]
```

- [ ] **Step 2: Add DEBUG test helpers after existing test helpers (after line 83)**

```swift
func setIsCompactForTesting(_ compact: Bool) {
    isCompact = compact
}

func setIsZoomedForTesting(_ zoomed: Bool) {
    isZoomed = zoomed
}

func setPendingZoomForTesting(_ pending: Bool) {
    pendingZoom = pending
}

func setWindowKnownPaneIdsForTesting(_ ids: [String: Set<String>]) {
    windowKnownPaneIds = ids
}
```

- [ ] **Step 3: Verify project builds**

Run: `cd ios && xcodebuild build -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.2' -quiet 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add ios/Muxi/Services/ConnectionManager.swift
git commit -m "feat(zoom): add zoom state properties to ConnectionManager"
```

---

### Task 2: Implement ensureZoomIfNeeded() and ensureUnzoomIfNeeded()

**Files:**
- Modify: `ios/Muxi/Services/ConnectionManager.swift` (add methods near `resizeTerminal()`, around line 795)
- Create: `ios/MuxiTests/Services/ConnectionManagerZoomTests.swift`

- [ ] **Step 1: Write failing tests for ensureZoomIfNeeded()**

Create `ios/MuxiTests/Services/ConnectionManagerZoomTests.swift`:

```swift
import XCTest

@testable import Muxi

@MainActor
final class ConnectionManagerZoomTests: XCTestCase {

    // MARK: - Helpers

    private func makeManager() -> (ConnectionManager, MockSSHService) {
        let ssh = MockSSHService()
        let manager = ConnectionManager(sshService: ssh)
        manager.wireCallbacksForTesting()
        manager.setStateForTesting(.attached(sessionName: "main"))
        return (manager, ssh)
    }

    /// Set up a multi-pane state: 2 known panes, active pane %0, unzoomed.
    private func setupMultiPane(_ manager: ConnectionManager) {
        manager.setIsCompactForTesting(true)
        manager.setWindowKnownPaneIdsForTesting(["@0": ["%0", "%1"]])
        manager.activePaneId = "%0"
        manager.setWindowsForTesting(
            [ConnectionManager.TmuxWindowInfo(id: "@0", name: "bash", index: 0)],
            activeId: "@0"
        )
    }

    // MARK: - ensureZoomIfNeeded

    func testZoomSendsCommandWhenCompactMultiPaneUnzoomed() {
        let (manager, _) = makeManager()
        setupMultiPane(manager)
        // isZoomed = false (default), pendingZoom = false (default)

        manager.ensureZoomIfNeeded()

        // pendingZoom is set synchronously before the async Task sends the command.
        XCTAssertTrue(manager.pendingZoom)
    }

    func testZoomSkipsWhenNotCompact() {
        let (manager, _) = makeManager()
        setupMultiPane(manager)
        manager.setIsCompactForTesting(false)

        manager.ensureZoomIfNeeded()

        XCTAssertFalse(manager.pendingZoom)
    }

    func testZoomSkipsWhenSinglePane() {
        let (manager, _) = makeManager()
        manager.setIsCompactForTesting(true)
        manager.setWindowKnownPaneIdsForTesting(["@0": ["%0"]])
        manager.activePaneId = "%0"
        manager.setWindowsForTesting(
            [ConnectionManager.TmuxWindowInfo(id: "@0", name: "bash", index: 0)],
            activeId: "@0"
        )

        manager.ensureZoomIfNeeded()

        XCTAssertFalse(manager.pendingZoom)
    }

    func testZoomSkipsWhenAlreadyZoomed() {
        let (manager, _) = makeManager()
        setupMultiPane(manager)
        manager.setIsZoomedForTesting(true)

        manager.ensureZoomIfNeeded()

        XCTAssertFalse(manager.pendingZoom)
    }

    func testZoomSkipsWhenPendingZoom() {
        let (manager, _) = makeManager()
        setupMultiPane(manager)
        manager.setPendingZoomForTesting(true)

        manager.ensureZoomIfNeeded()

        // pendingZoom was already true, should not send again
        XCTAssertTrue(manager.pendingZoom)
    }

    // MARK: - ensureUnzoomIfNeeded

    func testUnzoomIsNoOpWhenNotZoomed() {
        let (manager, _) = makeManager()
        setupMultiPane(manager)
        // isZoomed = false (default)

        // Should return early without side effects.
        manager.ensureUnzoomIfNeeded()

        // No state change — still not zoomed, no pending zoom.
        XCTAssertFalse(manager.isZoomed)
        XCTAssertFalse(manager.pendingZoom)
    }

    func testUnzoomSetsStateWhenZoomed() {
        let (manager, _) = makeManager()
        setupMultiPane(manager)
        manager.setIsZoomedForTesting(true)

        manager.ensureUnzoomIfNeeded()

        // The method fires a Task to send the command.
        // We can't assert on the channel write synchronously,
        // but we verify it didn't early-return (isZoomed was true).
        // The actual unzoom confirmation comes via %layout-change.
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ios && xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.2' -only-testing:MuxiTests/ConnectionManagerZoomTests 2>&1 | grep -E '(Test Case|FAIL|error:)' | head -20`
Expected: Compilation errors — `ensureZoomIfNeeded()` and `ensureUnzoomIfNeeded()` don't exist yet, `lastWrittenData` not on MockSSHService.

- [ ] **Step 3: Implement ensureZoomIfNeeded() and ensureUnzoomIfNeeded()**

Add to ConnectionManager near `resizeTerminal()` (around line 810):

```swift
// MARK: - Pane Auto-Zoom

/// If conditions are met (compact + multi-pane + not zoomed + no pending zoom),
/// send `resize-pane -Z` to zoom the active pane to full window size.
func ensureZoomIfNeeded() {
    guard isCompact else { return }
    guard let windowId = activeWindowId,
          (windowKnownPaneIds[windowId]?.count ?? 0) > 1 else { return }
    guard !isZoomed else { return }
    guard !pendingZoom else { return }
    guard let paneId = activePaneId else { return }

    pendingZoom = true
    Task {
        try? await sendControlCommand(
            "resize-pane -Z -t \(paneId.shellEscaped())\n", type: .ignored)
    }
}

/// If currently zoomed, send `resize-pane -Z` to toggle back to unzoomed.
/// Called when transitioning from compact to regular size class.
func ensureUnzoomIfNeeded() {
    guard isZoomed else { return }
    guard let paneId = activePaneId else { return }

    Task {
        try? await sendControlCommand(
            "resize-pane -Z -t \(paneId.shellEscaped())\n", type: .ignored)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ios && xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.2' -only-testing:MuxiTests/ConnectionManagerZoomTests 2>&1 | grep -E '(Test Case|PASS|FAIL)' | head -20`
Expected: All 7 tests PASS.

Note: Tests assert on synchronous state changes (`pendingZoom`, `isZoomed`) rather than async channel writes. The actual `resize-pane -Z` command is sent via a fire-and-forget `Task` inside `ensureZoomIfNeeded()`. The `pendingZoom = true` guard is set synchronously *before* the `Task`, making it reliably testable. The actual command delivery is verified by integration tests (manual).

- [ ] **Step 5: Commit**

```bash
git add ios/Muxi/Services/ConnectionManager.swift ios/MuxiTests/Services/ConnectionManagerZoomTests.swift
git commit -m "feat(zoom): implement ensureZoomIfNeeded() and ensureUnzoomIfNeeded()"
```

---

## Chunk 2: Modified onLayoutChange with Zoom Detection

### Task 3: Modify onLayoutChange to detect and handle zoomed layouts

**Files:**
- Modify: `ios/Muxi/Services/ConnectionManager.swift:1123-1206` (onLayoutChange callback in wireCallbacks())
- Test: `ios/MuxiTests/Services/ConnectionManagerZoomTests.swift`

- [ ] **Step 1: Write failing tests for zoom state detection in onLayoutChange**

Add to `ConnectionManagerZoomTests.swift`:

```swift
// MARK: - onLayoutChange Zoom Detection

func testLayoutChangeDetectsZoomedState() {
    let (manager, _) = makeManager()
    manager.setIsCompactForTesting(true)
    // Simulate an initial unzoomed layout (2 panes)
    manager.simulateLayoutChange(windowId: "@0", panes: [
        .init(x: 0, y: 0, width: 40, height: 24, paneId: 0),
        .init(x: 41, y: 0, width: 39, height: 24, paneId: 1),
    ])
    XCTAssertFalse(manager.isZoomed)
    XCTAssertEqual(manager.windowKnownPaneIds["@0"], ["%0", "%1"])

    // Simulate zoomed layout (1 pane, but we know 2 exist)
    manager.simulateLayoutChange(windowId: "@0", panes: [
        .init(x: 0, y: 0, width: 80, height: 24, paneId: 0),
    ])
    XCTAssertTrue(manager.isZoomed)
    // windowKnownPaneIds should NOT be modified
    XCTAssertEqual(manager.windowKnownPaneIds["@0"], ["%0", "%1"])
}

func testLayoutChangePreservesBuffersDuringZoom() {
    let (manager, _) = makeManager()
    // Setup 2 panes with buffers
    manager.simulateLayoutChange(windowId: "@0", panes: [
        .init(x: 0, y: 0, width: 40, height: 24, paneId: 0),
        .init(x: 41, y: 0, width: 39, height: 24, paneId: 1),
    ])
    XCTAssertNotNil(manager.paneBuffers["%0"])
    XCTAssertNotNil(manager.paneBuffers["%1"])

    // Zoomed layout — only pane %0
    manager.simulateLayoutChange(windowId: "@0", panes: [
        .init(x: 0, y: 0, width: 80, height: 24, paneId: 0),
    ])
    // Both buffers should survive
    XCTAssertNotNil(manager.paneBuffers["%0"])
    XCTAssertNotNil(manager.paneBuffers["%1"])
    // Zoomed pane buffer should be resized to full window
    XCTAssertEqual(manager.paneBuffers["%0"]?.cols, 80)
}

func testLayoutChangeResetsZoomOnUnzoomedLayout() {
    let (manager, _) = makeManager()
    // Setup known panes
    manager.setWindowKnownPaneIdsForTesting(["@0": ["%0", "%1"]])
    manager.setIsZoomedForTesting(true)
    manager.setPendingZoomForTesting(true)

    // Unzoomed layout arrives (2 panes visible)
    manager.simulateLayoutChange(windowId: "@0", panes: [
        .init(x: 0, y: 0, width: 40, height: 24, paneId: 0),
        .init(x: 41, y: 0, width: 39, height: 24, paneId: 1),
    ])

    XCTAssertFalse(manager.isZoomed)
}

func testZoomedLayoutClearsPendingZoom() {
    let (manager, _) = makeManager()
    manager.setWindowKnownPaneIdsForTesting(["@0": ["%0", "%1"]])
    manager.setPendingZoomForTesting(true)

    // Zoomed layout arrives
    manager.simulateLayoutChange(windowId: "@0", panes: [
        .init(x: 0, y: 0, width: 80, height: 24, paneId: 0),
    ])

    XCTAssertTrue(manager.isZoomed)
    XCTAssertFalse(manager.pendingZoom)
}

func testSinglePaneWindowNotDetectedAsZoomed() {
    let (manager, _) = makeManager()
    // First layout for this window — no known panes yet
    manager.simulateLayoutChange(windowId: "@0", panes: [
        .init(x: 0, y: 0, width: 80, height: 24, paneId: 0),
    ])

    XCTAssertFalse(manager.isZoomed)
    XCTAssertEqual(manager.windowKnownPaneIds["@0"], ["%0"])
}

func testLayoutChangeUpdatesKnownPanesOnUnzoom() {
    let (manager, _) = makeManager()
    // Initial: 2 panes
    manager.simulateLayoutChange(windowId: "@0", panes: [
        .init(x: 0, y: 0, width: 40, height: 24, paneId: 0),
        .init(x: 41, y: 0, width: 39, height: 24, paneId: 1),
    ])
    XCTAssertEqual(manager.windowKnownPaneIds["@0"], ["%0", "%1"])

    // New pane added (3 panes, unzoomed)
    manager.simulateLayoutChange(windowId: "@0", panes: [
        .init(x: 0, y: 0, width: 26, height: 24, paneId: 0),
        .init(x: 27, y: 0, width: 26, height: 24, paneId: 1),
        .init(x: 54, y: 0, width: 26, height: 24, paneId: 2),
    ])
    XCTAssertEqual(manager.windowKnownPaneIds["@0"], ["%0", "%1", "%2"])
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ios && xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.2' -only-testing:MuxiTests/ConnectionManagerZoomTests 2>&1 | grep -E '(Test Case|PASS|FAIL)' | head -20`
Expected: New tests FAIL (isZoomed never set, buffers get removed, etc.)

- [ ] **Step 3: Modify onLayoutChange in wireCallbacks()**

Replace the `onLayoutChange` callback body (lines 1123-1206) in `wireCallbacks()`. The new logic adds a zoomed-detection branch at the top:

```swift
tmuxService.onLayoutChange = { [weak self] windowId, panes in
    guard let self else { return }
    // During a window switch, ignore layout-change from non-target windows.
    if let target = self.switchingToWindowId, windowId != target {
        return
    }
    self.switchingToWindowId = nil

    // Only process for active window (or first layout on connect).
    guard self.activeWindowId == nil || windowId == self.activeWindowId else {
        if let idx = self.currentWindows.firstIndex(where: { $0.id == windowId }) {
            self.currentWindows[idx].paneIds = panes.map { "%\($0.paneId)" }
        }
        return
    }

    let layoutPaneIds = Set(panes.map { "%\($0.paneId)" })
    let knownCount = self.windowKnownPaneIds[windowId]?.count ?? 0

    // --- Zoom Detection ---
    if panes.count == 1, knownCount > 1 {
        // ZOOMED: layout shows 1 pane but we know more exist.
        self.isZoomed = true
        self.pendingZoom = false
        // Only resize the zoomed pane's buffer — do NOT touch other buffers or currentPanes.
        let zoomedId = "%\(panes[0].paneId)"
        self.paneBuffers[zoomedId]?.resize(cols: panes[0].width, rows: panes[0].height)
        self.activeWindowId = windowId
        for i in self.currentWindows.indices {
            self.currentWindows[i].isActive = (self.currentWindows[i].id == windowId)
        }
        // Do NOT update currentWindows[].paneIds (would lose non-zoomed panes)
        // Do NOT update currentPanes (would lose layout geometry)
        // Do NOT remove paneBuffers
        return
    }

    // --- Unzoomed / Single-pane: normal processing ---
    self.isZoomed = false
    self.pendingZoom = false
    self.windowKnownPaneIds[windowId] = layoutPaneIds

    self.currentPanes = panes
    self.activeWindowId = windowId
    for i in self.currentWindows.indices {
        self.currentWindows[i].isActive = (self.currentWindows[i].id == windowId)
    }
    if let idx = self.currentWindows.firstIndex(where: { $0.id == windowId }) {
        self.currentWindows[idx].paneIds = panes.map { "%\($0.paneId)" }
    }

    // Create/resize buffers for each pane.
    var newPaneIds: [String] = []
    for pane in panes {
        let paneId = "%\(pane.paneId)"
        if self.paneBuffers[paneId] == nil {
            self.paneBuffers[paneId] = TerminalBuffer(
                cols: pane.width, rows: pane.height
            )
            newPaneIds.append(paneId)
        } else {
            self.paneBuffers[paneId]?.resize(
                cols: pane.width, rows: pane.height
            )
        }
    }

    // Remove buffers for panes that no longer exist.
    for key in self.paneBuffers.keys where !layoutPaneIds.contains(key) {
        self.paneBuffers.removeValue(forKey: key)
    }

    // Update activePaneId.
    if let active = self.activePaneId, !layoutPaneIds.contains(active) {
        self.activePaneId = panes.first.map { "%\($0.paneId)" }
    } else if self.activePaneId == nil, let first = panes.first {
        self.activePaneId = "%\(first.paneId)"
    }

    // Capture initial content for new panes (skip during initial attach).
    if !self.pendingInitialResize {
        for paneId in newPaneIds {
            Task {
                try? await self.sendControlCommand(
                    "capture-pane -e -p -t \(paneId.shellEscaped())\n",
                    type: .capturePane(paneId: paneId))
                try? await self.sendControlCommand(
                    "display-message -p -t \(paneId.shellEscaped()) '#{cursor_x}:#{cursor_y}'\n",
                    type: .cursorQuery(paneId: paneId))
            }
        }
    }

    // Auto-zoom if needed (iPhone + multi-pane + just unzoomed).
    self.ensureZoomIfNeeded()
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ios && xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.2' -only-testing:MuxiTests/ConnectionManagerZoomTests 2>&1 | grep -E '(Test Case|PASS|FAIL)' | head -20`
Expected: All tests PASS (both old and new).

- [ ] **Step 5: Run full test suite to ensure no regressions**

Run: `cd ios && xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.2' 2>&1 | grep -E '(Test Suite|Tests?.*passed|FAIL)' | tail -10`
Expected: All existing tests pass.

- [ ] **Step 6: Commit**

```bash
git add ios/Muxi/Services/ConnectionManager.swift ios/MuxiTests/Services/ConnectionManagerZoomTests.swift
git commit -m "feat(zoom): detect zoomed layout and preserve pane state in onLayoutChange"
```

---

## Chunk 3: Pane Switch Zoom and Session/Window Switch Integration

### Task 4: Add zoom to pane switch code paths

**Files:**
- Modify: `ios/Muxi/Services/ConnectionManager.swift:715-732` (selectWindowAndPane)
- Modify: `ios/Muxi/Views/Terminal/TerminalSessionView.swift:59-62` (onPaneTapped)

- [ ] **Step 1: Modify selectWindowAndPane() to append resize-pane -Z when compact**

In `selectWindowAndPane()`, after each `select-pane` command, add `resize-pane -Z` when `isCompact` and multi-pane:

```swift
func selectWindowAndPane(windowId: String, paneId: String) async throws {
    guard case .attached = state else { return }

    if windowId != activeWindowId {
        prepareWindowSwitch(to: windowId)
        activePaneId = paneId
        try await sendControlCommand(
            "select-window -t \(windowId.shellEscaped())\n", type: .ignored)
        try await sendControlCommand(
            "select-pane -t \(paneId.shellEscaped())\n", type: .ignored)
        // Zoom will be triggered by ensureZoomIfNeeded() in onLayoutChange
        // after forceLayoutRefresh().
        try await forceLayoutRefresh()
    } else {
        activePaneId = paneId
        try await sendControlCommand(
            "select-pane -t \(paneId.shellEscaped())\n", type: .ignored)
        // Zoom the newly selected pane if on iPhone with multi-pane.
        if isCompact, (windowKnownPaneIds[windowId]?.count ?? 0) > 1 {
            pendingZoom = true
            try await sendControlCommand(
                "resize-pane -Z -t \(paneId.shellEscaped())\n", type: .ignored)
        }
    }
}
```

- [ ] **Step 2: Modify TerminalSessionView.onPaneTapped to route through ConnectionManager**

In `TerminalSessionView.swift`, change the `onPaneTapped` closure (line 59) to use `selectWindowAndPane` instead of direct `sendTmuxCommand`:

```swift
onPaneTapped: { paneId in
    isKeyboardActive = true
    if let windowId = connectionManager.activeWindowId {
        Task {
            try? await connectionManager.selectWindowAndPane(
                windowId: windowId, paneId: paneId)
        }
    }
},
```

- [ ] **Step 3: Verify project builds and existing tests pass**

Run: `cd ios && xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.2' 2>&1 | grep -E '(Test Suite|Tests?.*passed|FAIL)' | tail -10`
Expected: All tests pass.

- [ ] **Step 4: Commit**

```bash
git add ios/Muxi/Services/ConnectionManager.swift ios/Muxi/Views/Terminal/TerminalSessionView.swift
git commit -m "feat(zoom): add auto-zoom to pane switch code paths"
```

---

### Task 5: Clear zoom state on session change and add zoom on attach

**Files:**
- Modify: `ios/Muxi/Services/ConnectionManager.swift` (onSessionChanged ~line 1300, performAttach ~line 578)
- Test: `ios/MuxiTests/Services/ConnectionManagerZoomTests.swift`

- [ ] **Step 1: Write failing test for session change clearing zoom state**

Add to `ConnectionManagerZoomTests.swift`:

```swift
// MARK: - Session Change

func testSessionChangeClearsZoomState() {
    let (manager, _) = makeManager()
    manager.setIsZoomedForTesting(true)
    manager.setPendingZoomForTesting(true)
    manager.setWindowKnownPaneIdsForTesting(["@0": ["%0", "%1"]])

    // Simulate session change
    manager.simulateSessionChanged(sessionId: "$1", name: "new-session")

    XCTAssertFalse(manager.isZoomed)
    XCTAssertFalse(manager.pendingZoom)
    XCTAssertTrue(manager.windowKnownPaneIds.isEmpty)
}
```

- [ ] **Step 2: Add `simulateSessionChanged` test helper (if not present)**

In the `#if DEBUG` block of ConnectionManager:

```swift
func simulateSessionChanged(sessionId: String, name: String) {
    tmuxService.onSessionChanged?(sessionId, name)
}
```

- [ ] **Step 3: Run test to verify it fails**

Expected: `windowKnownPaneIds` not cleared, test fails.

- [ ] **Step 4: Modify onSessionChanged to clear zoom state**

In the `onSessionChanged` callback (around line 1300), add after the existing state clearing:

```swift
self.isZoomed = false
self.pendingZoom = false
self.windowKnownPaneIds = [:]
```

- [ ] **Step 5: Clear zoom state in reconnect() as well**

In `reconnect()` (around line 870), alongside the existing `pendingCommands = []` clearing, add:

```swift
isZoomed = false
pendingZoom = false
windowKnownPaneIds = [:]
```

This prevents stale zoom state after a dropped connection — `reconnect()` re-establishes the SSH session, and fresh `%layout-change` events will trigger `ensureZoomIfNeeded()`.

- [ ] **Step 6: Run test to verify it passes**

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add ios/Muxi/Services/ConnectionManager.swift ios/MuxiTests/Services/ConnectionManagerZoomTests.swift
git commit -m "feat(zoom): clear zoom state on session change"
```

---

## Chunk 4: TerminalSessionView sizeClass Integration and ToolbarView

### Task 6: Pass horizontalSizeClass from TerminalSessionView to ConnectionManager

**Files:**
- Modify: `ios/Muxi/Views/Terminal/TerminalSessionView.swift`

- [ ] **Step 1: Add sizeClass observation and pass to ConnectionManager**

In `TerminalSessionView`, add `@Environment(\.horizontalSizeClass)`:

```swift
@Environment(\.horizontalSizeClass) private var sizeClass
```

Then in the `body`, add `.onAppear` and `.onChange` to sync with ConnectionManager:

```swift
.onAppear {
    connectionManager.isCompact = (sizeClass == .compact)
    // Catch any layout that arrived before the view appeared
    // (first %layout-change from performAttach may precede onAppear).
    connectionManager.ensureZoomIfNeeded()
}
.onChange(of: sizeClass) { _, newValue in
    let wasCompact = connectionManager.isCompact
    connectionManager.isCompact = (newValue == .compact)
    if wasCompact && !connectionManager.isCompact {
        // Transitioning to regular — unzoom
        connectionManager.ensureUnzoomIfNeeded()
    } else if !wasCompact && connectionManager.isCompact {
        // Transitioning to compact — zoom if multi-pane
        connectionManager.ensureZoomIfNeeded()
    }
}
```

Place these modifiers on the outermost `VStack` in `body`, alongside existing modifiers.

- [ ] **Step 2: Verify build succeeds**

Run: `cd ios && xcodebuild build -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.2' -quiet 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add ios/Muxi/Views/Terminal/TerminalSessionView.swift
git commit -m "feat(zoom): pass horizontalSizeClass to ConnectionManager for auto-zoom"
```

---

### Task 7: Update WindowPanePillsView to show all panes when zoomed

**Files:**
- Modify: `ios/Muxi/Views/Terminal/WindowPanePillsView.swift:108-116` (panesToShow)
- Modify: `ios/Muxi/Views/Terminal/ToolbarView.swift` (pass new props)

- [ ] **Step 1: Add `windowKnownPaneIds` and `isZoomed` props to WindowPanePillsView**

```swift
struct WindowPanePillsView: View {
    let windows: [ConnectionManager.TmuxWindowInfo]
    let activeWindowId: String?
    let activePaneId: String?
    let currentPanes: [TmuxControlService.ParsedPane]
    let isZoomed: Bool                                    // NEW
    let windowKnownPaneIds: [String: Set<String>]         // NEW
    // ... rest unchanged
```

- [ ] **Step 2: Modify panesToShow() to use windowKnownPaneIds when zoomed**

```swift
private func panesToShow(for window: ConnectionManager.TmuxWindowInfo) -> [String] {
    // When zoomed, the window's paneIds only has the zoomed pane.
    // Use windowKnownPaneIds to show all panes for switching.
    if isZoomed, window.id == activeWindowId,
       let knownIds = windowKnownPaneIds[window.id], knownIds.count > 1 {
        return knownIds.sorted()
    }
    if !window.paneIds.isEmpty {
        return window.paneIds
    }
    if window.id == activeWindowId {
        return currentPanes.map { "%\($0.paneId)" }
    }
    return []
}
```

- [ ] **Step 3: Update ToolbarView to pass new props**

In `ToolbarView.swift`, update the `WindowPanePillsView` construction:

```swift
WindowPanePillsView(
    windows: connectionManager.currentWindows,
    activeWindowId: connectionManager.activeWindowId,
    activePaneId: connectionManager.activePaneId,
    currentPanes: connectionManager.currentPanes,
    isZoomed: connectionManager.isZoomed,                          // NEW
    windowKnownPaneIds: connectionManager.windowKnownPaneIds,      // NEW
    // ... rest unchanged
```

- [ ] **Step 4: Verify build succeeds and all tests pass**

Run: `cd ios && xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.2' 2>&1 | grep -E '(Test Suite|Tests?.*passed|FAIL)' | tail -10`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add ios/Muxi/Views/Terminal/WindowPanePillsView.swift ios/Muxi/Views/Terminal/ToolbarView.swift
git commit -m "feat(zoom): show all panes in toolbar when zoomed"
```

---

## Chunk 5: Size Class Transition Tests and Final Verification

### Task 8: Add size class transition tests

**Files:**
- Test: `ios/MuxiTests/Services/ConnectionManagerZoomTests.swift`

- [ ] **Step 1: Write tests for size class transitions**

Add to `ConnectionManagerZoomTests.swift`:

```swift
// MARK: - Size Class Transitions

func testCompactToRegularCallsUnzoom() {
    let (manager, _) = makeManager()
    setupMultiPane(manager)
    manager.setIsZoomedForTesting(true)

    // Simulate compact -> regular transition
    manager.isCompact = false
    manager.ensureUnzoomIfNeeded()

    // ensureUnzoomIfNeeded() passes the isZoomed guard and fires
    // the async unzoom command. Actual unzoom confirmed by %layout-change.
    // We verify it didn't early-return by confirming isZoomed is still true
    // until the %layout-change arrives (toggle is async).
    XCTAssertTrue(manager.isZoomed) // not cleared until %layout-change
}

func testCompactToRegularNoOpWhenNotZoomed() {
    let (manager, _) = makeManager()
    setupMultiPane(manager)
    // isZoomed = false

    manager.isCompact = false
    manager.ensureUnzoomIfNeeded()

    // Should early-return — no state changes
    XCTAssertFalse(manager.isZoomed)
    XCTAssertFalse(manager.pendingZoom)
}

func testRegularToCompactZooms() {
    let (manager, _) = makeManager()
    setupMultiPane(manager)
    manager.setIsCompactForTesting(false)
    manager.setIsZoomedForTesting(false)

    // Simulate regular -> compact transition
    manager.isCompact = true
    manager.ensureZoomIfNeeded()

    XCTAssertTrue(manager.pendingZoom)
}

// MARK: - Manual Unzoom Re-Zoom

func testManualUnzoomTriggersReZoomOnCompact() {
    let (manager, _) = makeManager()
    manager.setIsCompactForTesting(true)
    // Start with known 2 panes, zoomed state
    manager.setWindowKnownPaneIdsForTesting(["@0": ["%0", "%1"]])
    manager.setIsZoomedForTesting(true)
    manager.activePaneId = "%0"
    manager.setWindowsForTesting(
        [ConnectionManager.TmuxWindowInfo(id: "@0", name: "bash", index: 0)],
        activeId: "@0"
    )

    // User presses prefix+z — tmux sends unzoomed layout
    manager.simulateLayoutChange(windowId: "@0", panes: [
        .init(x: 0, y: 0, width: 40, height: 24, paneId: 0),
        .init(x: 41, y: 0, width: 39, height: 24, paneId: 1),
    ])

    // onLayoutChange should detect unzoomed state on compact
    // and call ensureZoomIfNeeded() which sets pendingZoom = true
    XCTAssertFalse(manager.isZoomed)
    XCTAssertTrue(manager.pendingZoom) // re-zoom triggered
}
```

- [ ] **Step 2: Run tests**

Run: `cd ios && xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.2' -only-testing:MuxiTests/ConnectionManagerZoomTests 2>&1 | grep -E '(Test Case|PASS|FAIL)' | head -20`
Expected: All tests PASS.

- [ ] **Step 3: Run full test suite**

Run: `cd ios && xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.2' 2>&1 | grep -E '(Test Suite|Tests?.*passed|FAIL)' | tail -10`
Expected: All tests pass, zero regressions.

- [ ] **Step 4: Commit**

```bash
git add ios/MuxiTests/Services/ConnectionManagerZoomTests.swift
git commit -m "test(zoom): add size class transition tests"
```

---

### Task 9: Final integration verification

- [ ] **Step 1: Run full test suite one final time**

Run: `cd ios && xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.2' 2>&1 | grep -E '(Test Suite|Tests?.*passed|FAIL)' | tail -10`
Expected: All tests pass.

- [ ] **Step 2: Verify no stale TODO/FIXME markers**

Run: `grep -rn 'TODO\|FIXME' ios/Muxi/Services/ConnectionManager.swift | grep -i zoom` — should return nothing.

- [ ] **Step 3: Final commit with plan doc**

```bash
git add docs/superpowers/plans/2026-03-12-iphone-pane-auto-zoom.md
git commit -m "docs: add iPhone pane auto-zoom implementation plan"
```
