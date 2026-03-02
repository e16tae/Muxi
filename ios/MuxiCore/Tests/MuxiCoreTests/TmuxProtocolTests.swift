import Testing
import CTmuxProtocol

/// Helper to extract a Swift String from a C fixed-size char array.
/// Takes a pointer to the first element of the tuple.
private func string(from ptr: UnsafePointer<CChar>) -> String {
    return String(cString: ptr)
}

// MARK: - Message Parsing Tests

@Test func testParseOutputMessage() {
    let line = "%output %0 Hello world\\n"
    // Keep the C string alive while we inspect pointer fields.
    line.withCString { cLine in
        var msg = TmuxMessage()
        let msgType = tmux_parse_line(cLine, &msg)

        #expect(msgType == TMUX_MSG_OUTPUT)
        let paneId = withUnsafePointer(to: &msg.pane_id.0) { string(from: $0) }
        #expect(paneId == "%0")
        #expect(msg.output_data != nil)
        if let data = msg.output_data {
            let output = String(cString: data)
            #expect(output == "Hello world\\n")
        }
        #expect(msg.output_len == 13)
    }
}

@Test func testParseLayoutChange() {
    let line = "%layout-change @0 abcd,80x24,0,0{40x24,0,0,0,39x24,41,0,1}"
    line.withCString { cLine in
        var msg = TmuxMessage()
        let msgType = tmux_parse_line(cLine, &msg)

        #expect(msgType == TMUX_MSG_LAYOUT_CHANGE)
        let windowId = withUnsafePointer(to: &msg.window_id.0) { string(from: $0) }
        #expect(windowId == "@0")
        #expect(msg.layout != nil)
        if let layout = msg.layout {
            let layoutStr = String(cString: layout)
            #expect(layoutStr == "abcd,80x24,0,0{40x24,0,0,0,39x24,41,0,1}")
        }
    }
}

@Test func testParseWindowAdd() {
    let line = "%window-add @1"
    line.withCString { cLine in
        var msg = TmuxMessage()
        let msgType = tmux_parse_line(cLine, &msg)

        #expect(msgType == TMUX_MSG_WINDOW_ADD)
        let windowId = withUnsafePointer(to: &msg.window_id.0) { string(from: $0) }
        #expect(windowId == "@1")
    }
}

@Test func testParseWindowClose() {
    let line = "%window-close @2"
    line.withCString { cLine in
        var msg = TmuxMessage()
        let msgType = tmux_parse_line(cLine, &msg)

        #expect(msgType == TMUX_MSG_WINDOW_CLOSE)
        let windowId = withUnsafePointer(to: &msg.window_id.0) { string(from: $0) }
        #expect(windowId == "@2")
    }
}

@Test func testParseSessionChanged() {
    let line = "%session-changed $0 my-session"
    line.withCString { cLine in
        var msg = TmuxMessage()
        let msgType = tmux_parse_line(cLine, &msg)

        #expect(msgType == TMUX_MSG_SESSION_CHANGED)
        let sessionId = withUnsafePointer(to: &msg.session_id.0) { string(from: $0) }
        #expect(sessionId == "$0")
        let sessionName = withUnsafePointer(to: &msg.session_name.0) { string(from: $0) }
        #expect(sessionName == "my-session")
    }
}

@Test func testParseBegin() {
    let line = "%begin 1234567890 1 0"
    line.withCString { cLine in
        var msg = TmuxMessage()
        let msgType = tmux_parse_line(cLine, &msg)

        #expect(msgType == TMUX_MSG_BEGIN)
        #expect(msg.timestamp == 1234567890)
        #expect(msg.command_number == 1)
        #expect(msg.flags == 0)
    }
}

@Test func testParseEnd() {
    let line = "%end 1234567890 1 0"
    line.withCString { cLine in
        var msg = TmuxMessage()
        let msgType = tmux_parse_line(cLine, &msg)

        #expect(msgType == TMUX_MSG_END)
        #expect(msg.timestamp == 1234567890)
        #expect(msg.command_number == 1)
        #expect(msg.flags == 0)
    }
}

@Test func testParseExit() {
    let line = "%exit"
    line.withCString { cLine in
        var msg = TmuxMessage()
        let msgType = tmux_parse_line(cLine, &msg)

        #expect(msgType == TMUX_MSG_EXIT)
        #expect(msg.exit_reason == nil)
    }
}

@Test func testParseUnknownLine() {
    let line = "This is not a tmux message"
    line.withCString { cLine in
        var msg = TmuxMessage()
        let msgType = tmux_parse_line(cLine, &msg)

        #expect(msgType == TMUX_MSG_UNKNOWN)
    }
}

@Test func testParseEmptyLine() {
    let line = ""
    line.withCString { cLine in
        var msg = TmuxMessage()
        let msgType = tmux_parse_line(cLine, &msg)

        #expect(msgType == TMUX_MSG_UNKNOWN)
    }
}

// MARK: - Layout Parsing Tests

