import XCTest

@testable import Muxi

@MainActor
final class TmuxControlServiceTests: XCTestCase {

    // MARK: - Session List Parsing

    func testParseSessionList() {
        let output = """
        main: 2 windows (created Fri Feb 28 10:00:00 2026)
        dev: 1 windows (created Fri Feb 28 11:00:00 2026)
        """
        let sessions = TmuxControlService.parseSessionList(output)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].name, "main")
        XCTAssertEqual(sessions[1].name, "dev")
    }

    func testParseSessionListFormatted() {
        let output = """
        $0:main:2:1740700800
        $1:dev:1:1740704400
        """
        let sessions = TmuxControlService.parseFormattedSessionList(output)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].id, "$0")
        XCTAssertEqual(sessions[0].name, "main")
        XCTAssertEqual(sessions[0].windows.count, 0)
    }

    func testParseSessionListEmpty() {
        let sessions = TmuxControlService.parseSessionList("")
        XCTAssertTrue(sessions.isEmpty)
    }

    func testParseFormattedSessionListEmpty() {
        let sessions = TmuxControlService.parseFormattedSessionList("")
        XCTAssertTrue(sessions.isEmpty)
    }

    // MARK: - Control Mode Line Handling

    func testHandleControlModeOutput() {
        let service = TmuxControlService()
        var receivedPaneId: String?
        var receivedData: String?

        service.onPaneOutput = { paneId, data in
            receivedPaneId = paneId
            receivedData = data
        }

        service.handleLine("%output %0 Hello\\n")

        XCTAssertEqual(receivedPaneId, "%0")
        XCTAssertNotNil(receivedData)
    }

    func testHandleLayoutChange() {
        let service = TmuxControlService()
        var receivedWindowId: String?
        var receivedPanes: [TmuxControlService.ParsedPane]?

        service.onLayoutChange = { windowId, panes in
            receivedWindowId = windowId
            receivedPanes = panes
        }

        service.handleLine("%layout-change @0 abcd,80x24,0,0{40x24,0,0,0,39x24,41,0,1}")

        XCTAssertEqual(receivedWindowId, "@0")
        XCTAssertNotNil(receivedPanes)
        if let panes = receivedPanes {
            XCTAssertEqual(panes.count, 2)
            XCTAssertEqual(panes[0].width, 40)
            XCTAssertEqual(panes[0].height, 24)
            XCTAssertEqual(panes[0].paneId, 0)
            XCTAssertEqual(panes[1].width, 39)
            XCTAssertEqual(panes[1].height, 24)
            XCTAssertEqual(panes[1].x, 41)
            XCTAssertEqual(panes[1].paneId, 1)
        }
    }

    func testHandleWindowAdd() {
        let service = TmuxControlService()
        var receivedWindowId: String?

        service.onWindowAdd = { windowId in
            receivedWindowId = windowId
        }

        service.handleLine("%window-add @1")

        XCTAssertEqual(receivedWindowId, "@1")
    }

    func testHandleWindowClose() {
        let service = TmuxControlService()
        var receivedWindowId: String?

        service.onWindowClose = { windowId in
            receivedWindowId = windowId
        }

        service.handleLine("%window-close @2")

        XCTAssertEqual(receivedWindowId, "@2")
    }

    func testHandleSessionChanged() {
        let service = TmuxControlService()
        var receivedId: String?
        var receivedName: String?

        service.onSessionChanged = { id, name in
            receivedId = id
            receivedName = name
        }

        service.handleLine("%session-changed $0 work")

        XCTAssertEqual(receivedId, "$0")
        XCTAssertEqual(receivedName, "work")
    }

    func testHandleExit() {
        let service = TmuxControlService()
        var exitCalled = false

        service.onExit = {
            exitCalled = true
        }

        service.handleLine("%exit")

        XCTAssertTrue(exitCalled)
    }

    func testHandleUnknownLine() {
        let service = TmuxControlService()
        var anyCalled = false

        service.onPaneOutput = { _, _ in anyCalled = true }
        service.onLayoutChange = { _, _ in anyCalled = true }
        service.onWindowAdd = { _ in anyCalled = true }
        service.onWindowClose = { _ in anyCalled = true }
        service.onSessionChanged = { _, _ in anyCalled = true }
        service.onExit = { anyCalled = true }

        service.handleLine("This is not a tmux message")

        XCTAssertFalse(anyCalled)
    }

    func testNoCallbackDoesNotCrash() {
        let service = TmuxControlService()
        // No callbacks set — should not crash
        service.handleLine("%output %0 data")
        service.handleLine("%layout-change @0 abcd,80x24,0,0,0")
        service.handleLine("%window-add @1")
        service.handleLine("%window-close @2")
        service.handleLine("%session-changed $0 name")
        service.handleLine("%exit")
    }
}
