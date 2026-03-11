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
        manager.currentWindows = [
            .init(id: "@0", name: "bash", paneIds: ["%0"], isActive: true),
            .init(id: "@1", name: "vim", paneIds: ["%1"], isActive: false),
        ]
        manager.activeWindowId = "@0"

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
}
