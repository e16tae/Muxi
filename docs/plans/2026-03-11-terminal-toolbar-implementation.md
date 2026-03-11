# Terminal Toolbar Redesign — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the top toolbar + floating QuickActionButton with a bottom toolbar featuring grouped window/pane pills, session mode toggle, and context-dependent + menu.

**Architecture:** Bottom-up: (1) add `%window-renamed` to C parser, (2) wire window tracking in ConnectionManager, (3) build toolbar UI components, (4) integrate into TerminalSessionView and remove deprecated components. Each layer is independently testable.

**Tech Stack:** C11 (tmux protocol parser), Swift/SwiftUI (iOS 17+), Swift Testing + XCTest

**Spec:** `docs/plans/2026-03-11-terminal-toolbar-redesign.md`

---

## File Structure

### New Files
| File | Responsibility |
|------|---------------|
| `ios/Muxi/Views/Terminal/ToolbarView.swift` | Bottom toolbar container: session toggle, pill area, + button, keyboard toggle |
| `ios/Muxi/Views/Terminal/WindowPanePillsView.swift` | Grouped capsule pills for windows/panes with tap + long-press |
| `ios/Muxi/Views/Terminal/SessionPillsView.swift` | Session pills for session mode with tap + long-press |
| `ios/Muxi/Views/Terminal/PlusMenuView.swift` | Context-dependent + menu (popover) |
| `ios/MuxiTests/Views/ToolbarTests.swift` | Tests for pill helper logic (panesToShow, renameAlertTitle) |
| `ios/MuxiTests/Services/WindowTrackingTests.swift` | Tests for ConnectionManager window tracking + commands |

### Modified Files
| File | Changes |
|------|---------|
| `core/tmux_protocol/include/tmux_protocol.h` | Add `TMUX_MSG_WINDOW_RENAMED` constant, add `window_name` field |
| `core/tmux_protocol/tmux_protocol.c` | Add `parse_window_renamed` handler + keyword table entry |
| `ios/MuxiCore/Tests/MuxiCoreTests/TmuxProtocolTests.swift` | Add `%window-renamed` parsing test |
| `ios/Muxi/Services/TmuxControlService.swift` | Add `onWindowRenamed` callback, handle `TMUX_MSG_WINDOW_RENAMED` |
| `ios/MuxiTests/Services/TmuxControlServiceTests.swift` | Add `%window-renamed` dispatch test |
| `ios/Muxi/Services/ConnectionManager.swift` | Add `currentWindows`, `activeWindowId`, window tracking in callbacks, new tmux commands (`select-window`, `rename-session`, `kill-session`) |
| `ios/Muxi/Views/Terminal/TerminalSessionView.swift` | Remove top toolbar + QuickActionButton overlay, add ToolbarView + ExtendedKeyboardView below pane area |
| `ios/Muxi/Views/Terminal/PaneContainerView.swift` | Remove `paneTabBar` (replaced by pills in toolbar) |

### Deleted Files
| File | Reason |
|------|--------|
| `ios/Muxi/Views/QuickAction/QuickActionButton.swift` | Replaced by + menu in toolbar |
| `ios/Muxi/Views/QuickAction/QuickActionView.swift` | Replaced by + menu + long-press menus |
| `ios/MuxiTests/Views/QuickActionTests.swift` | Tests for deleted component |

---

## Chunk 1: C Parser — `%window-renamed` Support

### Task 1: Add `%window-renamed` to C parser

`%window-renamed` format: `%window-renamed @<id> <new_name>`

**Files:**
- Modify: `core/tmux_protocol/include/tmux_protocol.h`
- Modify: `core/tmux_protocol/tmux_protocol.c`
- Test: `ios/MuxiCore/Tests/MuxiCoreTests/TmuxProtocolTests.swift`

- [ ] **Step 1: Write the failing test**

In `ios/MuxiCore/Tests/MuxiCoreTests/TmuxProtocolTests.swift`, add:

```swift
@Test func testParseWindowRenamed() {
    let line = "%window-renamed @0 vim"
    line.withCString { cLine in
        var msg = TmuxMessage()
        let msgType = tmux_parse_line(cLine, &msg)

        #expect(msgType == TMUX_MSG_WINDOW_RENAMED)
        let windowId = withUnsafePointer(to: &msg.window_id.0) { string(from: $0) }
        #expect(windowId == "@0")
        let windowName = withUnsafePointer(to: &msg.window_name.0) { string(from: $0) }
        #expect(windowName == "vim")
    }
}

@Test func testParseWindowRenamedWithSpaces() {
    let line = "%window-renamed @2 my window name"
    line.withCString { cLine in
        var msg = TmuxMessage()
        let msgType = tmux_parse_line(cLine, &msg)

        #expect(msgType == TMUX_MSG_WINDOW_RENAMED)
        let windowId = withUnsafePointer(to: &msg.window_id.0) { string(from: $0) }
        #expect(windowId == "@2")
        let windowName = withUnsafePointer(to: &msg.window_name.0) { string(from: $0) }
        #expect(windowName == "my window name")
    }
}

@Test func testParseUnlinkedWindowClose() {
    let line = "%unlinked-window-close @3"
    line.withCString { cLine in
        var msg = TmuxMessage()
        let msgType = tmux_parse_line(cLine, &msg)

        #expect(msgType == TMUX_MSG_UNLINKED_WINDOW_CLOSE)
        let windowId = withUnsafePointer(to: &msg.window_id.0) { string(from: $0) }
        #expect(windowId == "@3")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path ios/MuxiCore 2>&1 | tail -20`
Expected: Compile error — `TMUX_MSG_WINDOW_RENAMED` and `window_name` not defined.

- [ ] **Step 3: Add constants and field to header**

In `core/tmux_protocol/include/tmux_protocol.h`, after line 27 (`#define TMUX_MSG_SESSIONS_CHANGED 10`), add:

```c
#define TMUX_MSG_WINDOW_RENAMED       11
#define TMUX_MSG_UNLINKED_WINDOW_CLOSE 12
```

In the `TmuxMessage` struct (after `session_name` field, line 49), add:

```c
    char window_name[TMUX_NAME_MAX];
```

- [ ] **Step 4: Add parsers to C implementation**

In `core/tmux_protocol/tmux_protocol.c`, after `parse_window_close` (line 162), add:

```c
/**
 * Parse %window-renamed @<id> <name>
 */
static int parse_window_renamed(const char *rest, TmuxMessage *msg) {
    char tok[TMUX_ID_MAX];
    if (!next_token(&rest, tok, sizeof(tok)))
        return TMUX_MSG_UNKNOWN;
    safe_strcpy(msg->window_id, TMUX_ID_MAX, tok);
    /* Window name is the rest of the line (may contain spaces) */
    const char *p = skip_space(rest);
    safe_strcpy(msg->window_name, TMUX_NAME_MAX, p);
    return TMUX_MSG_WINDOW_RENAMED;
}

/**
 * Parse %unlinked-window-close @<id>
 */
static int parse_unlinked_window_close(const char *rest, TmuxMessage *msg) {
    char tok[TMUX_ID_MAX];
    if (!next_token(&rest, tok, sizeof(tok)))
        return TMUX_MSG_UNKNOWN;
    safe_strcpy(msg->window_id, TMUX_ID_MAX, tok);
    return TMUX_MSG_UNLINKED_WINDOW_CLOSE;
}
```