@Test func testParseLayoutString() {
    // Vertical split: two panes side by side
    let layout = "abcd,80x24,0,0{40x24,0,0,0,39x24,41,0,1}"
    var panes = [TmuxLayoutPane](repeating: TmuxLayoutPane(), count: 16)
    var count: Int32 = 0

    let result = tmux_parse_layout(layout, &panes, 16, &count)

    #expect(result == 0)
    #expect(count == 2)

    // First pane: 40x24 at (0,0), pane_id=0
    #expect(panes[0].width == 40)
    #expect(panes[0].height == 24)
    #expect(panes[0].x == 0)
    #expect(panes[0].y == 0)
    #expect(panes[0].pane_id == 0)

    // Second pane: 39x24 at (41,0), pane_id=1
    #expect(panes[1].width == 39)
    #expect(panes[1].height == 24)
    #expect(panes[1].x == 41)
    #expect(panes[1].y == 0)
    #expect(panes[1].pane_id == 1)
}

@Test func testParseLayoutHorizontalSplit() {
    // Horizontal split: two panes stacked vertically
    let layout = "1234,80x24,0,0[80x12,0,0,0,80x11,0,13,1]"
    var panes = [TmuxLayoutPane](repeating: TmuxLayoutPane(), count: 16)
    var count: Int32 = 0

    let result = tmux_parse_layout(layout, &panes, 16, &count)

    #expect(result == 0)
    #expect(count == 2)

    // Top pane: 80x12 at (0,0), pane_id=0
    #expect(panes[0].width == 80)
    #expect(panes[0].height == 12)
    #expect(panes[0].x == 0)
    #expect(panes[0].y == 0)
    #expect(panes[0].pane_id == 0)

    // Bottom pane: 80x11 at (0,13), pane_id=1
    #expect(panes[1].width == 80)
    #expect(panes[1].height == 11)
    #expect(panes[1].x == 0)
    #expect(panes[1].y == 13)
    #expect(panes[1].pane_id == 1)
}

@Test func testParseLayoutSinglePane() {
    // Single pane: no brackets, just dimensions + pane_id
    let layout = "a0b1,80x24,0,0,0"
    var panes = [TmuxLayoutPane](repeating: TmuxLayoutPane(), count: 16)
    var count: Int32 = 0

    let result = tmux_parse_layout(layout, &panes, 16, &count)

    #expect(result == 0)
    #expect(count == 1)

    #expect(panes[0].width == 80)
    #expect(panes[0].height == 24)
    #expect(panes[0].x == 0)
    #expect(panes[0].y == 0)
    #expect(panes[0].pane_id == 0)
}

// MARK: - Additional Edge Case Tests

@Test func testParseExitWithReason() {
    let line = "%exit server exited"
    line.withCString { cLine in
        var msg = TmuxMessage()
        let msgType = tmux_parse_line(cLine, &msg)

        #expect(msgType == TMUX_MSG_EXIT)
        #expect(msg.exit_reason != nil)
        if let reason = msg.exit_reason {
            let reasonStr = String(cString: reason)
            #expect(reasonStr == "server exited")
        }
    }
}

@Test func testParseErrorMessage() {
    let line = "%error something went wrong"
    line.withCString { cLine in
        var msg = TmuxMessage()
        let msgType = tmux_parse_line(cLine, &msg)

        #expect(msgType == TMUX_MSG_ERROR)
        #expect(msg.error_message != nil)
        if let errMsg = msg.error_message {
            let errStr = String(cString: errMsg)
            #expect(errStr == "something went wrong")
        }
    }
}

@Test func testParseLayoutNestedSplits() {
    // Nested: vertical split containing a horizontal split
    let layout = "ffff,80x24,0,0{40x24,0,0,0,39x24,41,0[39x12,41,0,1,39x11,41,13,2]}"
    var panes = [TmuxLayoutPane](repeating: TmuxLayoutPane(), count: 16)
    var count: Int32 = 0

    let result = tmux_parse_layout(layout, &panes, 16, &count)

    #expect(result == 0)
    #expect(count == 3)

    // Left pane
    #expect(panes[0].width == 40)
    #expect(panes[0].height == 24)
    #expect(panes[0].x == 0)
    #expect(panes[0].y == 0)
    #expect(panes[0].pane_id == 0)

    // Top-right pane
    #expect(panes[1].width == 39)
    #expect(panes[1].height == 12)
    #expect(panes[1].x == 41)
    #expect(panes[1].y == 0)
    #expect(panes[1].pane_id == 1)

    // Bottom-right pane
    #expect(panes[2].width == 39)
    #expect(panes[2].height == 11)
    #expect(panes[2].x == 41)
    #expect(panes[2].y == 13)
    #expect(panes[2].pane_id == 2)
}

@Test func testParseLayoutInvalidString() {
    let layout = "not-a-layout"
    var panes = [TmuxLayoutPane](repeating: TmuxLayoutPane(), count: 16)
    var count: Int32 = 0

    let result = tmux_parse_layout(layout, &panes, 16, &count)

    #expect(result == -1)
}

@Test func testParseSessionChangedWithSpacesInName() {
    let line = "%session-changed $5 my long session name"
    line.withCString { cLine in
        var msg = TmuxMessage()
        let msgType = tmux_parse_line(cLine, &msg)

        #expect(msgType == TMUX_MSG_SESSION_CHANGED)
        let sessionId = withUnsafePointer(to: &msg.session_id.0) { string(from: $0) }
        #expect(sessionId == "$5")
        let sessionName = withUnsafePointer(to: &msg.session_name.0) { string(from: $0) }
        #expect(sessionName == "my long session name")
    }
}

@Test func testParseNullLine() {
    var msg = TmuxMessage()
    let msgType = tmux_parse_line(nil, &msg)

    #expect(msgType == TMUX_MSG_UNKNOWN)
}
