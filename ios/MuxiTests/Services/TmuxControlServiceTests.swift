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
        XCTAssertEqual(sessions[0].id, SessionID("$0"))
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
        var receivedPaneId: PaneID?
        var receivedData: Data?

        service.onPaneOutput = { paneId, data in
            receivedPaneId = paneId
            receivedData = data
        }

        service.handleLine("%output %0 Hello\\n")

        XCTAssertEqual(receivedPaneId, PaneID("%0"))
        XCTAssertNotNil(receivedData)
    }

    func testHandleLayoutChange() {
        let service = TmuxControlService()
        var receivedWindowId: WindowID?
        var receivedPanes: [Pane]?
        var receivedIsZoomed: Bool?

        service.onLayoutChange = { windowId, panes, isZoomed in
            receivedWindowId = windowId
            receivedPanes = panes
            receivedIsZoomed = isZoomed
        }

        service.handleLine("%layout-change @0 abcd,80x24,0,0{40x24,0,0,0,39x24,41,0,1}")

        XCTAssertEqual(receivedWindowId, WindowID("@0"))
        XCTAssertEqual(receivedIsZoomed, false)
        XCTAssertNotNil(receivedPanes)
        if let panes = receivedPanes {
            XCTAssertEqual(panes.count, 2)
            XCTAssertEqual(panes[0].frame.width, 40)
            XCTAssertEqual(panes[0].frame.height, 24)
            XCTAssertEqual(panes[0].id, PaneID(index: 0))
            XCTAssertEqual(panes[1].frame.width, 39)
            XCTAssertEqual(panes[1].frame.height, 24)
            XCTAssertEqual(panes[1].frame.x, 41)
            XCTAssertEqual(panes[1].id, PaneID(index: 1))
        }
    }

    func testHandleLayoutChangeZoomed() {
        let service = TmuxControlService()
        var receivedPanes: [Pane]?
        var receivedIsZoomed: Bool?

        service.onLayoutChange = { _, panes, isZoomed in
            receivedPanes = panes
            receivedIsZoomed = isZoomed
        }

        // Zoomed: visible_layout is single pane, * flag present
        service.handleLine("%layout-change @0 abcd,80x24,0,0{40x24,0,0,0,39x24,41,0,1} ef01,80x24,0,0,0 *")

        XCTAssertEqual(receivedIsZoomed, true)
        XCTAssertNotNil(receivedPanes)
        // visible_layout is a single pane
        XCTAssertEqual(receivedPanes?.count, 1)
        XCTAssertEqual(receivedPanes?.first?.frame.width, 80)
        XCTAssertEqual(receivedPanes?.first?.frame.height, 24)
        XCTAssertEqual(receivedPanes?.first?.id, PaneID(index: 0))
    }

    func testHandleWindowAdd() {
        let service = TmuxControlService()
        var receivedWindowId: WindowID?

        service.onWindowAdd = { windowId in
            receivedWindowId = windowId
        }

        service.handleLine("%window-add @1")

        XCTAssertEqual(receivedWindowId, WindowID("@1"))
    }

    func testHandleWindowClose() {
        let service = TmuxControlService()
        var receivedWindowId: WindowID?

        service.onWindowClose = { windowId in
            receivedWindowId = windowId
        }

        service.handleLine("%window-close @2")

        XCTAssertEqual(receivedWindowId, WindowID("@2"))
    }

    func testHandleSessionChanged() {
        let service = TmuxControlService()
        var receivedId: SessionID?
        var receivedName: String?

        service.onSessionChanged = { id, name in
            receivedId = id
            receivedName = name
        }

        service.handleLine("%session-changed $0 work")

        XCTAssertEqual(receivedId, SessionID("$0"))
        XCTAssertEqual(receivedName, "work")
    }

    func testHandleSessionsChanged() {
        let service = TmuxControlService()
        var called = false

        service.onSessionsChanged = {
            called = true
        }

        service.handleLine("%sessions-changed")

        XCTAssertTrue(called)
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

    func testHandleWindowRenamed() {
        let service = TmuxControlService()
        var receivedWindowId: WindowID?
        var receivedName: String?

        service.onWindowRenamed = { windowId, name in
            receivedWindowId = windowId
            receivedName = name
        }

        service.handleLine("%window-renamed @0 vim")

        XCTAssertEqual(receivedWindowId, WindowID("@0"))
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
        var receivedWindowId: WindowID?

        service.onWindowClose = { windowId in
            receivedWindowId = windowId
        }

        service.handleLine("%unlinked-window-close @3")

        XCTAssertEqual(receivedWindowId, WindowID("@3"))
    }

    func testHandleUnknownLine() {
        let service = TmuxControlService()
        var anyCalled = false

        service.onPaneOutput = { _, _ in anyCalled = true }
        service.onLayoutChange = { _, _, _ in anyCalled = true }
        service.onWindowAdd = { _ in anyCalled = true }
        service.onWindowClose = { _ in anyCalled = true }
        service.onWindowRenamed = { _, _ in anyCalled = true }
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
        service.handleLine("%window-renamed @0 vim")
        service.handleLine("%unlinked-window-close @3")
        service.handleLine("%session-changed $0 name")
        service.handleLine("%exit")
    }

    // MARK: - Line Accumulator (feed)

    /// DCS prefix that puts the service into control mode.
    /// feed() skips all lines until it sees this prefix, matching real
    /// tmux behavior where shell output precedes control mode.
    private static let dcsPrefix = Data("\u{1B}P1000p\n".utf8)

    /// Feed the DCS prefix to enter control mode before sending test data.
    private func enterControlMode(_ service: TmuxControlService) {
        service.feed(Self.dcsPrefix)
    }

    func testFeedCompleteLine() {
        let service = TmuxControlService()
        var exitCalled = false

        service.onExit = {
            exitCalled = true
        }

        enterControlMode(service)
        let data = Data("%exit\n".utf8)
        service.feed(data)

        XCTAssertTrue(exitCalled)
    }

    func testFeedPartialThenComplete() {
        let service = TmuxControlService()
        var receivedWindowId: WindowID?

        service.onWindowAdd = { windowId in
            receivedWindowId = windowId
        }

        enterControlMode(service)

        // Feed partial data first
        service.feed(Data("%window".utf8))
        XCTAssertNil(receivedWindowId, "Should not dispatch before newline")

        // Complete the line
        service.feed(Data("-add @5\n".utf8))
        XCTAssertEqual(receivedWindowId, WindowID("@5"))
    }

    func testFeedMultipleLines() {
        let service = TmuxControlService()
        var windowAddIds: [WindowID] = []

        service.onWindowAdd = { windowId in
            windowAddIds.append(windowId)
        }

        enterControlMode(service)
        let data = Data("%window-add @1\n%window-add @2\n".utf8)
        service.feed(data)

        XCTAssertEqual(windowAddIds.count, 2)
        XCTAssertEqual(windowAddIds[0], WindowID("@1"))
        XCTAssertEqual(windowAddIds[1], WindowID("@2"))
    }

    func testFeedChunkedData() {
        let service = TmuxControlService()
        var exitCalled = false

        service.onExit = {
            exitCalled = true
        }

        enterControlMode(service)

        // Feed byte-by-byte
        let fullLine = "%exit\n"
        for byte in fullLine.utf8 {
            service.feed(Data([byte]))
        }

        XCTAssertTrue(exitCalled)
    }

    func testResetLineBuffer() {
        let service = TmuxControlService()
        var receivedWindowId: WindowID?

        service.onWindowAdd = { windowId in
            receivedWindowId = windowId
        }

        enterControlMode(service)

        // Feed partial data
        service.feed(Data("%window-add @".utf8))
        XCTAssertNil(receivedWindowId)

        // Reset clears the buffer (also resets inControlMode)
        service.resetLineBuffer()

        // Re-enter control mode after reset
        enterControlMode(service)

        // Feed a fresh complete line — old partial data is gone
        service.feed(Data("%window-add @9\n".utf8))
        XCTAssertEqual(receivedWindowId, WindowID("@9"))
    }

    func testFeedWithCarriageReturn() {
        let service = TmuxControlService()
        var exitCalled = false
        service.onExit = { exitCalled = true }

        enterControlMode(service)

        // PTY-style CRLF: \r should be stripped, leaving "%exit" which parses correctly
        let data = "%exit\r\n".data(using: .utf8)!
        service.feed(data)

        XCTAssertTrue(exitCalled, "\\r should be stripped so %exit parses correctly")
    }

    // MARK: - Notification Inside Response Block

    func testNotificationInsideResponseBlock() {
        let service = TmuxControlService()
        var sessionChangedId: SessionID?
        var sessionChangedName: String?
        var commandResponse: String?

        service.onSessionChanged = { id, name in
            sessionChangedId = id
            sessionChangedName = name
        }
        service.onCommandResponse = { response in
            commandResponse = response
        }

        enterControlMode(service)

        // Simulate: list-sessions command response with interleaved notification
        // tmux interleaves %session-changed inside %begin...%end blocks
        service.feed(Data("%begin 1234567890 1 0\n".utf8))
        service.feed(Data("$0:main:2:1740700800\n".utf8))
        service.feed(Data("%session-changed $1 beta\n".utf8))
        service.feed(Data("$1:beta:1:1740704400\n".utf8))
        service.feed(Data("%end 1234567890 1 0\n".utf8))

        // Notification must be dispatched, not swallowed
        XCTAssertEqual(sessionChangedId, SessionID("$1"))
        XCTAssertEqual(sessionChangedName, "beta")

        // Response should contain only data lines, not the notification
        XCTAssertNotNil(commandResponse)
        XCTAssertEqual(commandResponse, "$0:main:2:1740700800\n$1:beta:1:1740704400")
    }

    func testErrorResponseConsumesCommandResponse() {
        let service = TmuxControlService()
        var responses: [String] = []
        var errorMessages: [String] = []

        service.onCommandResponse = { response in
            responses.append(response)
        }
        service.onError = { message in
            errorMessages.append(message)
        }

        enterControlMode(service)

        // First command gets a %error response
        service.feed(Data("%begin 1234567890 1 0\n".utf8))
        service.feed(Data("%error bad command\n".utf8))

        // %error must still trigger onCommandResponse so the pending
        // command entry is consumed (otherwise the FIFO queue drifts).
        XCTAssertEqual(responses.count, 1, "%error must trigger onCommandResponse")
        XCTAssertEqual(responses[0], "", "Response should be empty (data was before %error)")
        XCTAssertEqual(errorMessages.count, 1)

        // Second command succeeds normally
        service.feed(Data("%begin 1234567890 2 0\n".utf8))
        service.feed(Data("OK\n".utf8))
        service.feed(Data("%end 1234567890 2 0\n".utf8))

        XCTAssertEqual(responses.count, 2, "Second response must also arrive")
        XCTAssertEqual(responses[1], "OK")
    }

    // MARK: - Octal Decode

    func testDecodeTmuxOutputPlainText() {
        let result = TmuxControlService.decodeTmuxOutput("Hello world")
        XCTAssertEqual(result, Data("Hello world".utf8))
    }

    func testDecodeTmuxOutputEscapeSequence() {
        // \033 = ESC (0x1B), \012 = newline (0x0A)
        let result = TmuxControlService.decodeTmuxOutput("\\033[31mRed\\012")
        XCTAssertEqual(result[0], 0x1B) // ESC
        XCTAssertEqual(result[4], 0x6D) // 'm'
        XCTAssertEqual(result[result.count - 1], 0x0A) // newline
    }

    func testDecodeTmuxOutputBackslash() {
        // \134 = backslash (0x5C)
        let result = TmuxControlService.decodeTmuxOutput("path\\134file")
        XCTAssertEqual(String(data: result, encoding: .utf8), "path\\file")
    }

    func testDecodeTmuxOutputEmptyString() {
        let result = TmuxControlService.decodeTmuxOutput("")
        XCTAssertTrue(result.isEmpty)
    }

    func testDecodeTmuxOutputTrailingBackslash() {
        // Backslash at end without 3 octal digits — should be literal
        let result = TmuxControlService.decodeTmuxOutput("end\\")
        XCTAssertEqual(result, Data("end\\".utf8))
    }

    // MARK: - Large Chunk Regression

    func testFeedLargeChunkAllLinesDelivered() {
        let service = TmuxControlService()
        var addedWindows: [WindowID] = []
        service.onWindowAdd = { windowId in
            addedWindows.append(windowId)
        }

        enterControlMode(service)

        // Build a 50-line payload
        var payload = ""
        for i in 0..<50 {
            payload += "%window-add @\(i)\n"
        }
        service.feed(Data(payload.utf8))

        XCTAssertEqual(addedWindows.count, 50)
        XCTAssertEqual(addedWindows.first, WindowID("@0"))
        XCTAssertEqual(addedWindows.last, WindowID("@49"))
    }
}