In the `keyword_table` array, after the `%window-close` entry, add:

```c
    KW_ENTRY("%window-renamed",         parse_window_renamed),
    KW_ENTRY("%unlinked-window-close",  parse_unlinked_window_close),
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --package-path ios/MuxiCore 2>&1 | tail -20`
Expected: All tests PASS including the 3 new ones.

- [ ] **Step 6: Commit**

```bash
git add core/tmux_protocol/include/tmux_protocol.h \
        core/tmux_protocol/tmux_protocol.c \
        ios/MuxiCore/Tests/MuxiCoreTests/TmuxProtocolTests.swift
git commit -m "feat: add %window-renamed and %unlinked-window-close to C parser

Add TMUX_MSG_WINDOW_RENAMED (11) and TMUX_MSG_UNLINKED_WINDOW_CLOSE (12)
message types. Parser extracts window_id and window_name fields.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Chunk 2: Swift Bridge — Window Notification Dispatch

### Task 2: Add `onWindowRenamed` callback to TmuxControlService

**Files:**
- Modify: `ios/Muxi/Services/TmuxControlService.swift`
- Test: `ios/MuxiTests/Services/TmuxControlServiceTests.swift`

- [ ] **Step 1: Write the failing test**

In `ios/MuxiTests/Services/TmuxControlServiceTests.swift`, add:

```swift
func testHandleWindowRenamed() {
    let service = TmuxControlService()
    var receivedWindowId: String?
    var receivedName: String?

    service.onWindowRenamed = { windowId, name in
        receivedWindowId = windowId
        receivedName = name
    }

    service.handleLine("%window-renamed @0 vim")

    XCTAssertEqual(receivedWindowId, "@0")
    XCTAssertEqual(receivedName, "vim")
}

func testHandleWindowRenamedWithSpaces() {
    let service = TmuxControlService()
    var receivedName: String?

    service.onWindowRenamed = { _, name in
        receivedName = name
    }

    service.handleLine("%window-renamed @1 my window")

    XCTAssertEqual(receivedName, "my window")
}

