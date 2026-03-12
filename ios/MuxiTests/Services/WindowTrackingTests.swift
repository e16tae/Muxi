import XCTest
@testable import Muxi

@MainActor
final class WindowTrackingTests: XCTestCase {

    private func makeManager() -> ConnectionManager {
        ConnectionManager(sshService: MockSSHService())
    }

    /// Create a manager with a connected mock SSH service (for testing
    /// methods that write to the control channel).
    private func makeConnectedManager() -> ConnectionManager {
        let mock = MockSSHService()
        mock.state = .connected
        return ConnectionManager(sshService: mock)
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

    // MARK: - Window State Management

    func testWindowCloseRemovesFromArray() {
        let manager = makeManager()
        manager.setWindowsForTesting([
            .init(id: "@0", name: "bash", paneIds: ["%0"], isActive: true),
            .init(id: "@1", name: "vim", paneIds: ["%1"], isActive: false),
        ], activeId: "@0")
        manager.activePaneId = "%0"
        manager.setPaneBuffersForTesting(["%0": TerminalBuffer(cols: 80, rows: 24)])

        manager.handleWindowClose("@0")

        XCTAssertEqual(manager.currentWindows.count, 1)
        XCTAssertEqual(manager.currentWindows[0].id, "@1")
        XCTAssertEqual(manager.activeWindowId, "@1")
        // Pane state must be cleared when the active window is closed
        XCTAssertNil(manager.activePaneId)
        XCTAssertTrue(manager.paneBuffers.isEmpty)
        XCTAssertTrue(manager.currentPanes.isEmpty)
    }

    func testWindowCloseNonActivePreservesPaneState() {
        let manager = makeManager()
        manager.setWindowsForTesting([
            .init(id: "@0", name: "bash", paneIds: ["%0"], isActive: true),
            .init(id: "@1", name: "vim", paneIds: ["%1"], isActive: false),
        ], activeId: "@0")
        manager.activePaneId = "%0"
        manager.setPaneBuffersForTesting(["%0": TerminalBuffer(cols: 80, rows: 24)])

        manager.handleWindowClose("@1")

        XCTAssertEqual(manager.currentWindows.count, 1)
        XCTAssertEqual(manager.activeWindowId, "@0")
        // Pane state must be preserved when a non-active window is closed
        XCTAssertEqual(manager.activePaneId, "%0")
        XCTAssertEqual(manager.paneBuffers.count, 1)
    }

    func testWindowRenameUpdatesName() {
        let manager = makeManager()
        manager.setWindowsForTesting([
            .init(id: "@0", name: "bash", paneIds: [], isActive: true),
        ])

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

    func testListWindowsResponsePreservesActiveWindowId() {
        let manager = makeManager()
        // Simulate: already on @0, then new-window creates @1 (tmux reports @1 active)
        manager.setWindowsForTesting([
            .init(id: "@0", name: "bash", paneIds: ["%0"], isActive: true),
        ], activeId: "@0")
        manager.activePaneId = "%0"

        let response = "@0\t0\tbash\t0\n@1\t1\tbash\t1"
        manager.handleListWindowsResponse(response)

        // activeWindowId must stay @0 — it still exists in the list
        XCTAssertEqual(manager.activeWindowId, "@0")
        XCTAssertEqual(manager.currentWindows.count, 2)
        XCTAssertEqual(manager.activePaneId, "%0")
    }

    func testListWindowsResponseUpdatesActiveWhenWindowGone() {
        let manager = makeManager()
        manager.setWindowsForTesting([
            .init(id: "@0", name: "bash", paneIds: ["%0"], isActive: true),
            .init(id: "@1", name: "vim", paneIds: ["%1"], isActive: false),
        ], activeId: "@0")

        // @0 gone from the list, only @1 remains
        let response = "@1\t0\tvim\t1"
        manager.handleListWindowsResponse(response)

        XCTAssertEqual(manager.activeWindowId, "@1")
        XCTAssertEqual(manager.currentWindows.count, 1)
    }

    // MARK: - list-panes Parsing

    func testParseListPanes() {
        let output = "@0\t%0\n@0\t%1\n@1\t%2"
        let mapping = ConnectionManager.parseListPanes(output)
        XCTAssertEqual(mapping["@0"], ["%0", "%1"])
        XCTAssertEqual(mapping["@1"], ["%2"])
    }

    func testParseListPanesEmpty() {
        let mapping = ConnectionManager.parseListPanes("")
        XCTAssertTrue(mapping.isEmpty)
    }

    func testParseListPanesMalformed() {
        let output = "@0\n%1"  // missing tab separator
        let mapping = ConnectionManager.parseListPanes(output)
        XCTAssertTrue(mapping.isEmpty)
    }

    func testHandleListPanesResponsePopulatesPaneIds() {
        let manager = makeManager()
        // Simulate list-windows already arrived
        manager.handleListWindowsResponse("@0\t0\tbash\t1\n@1\t1\tvim\t0")
        XCTAssertEqual(manager.currentWindows[0].paneIds, [])
        XCTAssertEqual(manager.currentWindows[1].paneIds, [])

        // list-panes response arrives
        manager.handleListPanesResponse("@0\t%0\n@0\t%1\n@1\t%2")

        XCTAssertEqual(manager.currentWindows[0].paneIds, ["%0", "%1"])
        XCTAssertEqual(manager.currentWindows[1].paneIds, ["%2"])
    }

    func testHandleListPanesResponsePreservesUnmatchedWindows() {
        let manager = makeManager()
        manager.handleListWindowsResponse("@0\t0\tbash\t1\n@1\t1\tvim\t0")

        // list-panes only has @0 (tmux might not report empty windows)
        manager.handleListPanesResponse("@0\t%0")

        XCTAssertEqual(manager.currentWindows[0].paneIds, ["%0"])
        XCTAssertEqual(manager.currentWindows[1].paneIds, [])
    }

    func testUpdateWindowPaneMappingSyncsActivePanes() {
        let manager = makeManager()
        manager.wireCallbacksForTesting()
        manager.handleListWindowsResponse("@0\t0\tbash\t1\n@1\t1\tvim\t0")

        // Simulate layout-change setting currentPanes for active window
        let panes = [
            TmuxControlService.ParsedPane(x: 0, y: 0, width: 80, height: 12, paneId: 0),
            TmuxControlService.ParsedPane(x: 0, y: 12, width: 80, height: 12, paneId: 1),
        ]
        manager.simulateLayoutChange(windowId: "@0", panes: panes)

        // Now simulate list-windows arriving again (replaces currentWindows)
        manager.handleListWindowsResponse("@0\t0\tbash\t1\n@1\t1\tvim\t0")

        // updateWindowPaneMapping should have restored active window's paneIds
        XCTAssertEqual(manager.currentWindows[0].paneIds, ["%0", "%1"])
    }

    // MARK: - Session/Window Command Tests

    func testRenameSessionUpdatesLocalState() async throws {
        let manager = makeConnectedManager()
        manager.setSessionsForTesting([
            TmuxSession(id: "$0", name: "work", windows: [], createdAt: Date(), lastActivity: Date()),
            TmuxSession(id: "$1", name: "dev", windows: [], createdAt: Date(), lastActivity: Date()),
        ])
        manager.setStateForTesting(.attached(sessionName: "work"))

        try await manager.renameSession("work", to: "office")

        XCTAssertEqual(manager.sessions[0].name, "office")
        if case .attached(let name) = manager.state {
            XCTAssertEqual(name, "office")
        } else {
            XCTFail("Expected .attached state")
        }
    }

    func testKillSessionRemovesFromArray() async throws {
        let manager = makeConnectedManager()
        manager.setSessionsForTesting([
            TmuxSession(id: "$0", name: "work", windows: [], createdAt: Date(), lastActivity: Date()),
            TmuxSession(id: "$1", name: "dev", windows: [], createdAt: Date(), lastActivity: Date()),
        ])
        manager.setStateForTesting(.attached(sessionName: "work"))

        try await manager.killSession("dev")

        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertEqual(manager.sessions[0].name, "work")
    }

    func testRenameWindowUpdatesLocalState() async throws {
        let manager = makeConnectedManager()
        manager.setWindowsForTesting([
            .init(id: "@0", name: "bash", paneIds: [], isActive: true),
        ])
        manager.setStateForTesting(.attached(sessionName: "work"))

        try await manager.renameWindow("@0", to: "zsh")

        XCTAssertEqual(manager.currentWindows[0].name, "zsh")
    }

    func testSelectWindowRequiresAttachedState() async throws {
        let manager = makeManager()
        // Not attached — should return without error
        try await manager.selectWindow("@0")
    }

    func testSelectWindowAndPaneRequiresAttachedState() async throws {
        let manager = makeManager()
        try await manager.selectWindowAndPane(windowId: "@0", paneId: "%0")
    }

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

    // MARK: - selectWindowAndPane Tests

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
        XCTAssertEqual(manager.activePaneId, "%1")  // optimistically set
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

    // MARK: - switchingToWindowId Reset Tests

    func testDisconnectClearsSwitchingToWindowId() async throws {
        let manager = makeConnectedManager()
        manager.setWindowsForTesting([
            .init(id: "@0", name: "bash", paneIds: ["%0"], isActive: true),
            .init(id: "@1", name: "vim", paneIds: ["%1"], isActive: false),
        ], activeId: "@0")
        manager.setStateForTesting(.attached(sessionName: "work"))

        try await manager.selectWindow("@1")
        XCTAssertEqual(manager.switchingToWindowId, "@1")

        manager.disconnect()
        XCTAssertNil(manager.switchingToWindowId)
    }

    // MARK: - onLayoutChange Guard Tests

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

    // MARK: - %window-pane-changed Auto-Focus Tests

    func testWindowPaneChangedSameWindowUpdatesActivePane() {
        let manager = makeManager()
        manager.wireCallbacksForTesting()
        manager.setWindowsForTesting([
            .init(id: "@0", name: "bash", paneIds: ["%0", "%1"], isActive: true),
        ], activeId: "@0")
        manager.activePaneId = "%0"

        // Same-window pane change (e.g., split-window)
        manager.simulateWindowPaneChanged(windowId: "@0", paneId: "%1")
        XCTAssertEqual(manager.activePaneId, "%1")
        XCTAssertEqual(manager.activeWindowId, "@0")
    }

    func testSessionWindowChangedSwitchesWindow() {
        let manager = makeManager()
        manager.wireCallbacksForTesting()
        manager.setWindowsForTesting([
            .init(id: "@0", name: "bash", paneIds: ["%0"], isActive: true),
            .init(id: "@1", name: "vim", paneIds: ["%1"], isActive: false),
        ], activeId: "@0")
        manager.activePaneId = "%0"

        // Session window changed (e.g., new-window)
        manager.simulateSessionWindowChanged(sessionId: "$0", windowId: "@1")

        // Should switch to the new window
        XCTAssertEqual(manager.activeWindowId, "@1")
        // switchingToWindowId set by prepareWindowSwitch, cleared by next layout-change
        XCTAssertEqual(manager.switchingToWindowId, "@1")
        // currentPanes cleared during transition
        XCTAssertTrue(manager.currentPanes.isEmpty)
    }

    func testSessionWindowChangedIgnoredForSameWindow() {
        let manager = makeManager()
        manager.wireCallbacksForTesting()
        manager.setWindowsForTesting([
            .init(id: "@0", name: "bash", paneIds: ["%0"], isActive: true),
        ], activeId: "@0")
        manager.activePaneId = "%0"

        // Same window — should be ignored
        manager.simulateSessionWindowChanged(sessionId: "$0", windowId: "@0")

        // Nothing changed
        XCTAssertEqual(manager.activeWindowId, "@0")
        XCTAssertEqual(manager.activePaneId, "%0")
        XCTAssertNil(manager.switchingToWindowId)
    }

    /// End-to-end: %session-window-changed → prepareWindowSwitch → %layout-change resolves.
    func testSessionWindowChangedThenLayoutChangeResolvesTransition() {
        let manager = makeManager()
        manager.wireCallbacksForTesting()
        manager.setWindowsForTesting([
            .init(id: "@0", name: "bash", paneIds: ["%0"], isActive: true),
            .init(id: "@1", name: "vim", paneIds: ["%1"], isActive: false),
        ], activeId: "@0")
        manager.activePaneId = "%0"

        // Step 1: %session-window-changed switches to @1
        manager.simulateSessionWindowChanged(sessionId: "$0", windowId: "@1")

        XCTAssertEqual(manager.activeWindowId, "@1")
        XCTAssertEqual(manager.switchingToWindowId, "@1")
        XCTAssertTrue(manager.currentPanes.isEmpty)

        // Step 2: %layout-change for @1 arrives (from forceLayoutRefresh)
        let newPanes = [TmuxControlService.ParsedPane(x: 0, y: 0, width: 120, height: 36, paneId: 5)]
        manager.simulateLayoutChange(windowId: "@1", panes: newPanes)

        // Transition fully resolved
        XCTAssertNil(manager.switchingToWindowId)
        XCTAssertEqual(manager.currentPanes.count, 1)
        XCTAssertEqual(manager.activePaneId, "%5")
        XCTAssertEqual(manager.activeWindowId, "@1")
        // Buffer created for the new pane
        XCTAssertNotNil(manager.paneBuffers["%5"])
        // Old pane buffer cleaned up
        XCTAssertNil(manager.paneBuffers["%0"])
        // Window active flags updated
        XCTAssertFalse(manager.currentWindows.first(where: { $0.id == "@0" })?.isActive ?? true)
        XCTAssertTrue(manager.currentWindows.first(where: { $0.id == "@1" })?.isActive ?? false)
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
}
