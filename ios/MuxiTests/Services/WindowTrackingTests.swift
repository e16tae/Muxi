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

        manager.handleWindowClose("@0")

        XCTAssertEqual(manager.currentWindows.count, 1)
        XCTAssertEqual(manager.currentWindows[0].id, "@1")
        XCTAssertEqual(manager.activeWindowId, "@1")
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
