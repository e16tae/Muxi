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

    // MARK: - Zoom State Tests

    func testZoomLayoutChangeSetsIsZoomed() {
        let manager = makeManager()
        manager.wireCallbacksForTesting()
        manager.setWindowsForTesting([
            .init(id: "@0", name: "bash", paneIds: ["%0", "%1"], isActive: true),
        ], activeId: "@0")
        manager.activePaneId = "%0"

        // Zoomed layout-change: only the zoomed pane
        let zoomedPanes = [TmuxControlService.ParsedPane(x: 0, y: 0, width: 80, height: 24, paneId: 0)]
        manager.simulateLayoutChange(windowId: "@0", panes: zoomedPanes, isZoomed: true)

        XCTAssertTrue(manager.isZoomed)
        XCTAssertEqual(manager.currentPanes.count, 1)
        XCTAssertEqual(manager.activePaneId, "%0")
    }

    func testUnzoomLayoutChangeClearsIsZoomed() {
        let manager = makeManager()
        manager.wireCallbacksForTesting()
        manager.setWindowsForTesting([
            .init(id: "@0", name: "bash", paneIds: ["%0", "%1"], isActive: true),
        ], activeId: "@0")
        manager.activePaneId = "%0"

        // First: zoom
        let zoomedPanes = [TmuxControlService.ParsedPane(x: 0, y: 0, width: 80, height: 24, paneId: 0)]
        manager.simulateLayoutChange(windowId: "@0", panes: zoomedPanes, isZoomed: true)
        XCTAssertTrue(manager.isZoomed)

        // Then: unzoom
        let normalPanes = [
            TmuxControlService.ParsedPane(x: 0, y: 0, width: 40, height: 24, paneId: 0),
            TmuxControlService.ParsedPane(x: 41, y: 0, width: 39, height: 24, paneId: 1),
        ]
        manager.simulateLayoutChange(windowId: "@0", panes: normalPanes, isZoomed: false)

        XCTAssertFalse(manager.isZoomed)
        XCTAssertEqual(manager.currentPanes.count, 2)
    }

    func testNonActiveWindowLayoutChangeDoesNotAffectZoom() {
        let manager = makeManager()
        manager.wireCallbacksForTesting()
        manager.setWindowsForTesting([
            .init(id: "@0", name: "bash", paneIds: ["%0"], isActive: true),
            .init(id: "@1", name: "vim", paneIds: ["%1"], isActive: false),
        ], activeId: "@0")
        manager.activePaneId = "%0"

        // Active window is zoomed
        let zoomedPanes = [TmuxControlService.ParsedPane(x: 0, y: 0, width: 80, height: 24, paneId: 0)]
        manager.simulateLayoutChange(windowId: "@0", panes: zoomedPanes, isZoomed: true)
        XCTAssertTrue(manager.isZoomed)

        // Non-active window's layout-change (isZoomed=false) must NOT clear zoom
        let otherPanes = [TmuxControlService.ParsedPane(x: 0, y: 0, width: 80, height: 24, paneId: 1)]
        manager.simulateLayoutChange(windowId: "@1", panes: otherPanes, isZoomed: false)
        XCTAssertTrue(manager.isZoomed, "Non-active window layout-change must not overwrite zoom state")
    }

    func testZoomLayoutChangePreservesPaneIds() {
        let manager = makeManager()
        manager.wireCallbacksForTesting()
        manager.setWindowsForTesting([
            .init(id: "@0", name: "bash", paneIds: ["%0", "%1"], isActive: true),
        ], activeId: "@0")
        manager.activePaneId = "%0"

        // Zoomed layout-change: visible_layout contains only zoomed pane
        let zoomedPanes = [TmuxControlService.ParsedPane(x: 0, y: 0, width: 80, height: 24, paneId: 0)]
        manager.simulateLayoutChange(windowId: "@0", panes: zoomedPanes, isZoomed: true)

        XCTAssertTrue(manager.isZoomed)
        // Pane pills must still show all panes so user can switch
        XCTAssertEqual(manager.currentWindows[0].paneIds, ["%0", "%1"],
                       "Zoomed layout must not overwrite full pane list")
    }

    func testNonActiveWindowZoomPreservesPaneIds() {
        let manager = makeManager()
        manager.wireCallbacksForTesting()
        manager.setWindowsForTesting([
            .init(id: "@0", name: "bash", paneIds: ["%0"], isActive: true),
            .init(id: "@1", name: "vim", paneIds: ["%1", "%2"], isActive: false),
        ], activeId: "@0")
        manager.activePaneId = "%0"

        // Non-active window gets zoomed layout-change
        let zoomedPanes = [TmuxControlService.ParsedPane(x: 0, y: 0, width: 80, height: 24, paneId: 1)]
        manager.simulateLayoutChange(windowId: "@1", panes: zoomedPanes, isZoomed: true)

        // Non-active window's pane list preserved
        XCTAssertEqual(manager.currentWindows[1].paneIds, ["%1", "%2"],
                       "Zoomed layout on non-active window must not shrink pane list")
    }

    func testDisconnectClearsIsZoomed() {
        let manager = makeManager()
        manager.wireCallbacksForTesting()
        manager.setWindowsForTesting([
            .init(id: "@0", name: "bash", paneIds: ["%0"], isActive: true),
        ], activeId: "@0")

        let panes = [TmuxControlService.ParsedPane(x: 0, y: 0, width: 80, height: 24, paneId: 0)]
        manager.simulateLayoutChange(windowId: "@0", panes: panes, isZoomed: true)
        XCTAssertTrue(manager.isZoomed)

        manager.disconnect()
        XCTAssertFalse(manager.isZoomed)
    }

    func testPrepareWindowSwitchClearsIsZoomed() async throws {
        let manager = makeConnectedManager()
        manager.wireCallbacksForTesting()
        manager.setWindowsForTesting([
            .init(id: "@0", name: "bash", paneIds: ["%0"], isActive: true),
            .init(id: "@1", name: "vim", paneIds: ["%1"], isActive: false),
        ], activeId: "@0")
        manager.setStateForTesting(.attached(sessionName: "work"))
        manager.activePaneId = "%0"

        let panes = [TmuxControlService.ParsedPane(x: 0, y: 0, width: 80, height: 24, paneId: 0)]
        manager.simulateLayoutChange(windowId: "@0", panes: panes, isZoomed: true)
        XCTAssertTrue(manager.isZoomed)

        // Window switch clears zoom
        try await manager.selectWindow("@1")
        XCTAssertFalse(manager.isZoomed)
    }

    // MARK: - Mobile Auto-Zoom Tests

    func testMobileAutoZoomSendsZoomOnUnzoomedMultiPane() {
        let manager = makeConnectedManager()
        manager.wireCallbacksForTesting()
        manager.mobileAutoZoom = true
        manager.setWindowsForTesting([
            .init(id: "@0", name: "bash", paneIds: ["%0", "%1"], isActive: true),
        ], activeId: "@0")
        manager.activePaneId = "%0"
        manager.setPaneBuffersForTesting(["%0": TerminalBuffer(cols: 80, rows: 24)])

        // Unzoomed layout with 2 panes — auto-zoom should suppress layout processing
        let panes = [
            TmuxControlService.ParsedPane(x: 0, y: 0, width: 40, height: 24, paneId: 0),
            TmuxControlService.ParsedPane(x: 41, y: 0, width: 39, height: 24, paneId: 1),
        ]
        manager.simulateLayoutChange(windowId: "@0", panes: panes, isZoomed: false)

        // currentPanes should NOT be updated (early return)
        XCTAssertEqual(manager.currentPanes.count, 0,
                        "Auto-zoom should skip layout processing")
        // pendingAutoZoom should be set
        XCTAssertTrue(manager.pendingAutoZoomForTesting)
        // Buffer should not be resized to split dimensions
        XCTAssertEqual(manager.paneBuffers["%0"]?.cols, 80)
    }

    func testMobileAutoZoomSkipsSinglePane() {
        let manager = makeManager()
        manager.wireCallbacksForTesting()
        manager.mobileAutoZoom = true
        manager.setWindowsForTesting([
            .init(id: "@0", name: "bash", paneIds: ["%0"], isActive: true),
        ], activeId: "@0")
        manager.activePaneId = "%0"

        // Unzoomed layout with 1 pane — normal processing
        let panes = [TmuxControlService.ParsedPane(x: 0, y: 0, width: 80, height: 24, paneId: 0)]
        manager.simulateLayoutChange(windowId: "@0", panes: panes, isZoomed: false)

        // Normal processing: currentPanes updated
        XCTAssertEqual(manager.currentPanes.count, 1)
        XCTAssertFalse(manager.pendingAutoZoomForTesting)
    }

    func testMobileAutoZoomClearedOnZoomedLayout() {
        let manager = makeConnectedManager()
        manager.wireCallbacksForTesting()
        manager.mobileAutoZoom = true
        manager.setWindowsForTesting([
            .init(id: "@0", name: "bash", paneIds: ["%0", "%1"], isActive: true),
        ], activeId: "@0")
        manager.activePaneId = "%0"
        manager.setPaneBuffersForTesting(["%0": TerminalBuffer(cols: 80, rows: 24)])

        // First: unzoomed multi-pane triggers auto-zoom
        let unzoomedPanes = [
            TmuxControlService.ParsedPane(x: 0, y: 0, width: 40, height: 24, paneId: 0),
            TmuxControlService.ParsedPane(x: 41, y: 0, width: 39, height: 24, paneId: 1),
        ]
        manager.simulateLayoutChange(windowId: "@0", panes: unzoomedPanes, isZoomed: false)
        XCTAssertTrue(manager.pendingAutoZoomForTesting)

        // Then: zoomed layout arrives — should clear pendingAutoZoom and process normally
        let zoomedPanes = [TmuxControlService.ParsedPane(x: 0, y: 0, width: 80, height: 24, paneId: 0)]
        manager.simulateLayoutChange(windowId: "@0", panes: zoomedPanes, isZoomed: true)

        XCTAssertFalse(manager.pendingAutoZoomForTesting)
        XCTAssertTrue(manager.isZoomed)
        XCTAssertEqual(manager.currentPanes.count, 1)
    }

    func testMobileAutoZoomPreventsDoubleZoom() {
        let manager = makeConnectedManager()
        manager.wireCallbacksForTesting()
        manager.mobileAutoZoom = true
        manager.setWindowsForTesting([
            .init(id: "@0", name: "bash", paneIds: ["%0", "%1"], isActive: true),
        ], activeId: "@0")
        manager.activePaneId = "%0"
        manager.setPaneBuffersForTesting(["%0": TerminalBuffer(cols: 80, rows: 24)])

        // First unzoomed layout — sets pendingAutoZoom
        let panes = [
            TmuxControlService.ParsedPane(x: 0, y: 0, width: 40, height: 24, paneId: 0),
            TmuxControlService.ParsedPane(x: 41, y: 0, width: 39, height: 24, paneId: 1),
        ]
        manager.simulateLayoutChange(windowId: "@0", panes: panes, isZoomed: false)
        XCTAssertTrue(manager.pendingAutoZoomForTesting)

        // Second unzoomed layout — should NOT send another command
        // (pendingAutoZoom is already true)
        manager.simulateLayoutChange(windowId: "@0", panes: panes, isZoomed: false)
        XCTAssertTrue(manager.pendingAutoZoomForTesting)
        // Still no layout processing
        XCTAssertEqual(manager.currentPanes.count, 0)
    }

    func testSameWindowPaneSwitchPreservesZoom() async throws {
        let manager = makeConnectedManager()
        manager.wireCallbacksForTesting()
        manager.mobileAutoZoom = true
        manager.setWindowsForTesting([
            .init(id: "@0", name: "bash", paneIds: ["%0", "%1"], isActive: true),
        ], activeId: "@0")
        manager.setStateForTesting(.attached(sessionName: "work"))
        manager.activePaneId = "%0"

        // Simulate zoomed state
        let zoomedPanes = [TmuxControlService.ParsedPane(x: 0, y: 0, width: 80, height: 24, paneId: 0)]
        manager.simulateLayoutChange(windowId: "@0", panes: zoomedPanes, isZoomed: true)
        XCTAssertTrue(manager.isZoomed)

        // Same-window pane switch uses select-pane -Z (no pendingAutoZoom needed)
        try await manager.selectWindowAndPane(windowId: "@0", paneId: "%1")

        // select-pane -Z preserves zoom — no pendingAutoZoom dance
        XCTAssertFalse(manager.pendingAutoZoomForTesting)
        XCTAssertEqual(manager.activePaneId, "%1")
    }

    func testSameWindowSamePaneSelectionIsNoop() async throws {
        let manager = makeConnectedManager()
        manager.wireCallbacksForTesting()
        manager.mobileAutoZoom = true
        manager.setWindowsForTesting([
            .init(id: "@0", name: "bash", paneIds: ["%0", "%1"], isActive: true),
        ], activeId: "@0")
        manager.setStateForTesting(.attached(sessionName: "work"))
        manager.activePaneId = "%0"

        // Simulate zoomed state
        let zoomedPanes = [TmuxControlService.ParsedPane(x: 0, y: 0, width: 80, height: 24, paneId: 0)]
        manager.simulateLayoutChange(windowId: "@0", panes: zoomedPanes, isZoomed: true)
        XCTAssertTrue(manager.isZoomed)

        // Tap the same active pane — should be a no-op
        try await manager.selectWindowAndPane(windowId: "@0", paneId: "%0")

        // pendingAutoZoom must NOT be set (no commands sent)
        XCTAssertFalse(manager.pendingAutoZoomForTesting)
        // Zoom state preserved
        XCTAssertTrue(manager.isZoomed)
        // Active pane unchanged
        XCTAssertEqual(manager.activePaneId, "%0")
    }

    func testMobileAutoZoomDisabledNoEffect() {
        let manager = makeManager()
        manager.wireCallbacksForTesting()
        manager.mobileAutoZoom = false  // disabled
        manager.setWindowsForTesting([
            .init(id: "@0", name: "bash", paneIds: ["%0", "%1"], isActive: true),
        ], activeId: "@0")
        manager.activePaneId = "%0"

        // Unzoomed multi-pane layout — should process normally
        let panes = [
            TmuxControlService.ParsedPane(x: 0, y: 0, width: 40, height: 24, paneId: 0),
            TmuxControlService.ParsedPane(x: 41, y: 0, width: 39, height: 24, paneId: 1),
        ]
        manager.simulateLayoutChange(windowId: "@0", panes: panes, isZoomed: false)

        // Normal processing happened
        XCTAssertEqual(manager.currentPanes.count, 2)
        XCTAssertFalse(manager.pendingAutoZoomForTesting)
    }

    func testDisconnectClearsPendingAutoZoom() {
        let manager = makeConnectedManager()
        manager.wireCallbacksForTesting()
        manager.mobileAutoZoom = true
        manager.setWindowsForTesting([
            .init(id: "@0", name: "bash", paneIds: ["%0", "%1"], isActive: true),
        ], activeId: "@0")
        manager.activePaneId = "%0"
        manager.setPaneBuffersForTesting(["%0": TerminalBuffer(cols: 80, rows: 24)])

        // Trigger auto-zoom to set pendingAutoZoom
        let panes = [
            TmuxControlService.ParsedPane(x: 0, y: 0, width: 40, height: 24, paneId: 0),
            TmuxControlService.ParsedPane(x: 41, y: 0, width: 39, height: 24, paneId: 1),
        ]
        manager.simulateLayoutChange(windowId: "@0", panes: panes, isZoomed: false)
        XCTAssertTrue(manager.pendingAutoZoomForTesting)

        manager.disconnect()
        XCTAssertFalse(manager.pendingAutoZoomForTesting)
    }

    // MARK: - Proactive Auto-Zoom (didSet) Tests

    func testProactiveAutoZoomOnMobileAutoZoomSet() {
        let manager = makeConnectedManager()
        manager.wireCallbacksForTesting()
        manager.setWindowsForTesting([
            .init(id: "@0", name: "bash", paneIds: ["%0", "%1"], isActive: true),
        ], activeId: "@0")
        manager.activePaneId = "%0"
        manager.setPaneBuffersForTesting(["%0": TerminalBuffer(cols: 80, rows: 24)])

        // Layout arrives before mobileAutoZoom is set (simulating the timing gap)
        let panes = [
            TmuxControlService.ParsedPane(x: 0, y: 0, width: 40, height: 24, paneId: 0),
            TmuxControlService.ParsedPane(x: 41, y: 0, width: 39, height: 24, paneId: 1),
        ]
        manager.simulateLayoutChange(windowId: "@0", panes: panes, isZoomed: false)
        XCTAssertFalse(manager.pendingAutoZoomForTesting, "Should not auto-zoom yet — mobileAutoZoom is false")

        // Now mobileAutoZoom is set (simulating onAppear)
        manager.mobileAutoZoom = true
        XCTAssertTrue(manager.pendingAutoZoomForTesting, "didSet should proactively trigger auto-zoom")
    }

    func testProactiveAutoZoomSkipsSinglePane() {
        let manager = makeConnectedManager()
        manager.wireCallbacksForTesting()
        manager.setWindowsForTesting([
            .init(id: "@0", name: "bash", paneIds: ["%0"], isActive: true),
        ], activeId: "@0")
        manager.activePaneId = "%0"

        // Single-pane layout
        let panes = [
            TmuxControlService.ParsedPane(x: 0, y: 0, width: 80, height: 24, paneId: 0),
        ]
        manager.simulateLayoutChange(windowId: "@0", panes: panes, isZoomed: false)

        manager.mobileAutoZoom = true
        XCTAssertFalse(manager.pendingAutoZoomForTesting, "Single pane — no auto-zoom needed")
    }

    func testProactiveAutoZoomSkipsEmptyPanes() {
        let manager = makeConnectedManager()
        manager.wireCallbacksForTesting()

        // No layout received yet — currentPanes is empty
        manager.mobileAutoZoom = true
        XCTAssertFalse(manager.pendingAutoZoomForTesting, "Empty panes — no auto-zoom needed")
    }

    // MARK: - Layout Change Transition Tests

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

    // MARK: - Pane ID Preservation Tests

    func testListWindowsResponsePreservesPaneIds() {
        let manager = makeManager()
        // Set up windows with known pane IDs
        manager.setWindowsForTesting([
            .init(id: "@0", name: "bash", paneIds: ["%0", "%1"], isActive: true),
            .init(id: "@1", name: "vim", paneIds: ["%2", "%3"], isActive: false),
        ], activeId: "@0")

        // Simulate list-windows refresh (e.g., after %window-add).
        // list-windows response doesn't include pane info.
        let response = "@0\t0\tbash\t1\n@1\t1\tvim\t0"
        manager.handleListWindowsResponse(response)

        // Non-active window must preserve its pane IDs
        XCTAssertEqual(manager.currentWindows[1].paneIds, ["%2", "%3"],
                       "list-windows must not drop non-active window pane IDs")
        // Active window also preserved (then overwritten by updateWindowPaneMapping)
        XCTAssertEqual(manager.currentWindows.count, 2)
    }

    func testListWindowsResponseDropsPaneIdsForRemovedWindow() {
        let manager = makeManager()
        manager.setWindowsForTesting([
            .init(id: "@0", name: "bash", paneIds: ["%0"], isActive: true),
            .init(id: "@1", name: "vim", paneIds: ["%1"], isActive: false),
            .init(id: "@2", name: "htop", paneIds: ["%2"], isActive: false),
        ], activeId: "@0")

        // @2 no longer in the list — its pane IDs should not carry over
        let response = "@0\t0\tbash\t1\n@1\t1\tvim\t0"
        manager.handleListWindowsResponse(response)

        XCTAssertEqual(manager.currentWindows.count, 2)
        XCTAssertEqual(manager.currentWindows[1].paneIds, ["%1"])
    }

    func testListWindowsResponseNewWindowHasEmptyPaneIds() {
        let manager = makeManager()
        manager.setWindowsForTesting([
            .init(id: "@0", name: "bash", paneIds: ["%0"], isActive: true),
        ], activeId: "@0")

        // @1 is new — no existing pane IDs to preserve
        let response = "@0\t0\tbash\t1\n@1\t1\tnew-win\t0"
        manager.handleListWindowsResponse(response)

        XCTAssertEqual(manager.currentWindows.count, 2)
        XCTAssertEqual(manager.currentWindows[0].paneIds, ["%0"])
        XCTAssertEqual(manager.currentWindows[1].paneIds, [],
                       "New windows should have empty pane IDs until list-panes arrives")
    }
}