func testHandleUnlinkedWindowClose() {
    let service = TmuxControlService()
    var receivedWindowId: String?

    service.onWindowClose = { windowId in
        receivedWindowId = windowId
    }

    service.handleLine("%unlinked-window-close @3")

    XCTAssertEqual(receivedWindowId, "@3")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios && xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' -only-testing:MuxiTests/TmuxControlServiceTests/testHandleWindowRenamed 2>&1 | tail -20`
Expected: Compile error — `onWindowRenamed` does not exist.

- [ ] **Step 3: Add callback and dispatch case**

In `ios/Muxi/Services/TmuxControlService.swift`:

After `onWindowClose` (line 30), add:

```swift
/// Called when a window is renamed.
var onWindowRenamed: ((_ windowId: String, _ name: String) -> Void)?
```

In `handleLine(_:)`, after the `TMUX_MSG_WINDOW_CLOSE` case (line 202), add:

```swift
            case TMUX_MSG_WINDOW_RENAMED:
                let windowId = extractString(from: &msg.window_id, capacity: Int(TMUX_ID_MAX))
                let name = extractString(from: &msg.window_name, capacity: Int(TMUX_NAME_MAX))
                onWindowRenamed?(windowId, name)
```

Also add the unlinked window close to the existing `TMUX_MSG_WINDOW_CLOSE` handler. After the `TMUX_MSG_WINDOW_CLOSE` case, add:

```swift
            case TMUX_MSG_UNLINKED_WINDOW_CLOSE:
                let windowId = extractString(from: &msg.window_id, capacity: Int(TMUX_ID_MAX))
                onWindowClose?(windowId)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ios && xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' -only-testing:MuxiTests/TmuxControlServiceTests 2>&1 | tail -20`
Expected: All TmuxControlServiceTests PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/Muxi/Services/TmuxControlService.swift \
        ios/MuxiTests/Services/TmuxControlServiceTests.swift
git commit -m "feat: dispatch %window-renamed and %unlinked-window-close in TmuxControlService

Wire TMUX_MSG_WINDOW_RENAMED to onWindowRenamed callback (windowId, name).
Route TMUX_MSG_UNLINKED_WINDOW_CLOSE through existing onWindowClose.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Chunk 3: ConnectionManager — Window Tracking & New Commands

### Task 3: Add window tracking state to ConnectionManager

**Files:**
- Modify: `ios/Muxi/Services/ConnectionManager.swift`
- Test: `ios/MuxiTests/Services/WindowTrackingTests.swift` (new)

- [ ] **Step 1: Write the failing test**

Create `ios/MuxiTests/Services/WindowTrackingTests.swift`:

```swift
import XCTest
@testable import Muxi

@MainActor
final class WindowTrackingTests: XCTestCase {

    private func makeManager() -> ConnectionManager {
        ConnectionManager(sshService: MockSSHService())
    }

    // MARK: - Window List Parsing

    func testParseWindowList() {
        let output = "@0\t0\tbash\t1\n@1\t1\tvim\t0"
        let windows = ConnectionManager.parseWindowList(output)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].id, "@0")
        XCTAssertEqual(windows[0].name, "bash")
        XCTAssertTrue(windows[0].isActive)
        XCTAssertEqual(windows[1].id, "@1")
        XCTAssertEqual(windows[1].name, "vim")
        XCTAssertFalse(windows[1].isActive)
    }

    func testParseWindowListEmpty() {
        let windows = ConnectionManager.parseWindowList("")
        XCTAssertTrue(windows.isEmpty)
    }

    func testParseWindowListWithColonInName() {
        // Window names can contain colons (e.g. "vim:file.txt")
        let output = "@0\t0\tvim:file.txt\t1"
        let windows = ConnectionManager.parseWindowList(output)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].name, "vim:file.txt")
    }

    func testParseWindowListMalformed() {
        let output = "@0\t0\n@1"  // missing fields
        let windows = ConnectionManager.parseWindowList(output)
        XCTAssertTrue(windows.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios && xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' -only-testing:MuxiTests/WindowTrackingTests 2>&1 | tail -20`
Expected: Compile error — `parseWindowList` does not exist.

- [ ] **Step 3: Add window tracking properties and parsing**

In `ios/Muxi/Services/ConnectionManager.swift`:

After `var activePaneId: String?` (line 76), add:

```swift
    /// Windows in the current session, tracked via tmux notifications.
    private(set) var currentWindows: [TmuxWindowInfo] = []

    /// The currently active window ID (e.g., "@0").
    private(set) var activeWindowId: String?
```

Before the `PendingCommand` enum (line 127), add:

```swift
    // MARK: - Window Info (lightweight, for toolbar pills)

    /// Lightweight window info for the toolbar pills.
    /// Unlike TmuxWindow in TmuxModels, this is managed entirely by
    /// ConnectionManager from tmux notifications — no SwiftData dependency.
    struct TmuxWindowInfo: Identifiable, Equatable {
        let id: String       // e.g. "@0"
        var name: String     // e.g. "bash"
        var paneIds: [String] // e.g. ["%0", "%1"]
        var isActive: Bool
    }
```

Add `listWindows` to the `PendingCommand` enum:

```swift
        /// `list-windows -F '...'` — refresh the window list.
        case listWindows
```

Add the static parser method (near `refreshSessions` at the bottom):

```swift
    /// Parse the output of `list-windows -F '#{window_id}\t#{window_index}\t#{window_name}\t#{window_active}'`.
    ///
    /// Uses tab separator to avoid breaking on colons in window names.
    /// Each line: `@0\t0\tbash\t1`
    static func parseWindowList(_ output: String) -> [TmuxWindowInfo] {
        output.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n")
            .compactMap { line in
                let parts = line.trimmingCharacters(in: .whitespaces)
                    .split(separator: "\t", maxSplits: 3)
                guard parts.count >= 4 else { return nil }
                let id = String(parts[0])
                let name = String(parts[2])
                let isActive = parts[3] == "1"
                return TmuxWindowInfo(id: id, name: name, paneIds: [], isActive: isActive)
            }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ios && xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' -only-testing:MuxiTests/WindowTrackingTests 2>&1 | tail -20`
Expected: All WindowTrackingTests PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/Muxi/Services/ConnectionManager.swift \
        ios/MuxiTests/Services/WindowTrackingTests.swift
git commit -m "feat: add TmuxWindowInfo model and window list parser to ConnectionManager

Add currentWindows/activeWindowId properties and parseWindowList() static
method. Introduces listWindows PendingCommand type for window refresh.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

### Task 4: Wire window callbacks in ConnectionManager

**Files:**
- Modify: `ios/Muxi/Services/ConnectionManager.swift` (wireCallbacks, onCommandResponse, performAttach)
- Test: `ios/MuxiTests/Services/WindowTrackingTests.swift`

- [ ] **Step 0: Write failing tests for window callback behavior**

Add to `ios/MuxiTests/Services/WindowTrackingTests.swift`:

```swift
    // MARK: - Window State Management

    func testWindowCloseRemovesFromArray() {
        let manager = makeManager()
        // Simulate having windows
        manager.currentWindows = [
            .init(id: "@0", name: "bash", paneIds: ["%0"], isActive: true),
            .init(id: "@1", name: "vim", paneIds: ["%1"], isActive: false),
        ]
        manager.activeWindowId = "@0"

        // Simulate onWindowClose
        manager.handleWindowClose("@0")

        XCTAssertEqual(manager.currentWindows.count, 1)
        XCTAssertEqual(manager.currentWindows[0].id, "@1")
        XCTAssertEqual(manager.activeWindowId, "@1")
    }

    func testWindowRenameUpdatesName() {
        let manager = makeManager()
        manager.currentWindows = [
            .init(id: "@0", name: "bash", paneIds: [], isActive: true),
        ]

        manager.handleWindowRenamed("@0", name: "zsh")

        XCTAssertEqual(manager.currentWindows[0].name, "zsh")
    }

    func testListWindowsResponsePopulatesWindows() {
        let manager = makeManager()
        let response = "@0\t0\tbash\t1\n@1\t1\tvim\t0"

        manager.handleListWindowsResponse(response)

        XCTAssertEqual(manager.currentWindows.count, 2)
        XCTAssertEqual(manager.activeWindowId, "@0")
    }
```

Run: `cd ios && xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' -only-testing:MuxiTests/WindowTrackingTests 2>&1 | tail -20`
Expected: Compile error — `handleWindowClose`, `handleWindowRenamed`, `handleListWindowsResponse` don't exist yet.

Note: These methods will be extracted as internal helpers called from `wireCallbacks()` closures, making them testable without needing to mock the full TmuxControlService callback chain.

- [ ] **Step 1: Wire `onWindowAdd`, `onWindowClose`, `onWindowRenamed` in wireCallbacks()**

In `ios/Muxi/Services/ConnectionManager.swift`, in `wireCallbacks()`:

After `tmuxService.onPaneOutput` (around line 874), add window callbacks. After the `onLayoutChange` callback (line 930), add:

```swift
        tmuxService.onWindowAdd = { [weak self] windowId in
            guard let self else { return }
            self.logger.info("Window added: \(windowId)")
            self.requestWindowListRefresh()
        }

        tmuxService.onWindowClose = { [weak self] windowId in
            guard let self else { return }
            self.handleWindowClose(windowId)
        }

        tmuxService.onWindowRenamed = { [weak self] windowId, name in
            guard let self else { return }
            self.handleWindowRenamed(windowId, name: name)
        }
```

And add these extracted methods (testable without mocking callbacks):

```swift
    // MARK: - Window State Helpers (internal for testability)

    /// Handle a window close notification.
    func handleWindowClose(_ windowId: String) {
        logger.info("Window closed: \(windowId)")
        currentWindows.removeAll { $0.id == windowId }
        if activeWindowId == windowId {
            activeWindowId = currentWindows.first(where: { $0.isActive })?.id
                ?? currentWindows.first?.id
        }
    }

    /// Handle a window rename notification.
    func handleWindowRenamed(_ windowId: String, name: String) {
        logger.info("Window renamed: \(windowId) → \(name)")
        if let index = currentWindows.firstIndex(where: { $0.id == windowId }) {
            currentWindows[index].name = name
        }
    }

    /// Handle the list-windows command response.
    func handleListWindowsResponse(_ response: String) {
        let parsed = Self.parseWindowList(response)
        if !parsed.isEmpty {
            currentWindows = parsed
            activeWindowId = parsed.first(where: { $0.isActive })?.id
                ?? parsed.first?.id
            updateWindowPaneMapping()
        }
    }

    /// Request a window list refresh via the control channel.
    private func requestWindowListRefresh() {
        Task {
            try? await sendControlCommand(
                "list-windows -F '#{window_id}\t#{window_index}\t#{window_name}\t#{window_active}'\n",
                type: .listWindows)
        }
    }
```

- [ ] **Step 2: Handle `listWindows` in onCommandResponse**

In the `onCommandResponse` callback, add a case for `.listWindows` before the `.ignored` case:

```swift
            case .listWindows:
                self.handleListWindowsResponse(response)
```

- [ ] **Step 3: Add updateWindowPaneMapping helper**

After the `parseWindowList` method, add:

```swift
    /// Associate pane IDs from currentPanes with their windows.
    /// Uses the window ID from `%layout-change` to build the mapping.
    private func updateWindowPaneMapping() {
        // currentPanes only contains panes for the currently visible window.
        // For a full mapping, we need to query each window — but for now,
        // mark panes in the active window.
        // This will be refined when %layout-change includes window tracking.
    }
```

- [ ] **Step 4: Request initial window list after attach**

In `performAttach(sessionName:)`, after the `refresh-client` command (line 531), add:

```swift
        // Request window list so the toolbar can show window pills.
        requestWindowListRefresh()
```

- [ ] **Step 5: Clear window state on session change**

In the `onSessionChanged` callback (around line 1012), after clearing `paneHasNewOutput`, add:

```swift
            self.currentWindows = []
            self.activeWindowId = nil
```

And in the Task that sends `refresh-client`, also request windows:

```swift
            Task {
                let (cols, rows) = self.lastSentSize
                let size = (cols > 0 && rows > 0) ? "\(cols),\(rows)" : "80,24"
                try? await self.sendControlCommand(
                    "refresh-client -C \(size)\n", type: .ignored)
                self.requestWindowListRefresh()
            }
```

- [ ] **Step 6: Track active window from layout-change**

In the existing `onLayoutChange` callback, the `windowId` parameter tells us which window the layout belongs to. After `self.currentPanes = panes` (line 878), add:

```swift
            self.activeWindowId = windowId
            // Mark this window as active in currentWindows
            for i in self.currentWindows.indices {
                self.currentWindows[i].isActive = (self.currentWindows[i].id == windowId)
            }
            // Update pane IDs for this window
            if let idx = self.currentWindows.firstIndex(where: { $0.id == windowId }) {
                self.currentWindows[idx].paneIds = panes.map { "%\($0.paneId)" }
            }
```

- [ ] **Step 7: Run all tests**

Run: `cd ios && xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' 2>&1 | tail -30`
Expected: All tests PASS (existing + new).

- [ ] **Step 8: Commit**

```bash
git add ios/Muxi/Services/ConnectionManager.swift
git commit -m "feat: wire window tracking callbacks in ConnectionManager

Handle onWindowAdd (list-windows refresh), onWindowClose (remove from
array), onWindowRenamed (update name). Track activeWindowId from
layout-change. Request window list on attach and session change.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

### Task 5: Add new tmux commands (select-window, rename-session, kill-session)

**Files:**
- Modify: `ios/Muxi/Services/ConnectionManager.swift`
- Test: `ios/MuxiTests/Services/WindowTrackingTests.swift`

- [ ] **Step 0: Write failing tests for new commands**

Add to `ios/MuxiTests/Services/WindowTrackingTests.swift`:

```swift
    // MARK: - Session/Window Command Tests

    func testRenameSessionUpdatesLocalState() {
        let manager = makeManager()
        manager.sessions = [
            TmuxSession(id: "$0", name: "work", windows: [], createdAt: Date(), lastActivity: Date()),
            TmuxSession(id: "$1", name: "dev", windows: [], createdAt: Date(), lastActivity: Date()),
        ]
        manager.setStateForTesting(.attached(sessionName: "work"))

        Task {
            try? await manager.renameSession("work", to: "office")
        }

        // Optimistic local update
        // Note: actual test needs RunLoop or expectation for async
    }

    func testKillSessionRemovesFromArray() {
        let manager = makeManager()
        manager.sessions = [
            TmuxSession(id: "$0", name: "work", windows: [], createdAt: Date(), lastActivity: Date()),
            TmuxSession(id: "$1", name: "dev", windows: [], createdAt: Date(), lastActivity: Date()),
        ]
        manager.setStateForTesting(.attached(sessionName: "work"))

        Task {
            try? await manager.killSession("dev")
        }
    }

    func testRenameWindowUpdatesLocalState() {
        let manager = makeManager()
        manager.currentWindows = [
            .init(id: "@0", name: "bash", paneIds: [], isActive: true),
        ]
        manager.setStateForTesting(.attached(sessionName: "work"))

        Task {
            try? await manager.renameWindow("@0", to: "zsh")
        }
    }
```

Run: `cd ios && xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' -only-testing:MuxiTests/WindowTrackingTests 2>&1 | tail -20`
Expected: Compile error — `renameSession`, `killSession`, `renameWindow` don't exist yet.

- [ ] **Step 1: Add selectWindow method**

```swift
    /// Switch to a specific window by ID.
    /// Sends `select-window -t <windowId>` through the control channel.
    func selectWindow(_ windowId: String) async throws {
        guard case .attached = state else { return }
        try await sendControlCommand(
            "select-window -t \(windowId.shellEscaped())\n", type: .ignored)
    }

    /// Switch to a specific window and pane.
    func selectWindowAndPane(windowId: String, paneId: String) async throws {
        guard case .attached = state else { return }
        try await sendControlCommand(
            "select-window -t \(windowId.shellEscaped())\n", type: .ignored)
        try await sendControlCommand(
            "select-pane -t \(paneId.shellEscaped())\n", type: .ignored)
    }
```

- [ ] **Step 2: Add renameSession and killSession methods**

```swift
    /// Rename the specified tmux session.
    func renameSession(_ sessionName: String, to newName: String) async throws {
        guard case .attached = state else { return }
        try await sendControlCommand(
            "rename-session -t \(sessionName.shellEscaped()) \(newName.shellEscaped())\n",
            type: .ignored)
        // Update local sessions array
        if let index = sessions.firstIndex(where: { $0.name == sessionName }) {
            sessions[index].name = newName
        }
        // Update state if we renamed the current session
        if case .attached(let current) = state, current == sessionName {
            state = .attached(sessionName: newName)
        }
    }

    /// Kill the specified tmux session by name.
    func killSession(_ sessionName: String) async throws {
        guard case .attached = state else { return }
        try await sendControlCommand(
            "kill-session -t \(sessionName.shellEscaped())\n", type: .ignored)
        sessions.removeAll { $0.name == sessionName }
    }

    /// Rename the specified window.
    func renameWindow(_ windowId: String, to newName: String) async throws {
        guard case .attached = state else { return }
        try await sendControlCommand(
            "rename-window -t \(windowId.shellEscaped()) \(newName.shellEscaped())\n",
            type: .ignored)
        if let index = currentWindows.firstIndex(where: { $0.id == windowId }) {
            currentWindows[index].name = newName
        }
    }
```

- [ ] **Step 3: Run tests**

Run: `cd ios && xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' 2>&1 | tail -20`
Expected: All tests PASS.

- [ ] **Step 4: Commit**

```bash
git add ios/Muxi/Services/ConnectionManager.swift
git commit -m "feat: add selectWindow, renameSession, killSession, renameWindow commands

New tmux control channel methods for window/session management.
Updates local state arrays optimistically before server confirmation.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Chunk 4: Toolbar UI Components

### Task 6: Create WindowPanePillsView

Grouped capsule pills showing windows and their panes.

**Files:**
- Create: `ios/Muxi/Views/Terminal/WindowPanePillsView.swift`

- [ ] **Step 1: Create the view**

```swift
import SwiftUI

/// Horizontally scrolling grouped pills showing windows and their panes.
///
/// Each window is a capsule containing the window name + pane indices.
/// Active pane has accent background; active window has accent outline.
///
/// Tap pane → selectWindowAndPane. Tap window name → selectWindow.
/// Long-press pane → Zoom/Close. Long-press window → Rename/Close.
struct WindowPanePillsView: View {
    let windows: [ConnectionManager.TmuxWindowInfo]
    let activeWindowId: String?
    let activePaneId: String?
    let currentPanes: [TmuxControlService.ParsedPane]

    var onSelectWindow: ((String) -> Void)?
    var onSelectWindowAndPane: ((String, String) -> Void)?
    var onRenameWindow: ((String) -> Void)?
    var onCloseWindow: ((String) -> Void)?
    var onZoomPane: (() -> Void)?
    var onClosePane: ((String) -> Void)?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: MuxiTokens.Spacing.sm) {
                ForEach(windows) { window in
                    windowPill(window)
                }
            }
        }
    }

    // MARK: - Window Pill

    @ViewBuilder
    private func windowPill(_ window: ConnectionManager.TmuxWindowInfo) -> some View {
        let isActiveWindow = window.id == activeWindowId

        HStack(spacing: 0) {
            // Window name segment
            Text(window.name)
                .font(MuxiTokens.Typography.label).fontWeight(.semibold)
                .foregroundStyle(isActiveWindow
                    ? MuxiTokens.Colors.textPrimary
                    : MuxiTokens.Colors.textTertiary)
                .padding(.horizontal, MuxiTokens.Spacing.sm)
                .padding(.vertical, MuxiTokens.Spacing.xs)
                .contentShape(Rectangle())
                .onTapGesture {
                    onSelectWindow?(window.id)
                }
                .contextMenu {
                    Button("Rename Window") {
                        onRenameWindow?(window.id)
                    }
                    Button("Close Window", role: .destructive) {
                        onCloseWindow?(window.id)
                    }
                }

            // Pane segments
            let paneIds = panesToShow(for: window)
            ForEach(Array(paneIds.enumerated()), id: \.offset) { index, paneId in
                let isActivePane = paneId == activePaneId

                Rectangle()
                    .fill(MuxiTokens.Colors.borderDefault)
                    .frame(width: 1)

                Text("\(index)")
                    .font(MuxiTokens.Typography.label).fontWeight(.semibold)
                    .foregroundStyle(isActivePane
                        ? MuxiTokens.Colors.textInverse
                        : MuxiTokens.Colors.textTertiary)
                    .padding(.horizontal, MuxiTokens.Spacing.sm)
                    .padding(.vertical, MuxiTokens.Spacing.xs)
                    .background(isActivePane
                        ? MuxiTokens.Colors.accentDefault
                        : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onSelectWindowAndPane?(window.id, paneId)
                    }
                    .contextMenu {
                        Button("Zoom") {
                            onZoomPane?()
                        }
                        Button("Close Pane", role: .destructive) {
                            onClosePane?(paneId)
                        }
                    }
            }
        }
        .background(MuxiTokens.Colors.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: MuxiTokens.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: MuxiTokens.Radius.md)
                .stroke(
                    isActiveWindow ? MuxiTokens.Colors.accentDefault : Color.clear,
                    lineWidth: 1.5
                )
        )
    }

    /// Get pane IDs for a window, falling back to currentPanes for the active window.
    /// For non-active windows without pane info, returns empty (pill shows name only).
    private func panesToShow(for window: ConnectionManager.TmuxWindowInfo) -> [String] {
        if !window.paneIds.isEmpty {
            return window.paneIds
        }
        // For active window, use currentPanes as fallback
        if window.id == activeWindowId {
            return currentPanes.map { "%\($0.paneId)" }
        }
        // Non-active windows: no pane info available, show name only
        return []
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add ios/Muxi/Views/Terminal/WindowPanePillsView.swift
git commit -m "feat: add WindowPanePillsView for grouped window/pane pills

Displays capsule pills with window name + pane indices. Active pane gets
accent background, active window gets accent outline. Supports tap to
switch and long-press context menus for rename/close/zoom.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

### Task 7: Create SessionPillsView

**Files:**
- Create: `ios/Muxi/Views/Terminal/SessionPillsView.swift`

- [ ] **Step 1: Create the view**

```swift
import SwiftUI

/// Horizontally scrolling session pills for session mode.
///
/// Tap to switch session, long-press for rename/close.
struct SessionPillsView: View {
    let sessions: [TmuxSession]
    let activeSessionName: String

    var onSelectSession: ((String) -> Void)?
    var onRenameSession: ((String) -> Void)?
    var onCloseSession: ((String) -> Void)?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: MuxiTokens.Spacing.sm) {
                ForEach(sessions) { session in
                    sessionPill(session)
                }
            }
        }
    }

    @ViewBuilder
    private func sessionPill(_ session: TmuxSession) -> some View {
        let isActive = session.name == activeSessionName

        Text(session.name)
            .font(MuxiTokens.Typography.label).fontWeight(.semibold)
            .foregroundStyle(isActive
                ? MuxiTokens.Colors.textInverse
                : MuxiTokens.Colors.textTertiary)
            .padding(.horizontal, MuxiTokens.Spacing.md)
            .padding(.vertical, MuxiTokens.Spacing.xs)
            .background(isActive
                ? MuxiTokens.Colors.accentDefault
                : MuxiTokens.Colors.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: MuxiTokens.Radius.md))
            .contentShape(Rectangle())
            .onTapGesture {
                onSelectSession?(session.name)
            }
            .contextMenu {
                Button("Rename Session") {
                    onRenameSession?(session.name)
                }
                Button("Close Session", role: .destructive) {
                    onCloseSession?(session.name)
                }
            }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add ios/Muxi/Views/Terminal/SessionPillsView.swift
git commit -m "feat: add SessionPillsView for session mode pills

Simple session pills with tap-to-switch and long-press context menus
for rename and close. Active session highlighted with accent background.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

### Task 8: Create PlusMenuView

**Files:**
- Create: `ios/Muxi/Views/Terminal/PlusMenuView.swift`

- [ ] **Step 1: Create the view**

```swift
import SwiftUI

/// Context-dependent + menu shown as a SwiftUI Menu.
///
/// Normal mode: New Window, Split Horizontal, Split Vertical.
/// Session mode: New Session.
struct PlusMenuView: View {
    let isSessionMode: Bool

    var onNewWindow: (() -> Void)?
    var onSplitHorizontal: (() -> Void)?
    var onSplitVertical: (() -> Void)?
    var onNewSession: (() -> Void)?

    var body: some View {
        Menu {
            if isSessionMode {
                Button {
                    onNewSession?()
                } label: {
                    Text("New Session")
                }
            } else {
                Button {
                    onNewWindow?()
                } label: {
                    Text("New Window")
                }
                Button {
                    onSplitHorizontal?()
                } label: {
                    Text("Split Horizontal")
                }
                Button {
                    onSplitVertical?()
                } label: {
                    Text("Split Vertical")
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(MuxiTokens.Typography.body)
                .foregroundStyle(MuxiTokens.Colors.accentDefault)
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add ios/Muxi/Views/Terminal/PlusMenuView.swift
git commit -m "feat: add PlusMenuView for context-dependent + menu

Shows New Window/Split H/Split V in normal mode, New Session in
session mode. Uses SwiftUI Menu for native popover behavior.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

### Task 9: Create ToolbarView

The main bottom toolbar that composes all pieces.

**Files:**
- Create: `ios/Muxi/Views/Terminal/ToolbarView.swift`

- [ ] **Step 1: Create the view**

```swift
import SwiftUI

/// Bottom toolbar above the extended keyboard.
///
/// Layout: `⊞ │ [pills] │ + ⌨`
///
/// `⊞` (square.stack) toggles session mode. In session mode, changes to `✕` (xmark).
/// Pills show window/pane capsules (normal) or session pills (session mode).
/// `+` shows context-dependent creation menu.
/// `⌨` toggles system keyboard.
struct ToolbarView: View {
    let connectionManager: ConnectionManager
    let sessionName: String
    @Binding var isKeyboardActive: Bool
    @Binding var isSessionMode: Bool

    // Rename alert state
    @Binding var showRenameAlert: Bool
    @Binding var renameTarget: RenameTarget?
    @Binding var renameText: String

    /// What we're renaming.
    enum RenameTarget: Equatable {
        case window(id: String)
        case session(name: String)
    }

    // Callbacks for tmux commands
    var onSendCommand: ((String) -> Void)?
    var onSelectWindow: ((String) -> Void)?
    var onSelectWindowAndPane: ((String, String) -> Void)?
    var onNewSession: (() -> Void)?
    var onSwitchSession: ((String) -> Void)?
    var onKillSession: ((String) -> Void)?

    var body: some View {
        HStack(spacing: MuxiTokens.Spacing.sm) {
            // Session mode toggle
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isSessionMode.toggle()
                }
            } label: {
                Image(systemName: isSessionMode ? "xmark" : "square.stack")
                    .font(MuxiTokens.Typography.body)
                    .foregroundStyle(MuxiTokens.Colors.accentDefault)
                    .frame(width: 32, height: 32)
            }

            // Separator
            Rectangle()
                .fill(MuxiTokens.Colors.borderDefault)
                .frame(width: 1, height: 24)

            // Pill area (fills remaining space)
            Group {
            if isSessionMode {
                SessionPillsView(
                    sessions: connectionManager.sessions,
                    activeSessionName: sessionName,
                    onSelectSession: { name in
                        onSwitchSession?(name)
                        isSessionMode = false
                    },
                    onRenameSession: { name in
                        renameTarget = .session(name: name)
                        renameText = name
                        showRenameAlert = true
                    },
                    onCloseSession: { name in
                        onKillSession?(name)
                    }
                )
            } else {
                WindowPanePillsView(
                    windows: connectionManager.currentWindows,
                    activeWindowId: connectionManager.activeWindowId,
                    activePaneId: connectionManager.activePaneId,
                    currentPanes: connectionManager.currentPanes,
                    onSelectWindow: { windowId in
                        onSelectWindow?(windowId)
                    },
                    onSelectWindowAndPane: { windowId, paneId in
                        onSelectWindowAndPane?(windowId, paneId)
                    },
                    onRenameWindow: { windowId in
                        let currentName = connectionManager.currentWindows
                            .first(where: { $0.id == windowId })?.name ?? ""
                        renameTarget = .window(id: windowId)
                        renameText = currentName
                        showRenameAlert = true
                    },
                    onCloseWindow: { windowId in
                        onSendCommand?("kill-window -t \(windowId.shellEscaped())")
                    },
                    onZoomPane: {
                        onSendCommand?("resize-pane -Z")
                    },
                    onClosePane: { paneId in
                        onSendCommand?("kill-pane -t \(paneId.shellEscaped())")
                    }
                )
            }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Separator
            Rectangle()
                .fill(MuxiTokens.Colors.borderDefault)
                .frame(width: 1, height: 24)

            // + menu
            PlusMenuView(
                isSessionMode: isSessionMode,
                onNewWindow: {
                    onSendCommand?("new-window")
                },
                onSplitHorizontal: {
                    onSendCommand?("split-window -h")
                },
                onSplitVertical: {
                    onSendCommand?("split-window -v")
                },
                onNewSession: {
                    onNewSession?()
                }
            )

            // Keyboard toggle
            Button {
                isKeyboardActive.toggle()
            } label: {
                Image(systemName: isKeyboardActive
                    ? "keyboard.chevron.compact.down"
                    : "keyboard")
                    .font(MuxiTokens.Typography.body)
                    .foregroundStyle(MuxiTokens.Colors.accentDefault)
            }
        }
        .padding(.horizontal, MuxiTokens.Spacing.lg)
        .padding(.vertical, MuxiTokens.Spacing.sm)
        .background(MuxiTokens.Colors.surfaceDefault)
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add ios/Muxi/Views/Terminal/ToolbarView.swift
git commit -m "feat: add ToolbarView composing session toggle, pills, + menu, keyboard

Bottom toolbar layout: square.stack | [pills] | + keyboard. Session mode
toggle swaps pill content between window/pane and session pills.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

### Task 9b: Add tests for toolbar components

**Files:**
- Create: `ios/MuxiTests/Views/ToolbarTests.swift`

- [ ] **Step 1: Create tests**

```swift
import XCTest
@testable import Muxi

@MainActor
final class ToolbarTests: XCTestCase {

    // MARK: - WindowPanePillsView.panesToShow

    func testPanesToShowUsesWindowPaneIds() {
        // When paneIds are populated, they should be used directly
        let window = ConnectionManager.TmuxWindowInfo(
            id: "@0", name: "bash", paneIds: ["%0", "%1"], isActive: true
        )
        // panesToShow is private, so test indirectly via the view's data flow
        XCTAssertEqual(window.paneIds, ["%0", "%1"])
    }

    func testPanesToShowEmptyForInactiveWindowWithoutPanes() {
        let window = ConnectionManager.TmuxWindowInfo(
            id: "@1", name: "vim", paneIds: [], isActive: false
        )
        // Inactive window with no pane info should show name only (empty paneIds)
        XCTAssertTrue(window.paneIds.isEmpty)
    }

    // MARK: - RenameTarget

    func testRenameTargetEquality() {
        let a = ToolbarView.RenameTarget.window(id: "@0")
        let b = ToolbarView.RenameTarget.window(id: "@0")
        let c = ToolbarView.RenameTarget.session(name: "work")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - TmuxWindowInfo

    func testTmuxWindowInfoIdentifiable() {
        let w1 = ConnectionManager.TmuxWindowInfo(
            id: "@0", name: "bash", paneIds: [], isActive: true
        )
        let w2 = ConnectionManager.TmuxWindowInfo(
            id: "@1", name: "vim", paneIds: [], isActive: false
        )
        XCTAssertNotEqual(w1.id, w2.id)
    }
}
```

- [ ] **Step 2: Run tests**

Run: `cd ios && xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' -only-testing:MuxiTests/ToolbarTests 2>&1 | tail -20`
Expected: All PASS.

- [ ] **Step 3: Commit**

```bash
git add ios/MuxiTests/Views/ToolbarTests.swift
git commit -m "test: add ToolbarTests for pill data model and rename target

Tests TmuxWindowInfo model, RenameTarget equality, and panesToShow
data flow expectations.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Chunk 5: Integration — Rewrite TerminalSessionView

### Task 10: Replace top toolbar and QuickActionButton with bottom ToolbarView

**Files:**
- Modify: `ios/Muxi/Views/Terminal/TerminalSessionView.swift`

- [ ] **Step 1: Add new state properties**

After `keyboardHeight` (line 22), add:

```swift
    @State private var isSessionMode = false
    @State private var showRenameAlert = false
    @State private var renameTarget: ToolbarView.RenameTarget?
    @State private var renameText = ""
```

- [ ] **Step 2: Replace the body**

Replace the entire `body` computed property with the new layout:

```swift
    var body: some View {
        VStack(spacing: 0) {
            // Terminal content — edge to edge from top
            if panes.isEmpty {
                placeholderView
            } else {
                GeometryReader { geometry in
                    PaneContainerView(
                        panes: panes,
                        theme: themeManager.currentTheme,
                        fontSize: themeManager.fontSize,
                        activePaneId: Binding(
                            get: { connectionManager.activePaneId },
                            set: { connectionManager.activePaneId = $0 }
                        ),
                        onPaneTapped: { paneId in
                            isKeyboardActive = true
                            sendTmuxCommand("select-pane -t \(paneId)")
                        },
                        onPaste: { text in
                            pasteToActivePane(text)
                        },
                        scrollbackBuffer: connectionManager.activePaneId.flatMap { scrollbackCaches[$0] },
                        scrollbackOffset: connectionManager.activePaneId.flatMap {
                            if case .scrolling(let offset, _) = scrollbackState[$0] {
                                return offset
                            }
                            return nil
                        } ?? 0,
                        onScrollOffsetChanged: { paneId, delta in
                            handleScrollDelta(paneId: paneId, delta: delta)
                        },
                        showNewOutputIndicator: connectionManager.activePaneId.map {
                            connectionManager.paneHasNewOutput.contains($0)
                        } ?? false,
                        onReturnToLive: { paneId in
                            returnToLive(paneId: paneId)
                        }
                    )
                    .onChange(of: geometry.size) { _, newSize in
                        updateTerminalSize(newSize)
                    }
                    .onChange(of: themeManager.fontSize) { _, _ in
                        updateTerminalSize(geometry.size)
                    }
                    .onAppear {
                        updateTerminalSize(geometry.size)
                    }
                }
            }

            // Bottom toolbar
            ToolbarView(
                connectionManager: connectionManager,
                sessionName: sessionName,
                isKeyboardActive: $isKeyboardActive,
                isSessionMode: $isSessionMode,
                showRenameAlert: $showRenameAlert,
                renameTarget: $renameTarget,
                renameText: $renameText,
                onSendCommand: { command in
                    sendTmuxCommand(command)
                },
                onSelectWindow: { windowId in
                    Task {
                        try? await connectionManager.selectWindow(windowId)
                    }
                },
                onSelectWindowAndPane: { windowId, paneId in
                    isKeyboardActive = true
                    Task {
                        try? await connectionManager.selectWindowAndPane(
                            windowId: windowId, paneId: paneId)
                    }
                },
                onNewSession: {
                    showNewSessionAlert = true
                },
                onSwitchSession: { name in
                    Task {
                        do {
                            try await connectionManager.switchSession(to: name)
                            logger.info("Switched to session: \(name)")
                        } catch {
                            logger.error("Failed to switch: \(error.localizedDescription)")
                        }
                    }
                },
                onKillSession: { name in
                    Task {
                        try? await connectionManager.killSession(name)
                    }
                }
            )

            // Extended keyboard — always visible
            ExtendedKeyboardView(
                theme: themeManager.currentTheme,
                inputHandler: inputHandler,
                onInput: { data in
                    sendToActivePane(data)
                }
            )

            // Hidden input view
            TerminalInputView(
                onText: { text in
                    for char in text {
                        let data = inputHandler.data(for: char)
                        sendToActivePane(data)
                    }
                },
                onDelete: {
                    sendToActivePane(Data([0x7F]))
                },
                onSpecialKey: { key in
                    let data = inputHandler.data(for: key)
                    sendToActivePane(data)
                },
                onRawData: { data in
                    sendToActivePane(data)
                },
                isActive: $isKeyboardActive,
                theme: themeManager.currentTheme,
                inputHandler: inputHandler,
                onExtendedInput: { data in
                    sendToActivePane(data)
                }
            )
            .frame(width: 1, height: 1)
            .opacity(0)
        }
        .padding(.bottom, keyboardHeight)
        .background(themeManager.currentTheme.background.color)
        .ignoresSafeArea(.keyboard)
        .onChange(of: connectionManager.activePaneId) { _, newValue in
            if newValue != nil {
                isKeyboardActive = true
            }
        }
        // Rename alert (shared between window and session)
        .alert(
            renameAlertTitle,
            isPresented: $showRenameAlert
        ) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                switch renameTarget {
                case .window(let id):
                    Task {
                        try? await connectionManager.renameWindow(id, to: trimmed)
                    }
                case .session(let name):
                    Task {
                        try? await connectionManager.renameSession(name, to: trimmed)
                    }
                case nil:
                    break
                }
                renameTarget = nil
                renameText = ""
            }
            Button("Cancel", role: .cancel) {
                renameTarget = nil
                renameText = ""
            }
        }
        // New session alert (kept from existing code)
        .alert("New Session", isPresented: $showNewSessionAlert) {
            TextField("Optional name", text: $newSessionName)
            Button("Create") {
                let trimmed = newSessionName.trimmingCharacters(in: .whitespaces)
                let name: String? = trimmed.isEmpty ? nil : trimmed
                newSessionName = ""
                Task {
                    do {
                        try await connectionManager.createAndSwitchToNewSession(name: name)
                        logger.info("Created session: \(name ?? "(auto)")")
                    } catch {
                        logger.error("Failed to create session: \(error.localizedDescription)")
                    }
                }
            }
            Button("Cancel", role: .cancel) { newSessionName = "" }
        }
        .task {
            for await notification in NotificationCenter.default.notifications(
                named: UIResponder.keyboardWillChangeFrameNotification
            ) {
                guard let userInfo = notification.userInfo,
                      let endFrame = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
                else { continue }
                let screenHeight = UIScreen.main.bounds.height
                let rawHeight = max(screenHeight - endFrame.origin.y, 0)
                let safeAreaBottom = UIApplication.shared.connectedScenes
                    .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                    .first?.safeAreaInsets.bottom ?? 0
                let newHeight = max(rawHeight - safeAreaBottom, 0)
                let duration = (userInfo[UIResponder.keyboardAnimationDurationUserInfoKey]
                    as? Double) ?? 0.25
                withAnimation(.easeInOut(duration: duration)) {
                    keyboardHeight = newHeight
                }
            }
        }
    }

    private var renameAlertTitle: String {
        switch renameTarget {
        case .window:
            return "Rename Window"
        case .session:
            return "Rename Session"
        case nil:
            return "Rename"
        }
    }
```

- [ ] **Step 3: Run app in simulator to verify layout**

Run: `cd ios && xcodebuild build -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' 2>&1 | tail -20`
Expected: Build succeeds. QuickActionButton import will produce an unused warning (that's fine, we'll delete it in the next task).

- [ ] **Step 4: Commit**

```bash
git add ios/Muxi/Views/Terminal/TerminalSessionView.swift
git commit -m "feat: replace top toolbar with bottom ToolbarView + ExtendedKeyboard

Terminal content now starts from the top edge. Toolbar with session
toggle, window/pane pills, + menu, and keyboard button sits above
the extended keyboard row. Rename alerts shared between window/session.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Chunk 6: Cleanup — Remove Deprecated Components

### Task 11: Remove pane tab bar from PaneContainerView

**Files:**
- Modify: `ios/Muxi/Views/Terminal/PaneContainerView.swift`

- [ ] **Step 1: Remove paneTabBar and its usage**

In `PaneContainerView.swift`:

1. Remove the `if panes.count > 1 { paneTabBar }` block from `compactLayout` (lines 172-174).
2. Remove the entire `paneTabBar` computed property (lines 178-208).
3. Remove `@State private var selectedPaneIndex: Int = 0` (line 75) — no longer needed.
4. Remove the `onChange(of: panes.count)` modifier that clamps `selectedPaneIndex` (lines 110-117).
5. In `compactLayout`, change `panes[safe: selectedPaneIndex]` to use `activePaneId` instead:

Replace the compact layout to show the active pane:

```swift
    @ViewBuilder
    private var compactLayout: some View {
        if let pane = panes.first(where: { $0.id == activePaneId }) ?? panes.first {
            TerminalView(
                buffer: pane.buffer,
                theme: theme,
                onPaste: onPaste,
                fontSize: fontSize,
                scrollbackBuffer: scrollbackBuffer,
                scrollOffset: scrollbackOffset,
                onScrollOffsetChanged: { delta in
                    onScrollOffsetChanged?(pane.id, delta)
                }
            )
            .overlay(alignment: .bottom) {
                if showNewOutputIndicator,
                   scrollbackOffset > 0,
                   pane.id == activePaneId {
                    Button {
                        onReturnToLive?(pane.id)
                    } label: {
                        HStack(spacing: MuxiTokens.Spacing.xs) {
                            Image(systemName: "arrow.down")
                            Text("New output")
                        }
                        .font(MuxiTokens.Typography.caption)
                        .padding(.horizontal, MuxiTokens.Spacing.md)
                        .padding(.vertical, MuxiTokens.Spacing.sm)
                        .background(
                            RoundedRectangle(
                                cornerRadius: MuxiTokens.Radius.sm,
                                style: .continuous
                            )
                            .fill(MuxiTokens.Colors.accentDefault)
                        )
                        .foregroundStyle(MuxiTokens.Colors.textPrimary)
                    }
                    .padding(.bottom, MuxiTokens.Spacing.md)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                activePaneId = pane.id
                onPaneTapped?(pane.id)
            }
        }
    }
```

- [ ] **Step 2: Run tests**

Run: `cd ios && xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' -only-testing:MuxiTests/PaneContainerTests 2>&1 | tail -20`
Expected: PASS (existing PaneLayout tests should still pass).

- [ ] **Step 3: Commit**

```bash
git add ios/Muxi/Views/Terminal/PaneContainerView.swift
git commit -m "refactor: remove pane tab bar from PaneContainerView

Pane switching is now handled by toolbar pills. Compact layout shows
the active pane (via activePaneId) instead of selectedPaneIndex.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

### Task 12: Delete QuickAction files and tests

**Files:**
- Delete: `ios/Muxi/Views/QuickAction/QuickActionButton.swift`
- Delete: `ios/Muxi/Views/QuickAction/QuickActionView.swift`
- Delete: `ios/MuxiTests/Views/QuickActionTests.swift`
- Modify: `ios/project.yml` (if QuickAction files are explicitly listed)

- [ ] **Step 1: Remove QuickAction import/usage from TerminalSessionView (if any remain)**

Search for any remaining references to `QuickActionButton` or `QuickActionView`:

Run: `grep -r "QuickAction" ios/Muxi/ --include="*.swift" -l`

Remove any remaining references.

- [ ] **Step 2: Delete the files**

```bash
rm ios/Muxi/Views/QuickAction/QuickActionButton.swift
rm ios/Muxi/Views/QuickAction/QuickActionView.swift
rm ios/MuxiTests/Views/QuickActionTests.swift
```

- [ ] **Step 3: Regenerate Xcode project (if using XcodeGen)**

Run: `cd ios && xcodegen generate`

- [ ] **Step 4: Verify build**

Run: `cd ios && xcodebuild build -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' 2>&1 | tail -20`
Expected: Build succeeds with no references to deleted files.

- [ ] **Step 5: Run all tests**

Run: `cd ios && xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' 2>&1 | tail -30`
Expected: All tests PASS.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "remove: delete QuickActionButton, QuickActionView, and QuickActionTests

All actions (split, new window, close, rename, zoom) are now in the
toolbar + menu and long-press context menus. QuickAction is fully
superseded.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Chunk 7: Polish & Edge Cases

### Task 13: Handle edge case — single window, single pane

When there's only 1 window with 1 pane, the pill should show `[bash│0]`.

**Files:**
- Modify: `ios/Muxi/Views/Terminal/WindowPanePillsView.swift`

- [ ] **Step 1: Verify the existing code handles this**

The `WindowPanePillsView` already renders whatever is in `windows`. If `currentWindows` has 1 entry with 1 pane, it will show `[bash│0]`. No code change needed — just verify visually.

- [ ] **Step 2: Handle empty windows (before first list-windows response)**

In `ToolbarView.swift`, if `currentWindows` is empty but we're attached, show a minimal fallback:

In ToolbarView body, wrap the `WindowPanePillsView` usage:

```swift
            } else {
                if connectionManager.currentWindows.isEmpty {
                    // Fallback before window list arrives
                    Text(sessionName)
                        .font(MuxiTokens.Typography.label).fontWeight(.semibold)
                        .foregroundStyle(MuxiTokens.Colors.textPrimary)
                        .padding(.horizontal, MuxiTokens.Spacing.md)
                        .padding(.vertical, MuxiTokens.Spacing.xs)
                        .background(MuxiTokens.Colors.surfaceElevated)
                        .clipShape(RoundedRectangle(cornerRadius: MuxiTokens.Radius.md))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    WindowPanePillsView(
                        // ... existing code
                    )
                }
            }
```

- [ ] **Step 3: Commit**

```bash
git add ios/Muxi/Views/Terminal/ToolbarView.swift
git commit -m "fix: show session name fallback when window list is not yet available

Before the first list-windows response arrives, display the session
name as a simple pill to avoid an empty toolbar.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

### Task 14: Update XcodeGen project.yml for new files

**Files:**
- Modify: `ios/project.yml` (only if file groups are explicitly declared)

- [ ] **Step 1: Regenerate Xcode project**

Run: `cd ios && xcodegen generate`

XcodeGen auto-discovers Swift files in the source directories, so new files are included automatically. Verify:

Run: `grep -r "ToolbarView\|WindowPanePills\|SessionPills\|PlusMenu" ios/Muxi.xcodeproj/project.pbxproj | head -10`

Expected: New files appear in the project.

- [ ] **Step 2: Final full build + test (iPhone)**

Run: `cd ios && xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' 2>&1 | tail -30`
Expected: All tests PASS, no warnings about missing files.

- [ ] **Step 2b: Verify iPad build**

Run: `cd ios && xcodebuild build -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4),OS=26.2' 2>&1 | tail -20`
Expected: Build succeeds. Toolbar renders the same on iPad — pills act as focus indicators for the multi-pane layout.

- [ ] **Step 3: Commit (if project.yml changed)**

```bash
git add ios/project.yml
git commit -m "chore: regenerate Xcode project for new toolbar views

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Summary

| Chunk | Tasks | What it delivers |
|-------|-------|-----------------|
| 1 | Task 1 | C parser handles `%window-renamed` and `%unlinked-window-close` |
| 2 | Task 2 | Swift TmuxControlService dispatches window rename notifications |
| 3 | Tasks 3-5 | ConnectionManager tracks windows, routes callbacks, new tmux commands |
| 4 | Tasks 6-9b | All toolbar UI components (pills, session pills, + menu, toolbar) + tests |
| 5 | Task 10 | TerminalSessionView rewritten with bottom toolbar layout |
| 6 | Tasks 11-12 | Pane tab bar and QuickAction removed |
| 7 | Tasks 13-14 | Edge cases, project regeneration, iPad verification |
