import Testing
import CVTParser

// MARK: - Basic Text Tests

@Test func testPlainText() {
    var parser = VTParserState()
    vt_parser_init(&parser, 80, 24)
    defer { vt_parser_destroy(&parser) }

    let text = "Hello, World!"
    vt_parser_feed(&parser, text, Int32(text.utf8.count))

    var buf = [CChar](repeating: 0, count: 256)
    let written = vt_parser_get_line(&parser, 0, &buf, 256)
    let line = String(cString: buf)

    #expect(written == 13)
    #expect(line == "Hello, World!")
}

@Test func testNewline() {
    var parser = VTParserState()
    vt_parser_init(&parser, 80, 24)
    defer { vt_parser_destroy(&parser) }

    let text = "Line1\r\nLine2"
    vt_parser_feed(&parser, text, Int32(text.utf8.count))

    var buf0 = [CChar](repeating: 0, count: 256)
    vt_parser_get_line(&parser, 0, &buf0, 256)
    let line0 = String(cString: buf0)

    var buf1 = [CChar](repeating: 0, count: 256)
    vt_parser_get_line(&parser, 1, &buf1, 256)
    let line1 = String(cString: buf1)

    #expect(line0 == "Line1")
    #expect(line1 == "Line2")
}

// MARK: - Cursor Movement Tests

@Test func testCursorMovement() {
    var parser = VTParserState()
    vt_parser_init(&parser, 80, 24)
    defer { vt_parser_destroy(&parser) }

    // ESC[2;5H positions cursor at row 2, col 5 (1-based)
    // Then write 'X'
    let text = "\u{1B}[2;5HX"
    vt_parser_feed(&parser, text, Int32(text.utf8.count))

    // After writing 'X', cursor should be at row 1 (0-based), col 5 (0-based, after advancing)
    var cell = VTCell()
    vt_parser_get_cell(&parser, 1, 4, &cell)
    #expect(cell.character == UInt32(Character("X").asciiValue!))
}

@Test func testCursorUp() {
    var parser = VTParserState()
    vt_parser_init(&parser, 80, 24)
    defer { vt_parser_destroy(&parser) }

    // Move to row 5, then cursor up 3
    let text = "\u{1B}[6;1H\u{1B}[3AA"
    vt_parser_feed(&parser, text, Int32(text.utf8.count))

    // Should be at row 2 (6-1=5 -> 5-3=2), col 0
    var cell = VTCell()
    vt_parser_get_cell(&parser, 2, 0, &cell)
    #expect(cell.character == UInt32(Character("A").asciiValue!))
}

@Test func testCursorDown() {
    var parser = VTParserState()
    vt_parser_init(&parser, 80, 24)
    defer { vt_parser_destroy(&parser) }

    // Cursor down 3, then write B
    let text = "\u{1B}[3BB"
    vt_parser_feed(&parser, text, Int32(text.utf8.count))

    var cell = VTCell()
    vt_parser_get_cell(&parser, 3, 0, &cell)
    #expect(cell.character == UInt32(Character("B").asciiValue!))
}

@Test func testCursorForwardBack() {
    var parser = VTParserState()
    vt_parser_init(&parser, 80, 24)
    defer { vt_parser_destroy(&parser) }

    // Move forward 10, then back 5, then write C
    let text = "\u{1B}[10C\u{1B}[5DC"
    vt_parser_feed(&parser, text, Int32(text.utf8.count))

    var cell = VTCell()
    vt_parser_get_cell(&parser, 0, 5, &cell)
    #expect(cell.character == UInt32(Character("C").asciiValue!))
}

// MARK: - SGR Color Tests

@Test func testColorSGR() {
    var parser = VTParserState()
    vt_parser_init(&parser, 80, 24)
    defer { vt_parser_destroy(&parser) }

    // ESC[31m sets foreground to red (ANSI color 1), then write 'R'
    let text = "\u{1B}[31mR"
    vt_parser_feed(&parser, text, Int32(text.utf8.count))

    var cell = VTCell()
    vt_parser_get_cell(&parser, 0, 0, &cell)
    #expect(cell.character == UInt32(Character("R").asciiValue!))
    #expect(cell.fg_color == 1)
    #expect(cell.fg_is_rgb == 0)
}

@Test func testBackgroundColor() {
    var parser = VTParserState()
    vt_parser_init(&parser, 80, 24)
    defer { vt_parser_destroy(&parser) }

    // ESC[42m sets background to green (ANSI color 2)
    let text = "\u{1B}[42mG"
    vt_parser_feed(&parser, text, Int32(text.utf8.count))

    var cell = VTCell()
    vt_parser_get_cell(&parser, 0, 0, &cell)
    #expect(cell.bg_color == 2)
    #expect(cell.bg_is_rgb == 0)
}

@Test func testTrueColor() {
    var parser = VTParserState()
    vt_parser_init(&parser, 80, 24)
    defer { vt_parser_destroy(&parser) }

    // ESC[38;2;255;128;0m sets true color foreground (orange)
    let text = "\u{1B}[38;2;255;128;0mX"
    vt_parser_feed(&parser, text, Int32(text.utf8.count))

    var cell = VTCell()
    vt_parser_get_cell(&parser, 0, 0, &cell)
    #expect(cell.character == UInt32(Character("X").asciiValue!))
    #expect(cell.fg_is_rgb == 1)
    #expect(cell.fg_r == 255)
    #expect(cell.fg_g == 128)
    #expect(cell.fg_b == 0)
}

@Test func testTrueColorBackground() {
    var parser = VTParserState()
    vt_parser_init(&parser, 80, 24)
    defer { vt_parser_destroy(&parser) }

    // ESC[48;2;10;20;30m sets true color background
    let text = "\u{1B}[48;2;10;20;30mY"
    vt_parser_feed(&parser, text, Int32(text.utf8.count))

    var cell = VTCell()
    vt_parser_get_cell(&parser, 0, 0, &cell)
    #expect(cell.bg_is_rgb == 1)
    #expect(cell.bg_r == 10)
    #expect(cell.bg_g == 20)
    #expect(cell.bg_b == 30)
}

@Test func test256Color() {
    var parser = VTParserState()
    vt_parser_init(&parser, 80, 24)
    defer { vt_parser_destroy(&parser) }

    // ESC[38;5;196m sets 256-color foreground
    let text = "\u{1B}[38;5;196mZ"
    vt_parser_feed(&parser, text, Int32(text.utf8.count))

    var cell = VTCell()
    vt_parser_get_cell(&parser, 0, 0, &cell)
    #expect(cell.fg_color == 196)
    #expect(cell.fg_is_rgb == 0)
}

// MARK: - Attribute Tests

@Test func testBoldAttribute() {
    var parser = VTParserState()
    vt_parser_init(&parser, 80, 24)
    defer { vt_parser_destroy(&parser) }

    let text = "\u{1B}[1mB"
    vt_parser_feed(&parser, text, Int32(text.utf8.count))

    var cell = VTCell()
    vt_parser_get_cell(&parser, 0, 0, &cell)
    #expect(cell.attrs & 1 != 0) // bold bit set
}

@Test func testItalicAttribute() {
    var parser = VTParserState()
    vt_parser_init(&parser, 80, 24)
    defer { vt_parser_destroy(&parser) }

    let text = "\u{1B}[3mI"
    vt_parser_feed(&parser, text, Int32(text.utf8.count))

    var cell = VTCell()
    vt_parser_get_cell(&parser, 0, 0, &cell)
    #expect(cell.attrs & 4 != 0) // italic bit set
}

@Test func testUnderlineAttribute() {
    var parser = VTParserState()
    vt_parser_init(&parser, 80, 24)
    defer { vt_parser_destroy(&parser) }

    let text = "\u{1B}[4mU"
    vt_parser_feed(&parser, text, Int32(text.utf8.count))

    var cell = VTCell()
    vt_parser_get_cell(&parser, 0, 0, &cell)
    #expect(cell.attrs & 2 != 0) // underline bit set
}

@Test func testSGRReset() {
    var parser = VTParserState()
    vt_parser_init(&parser, 80, 24)
    defer { vt_parser_destroy(&parser) }

    // Set bold + red, then reset, then write
    let text = "\u{1B}[1;31mR\u{1B}[0mN"
    vt_parser_feed(&parser, text, Int32(text.utf8.count))

    // First cell should be bold+red
    var cell0 = VTCell()
    vt_parser_get_cell(&parser, 0, 0, &cell0)
    #expect(cell0.attrs & 1 != 0) // bold
    #expect(cell0.fg_color == 1)  // red

    // Second cell should be reset
    var cell1 = VTCell()
    vt_parser_get_cell(&parser, 0, 1, &cell1)
    #expect(cell1.attrs == 0)
    #expect(cell1.fg_color == 0)
}

// MARK: - Erase Tests

@Test func testEraseDisplay() {
    var parser = VTParserState()
    vt_parser_init(&parser, 80, 24)
    defer { vt_parser_destroy(&parser) }

    // Write AAAA, then erase entire display
    let text = "AAAA\u{1B}[2J"
    vt_parser_feed(&parser, text, Int32(text.utf8.count))

    var cell = VTCell()
    vt_parser_get_cell(&parser, 0, 0, &cell)
    #expect(cell.character == 0)

    vt_parser_get_cell(&parser, 0, 1, &cell)
    #expect(cell.character == 0)
}

@Test func testEraseInLine() {
    var parser = VTParserState()
    vt_parser_init(&parser, 80, 24)
    defer { vt_parser_destroy(&parser) }

    // Write ABCDEF, go back to col 3, erase to end of line
    let text = "ABCDEF\u{1B}[1;4H\u{1B}[0K"
    vt_parser_feed(&parser, text, Int32(text.utf8.count))

    // Columns 0-2 should still have A, B, C
    var cellA = VTCell()
    vt_parser_get_cell(&parser, 0, 0, &cellA)
    #expect(cellA.character == UInt32(Character("A").asciiValue!))

    var cellC = VTCell()
    vt_parser_get_cell(&parser, 0, 2, &cellC)
    #expect(cellC.character == UInt32(Character("C").asciiValue!))

    // Column 3 should be erased (cursor was at col 3)
    var cellD = VTCell()
    vt_parser_get_cell(&parser, 0, 3, &cellD)
    #expect(cellD.character == 0)
}

// MARK: - Resize Tests

@Test func testResize() {
    var parser = VTParserState()
    vt_parser_init(&parser, 80, 24)
    defer { vt_parser_destroy(&parser) }

    // Write some text
    let text = "Hello"
    vt_parser_feed(&parser, text, Int32(text.utf8.count))

    // Resize
    vt_parser_resize(&parser, 120, 40)

    #expect(parser.cols == 120)
    #expect(parser.rows == 40)

    // Old content should be preserved
    var buf = [CChar](repeating: 0, count: 256)
    vt_parser_get_line(&parser, 0, &buf, 256)
    let line = String(cString: buf)
    #expect(line == "Hello")
}

@Test func testResizeShrink() {
    var parser = VTParserState()
    vt_parser_init(&parser, 80, 24)
    defer { vt_parser_destroy(&parser) }

    // Put cursor at col 79
    let text = "\u{1B}[1;80HX"
    vt_parser_feed(&parser, text, Int32(text.utf8.count))

    // Shrink to 40 cols — cursor should be clamped
    vt_parser_resize(&parser, 40, 12)
    #expect(parser.cols == 40)
    #expect(parser.rows == 12)
    #expect(parser.cursor_col < 40)
    #expect(parser.cursor_row < 12)
}

// MARK: - Scroll Region Tests

@Test func testScrollRegion() {
    var parser = VTParserState()
    vt_parser_init(&parser, 80, 24)
    defer { vt_parser_destroy(&parser) }

    // Set scroll region to rows 1-5 (1-based)
    let setupText = "\u{1B}[1;5r"
    vt_parser_feed(&parser, setupText, Int32(setupText.utf8.count))

    #expect(parser.scroll_top == 0)
    #expect(parser.scroll_bottom == 4)
}

// MARK: - UTF-8 Tests

@Test func testUTF8TwoByte() {
    var parser = VTParserState()
    vt_parser_init(&parser, 80, 24)
    defer { vt_parser_destroy(&parser) }

    // e with acute accent: U+00E9 = 0xC3 0xA9
    let text = "\u{00E9}"
    vt_parser_feed(&parser, text, Int32(text.utf8.count))

    var cell = VTCell()
    vt_parser_get_cell(&parser, 0, 0, &cell)
    #expect(cell.character == 0x00E9)
}

@Test func testUTF8ThreeByte() {
    var parser = VTParserState()
    vt_parser_init(&parser, 80, 24)
    defer { vt_parser_destroy(&parser) }

    // Euro sign: U+20AC
    let text = "\u{20AC}"
    vt_parser_feed(&parser, text, Int32(text.utf8.count))

    var cell = VTCell()
    vt_parser_get_cell(&parser, 0, 0, &cell)
    #expect(cell.character == 0x20AC)
}

@Test func testUTF8FourByte() {
    var parser = VTParserState()
    vt_parser_init(&parser, 80, 24)
    defer { vt_parser_destroy(&parser) }

    // Emoji: U+1F600
    let text = "\u{1F600}"
    vt_parser_feed(&parser, text, Int32(text.utf8.count))

    var cell = VTCell()
    vt_parser_get_cell(&parser, 0, 0, &cell)
    #expect(cell.character == 0x1F600)
}

// MARK: - Tab and Backspace Tests

@Test func testTab() {
    var parser = VTParserState()
    vt_parser_init(&parser, 80, 24)
    defer { vt_parser_destroy(&parser) }

    let text = "AB\tC"
    vt_parser_feed(&parser, text, Int32(text.utf8.count))

    // After "AB" cursor is at col 2, tab moves to col 8
    var cell = VTCell()
    vt_parser_get_cell(&parser, 0, 8, &cell)
    #expect(cell.character == UInt32(Character("C").asciiValue!))
}

@Test func testBackspace() {
    var parser = VTParserState()
    vt_parser_init(&parser, 80, 24)
    defer { vt_parser_destroy(&parser) }

    // Write AB, backspace, write C — should overwrite B
    let text = "AB\u{08}C"
    vt_parser_feed(&parser, text, Int32(text.utf8.count))

    var cellA = VTCell()
    vt_parser_get_cell(&parser, 0, 0, &cellA)
    #expect(cellA.character == UInt32(Character("A").asciiValue!))

    var cellC = VTCell()
    vt_parser_get_cell(&parser, 0, 1, &cellC)
    #expect(cellC.character == UInt32(Character("C").asciiValue!))
}

// MARK: - OSC Test

@Test func testOSCSkipped() {
    var parser = VTParserState()
    vt_parser_init(&parser, 80, 24)
    defer { vt_parser_destroy(&parser) }

    // OSC to set window title, terminated by BEL
    let text = "\u{1B}]0;My Title\u{07}Hello"
    vt_parser_feed(&parser, text, Int32(text.utf8.count))

    var buf = [CChar](repeating: 0, count: 256)
    vt_parser_get_line(&parser, 0, &buf, 256)
    let line = String(cString: buf)
    #expect(line == "Hello")
}

// MARK: - Line Wrapping Test

@Test func testLineWrap() {
    var parser = VTParserState()
    vt_parser_init(&parser, 10, 24)
    defer { vt_parser_destroy(&parser) }

    // Write 12 characters in a 10-col terminal — should wrap
    let text = "ABCDEFGHIJKL"
    vt_parser_feed(&parser, text, Int32(text.utf8.count))

    var buf0 = [CChar](repeating: 0, count: 256)
    vt_parser_get_line(&parser, 0, &buf0, 256)
    let line0 = String(cString: buf0)
    #expect(line0 == "ABCDEFGHIJ")

    var buf1 = [CChar](repeating: 0, count: 256)
    vt_parser_get_line(&parser, 1, &buf1, 256)
    let line1 = String(cString: buf1)
    #expect(line1 == "KL")
}

// MARK: - Edge Cases

@Test func testEmptyFeed() {
    var parser = VTParserState()
    vt_parser_init(&parser, 80, 24)
    defer { vt_parser_destroy(&parser) }

    // Feed empty data — should not crash
    vt_parser_feed(&parser, "", 0)
    vt_parser_feed(&parser, nil, 0)

    #expect(parser.cursor_row == 0)
    #expect(parser.cursor_col == 0)
}

@Test func testGetCellOutOfBounds() {
    var parser = VTParserState()
    vt_parser_init(&parser, 80, 24)
    defer { vt_parser_destroy(&parser) }

    // Out of bounds — should return zeroed cell
    var cell = VTCell()
    cell.character = 999
    vt_parser_get_cell(&parser, 100, 100, &cell)
    #expect(cell.character == 0)
}

@Test func testGetLineOutOfBounds() {
    var parser = VTParserState()
    vt_parser_init(&parser, 80, 24)
    defer { vt_parser_destroy(&parser) }

    var buf = [CChar](repeating: 0, count: 256)
    let written = vt_parser_get_line(&parser, 100, &buf, 256)
    #expect(written == 0)
}

// MARK: - Scroll Down Tests

@Test func testScrollDown() {
    var parser = VTParserState()
    vt_parser_init(&parser, 80, 5)
    defer { vt_parser_destroy(&parser) }

    // Write lines 0-4
    let text = "Line0\r\nLine1\r\nLine2\r\nLine3\r\nLine4"
    vt_parser_feed(&parser, text, Int32(text.utf8.count))

    // CSI T — scroll down 1 line (insert blank at top, push content down)
    let scrollDown = "\u{1B}[T"
    vt_parser_feed(&parser, scrollDown, Int32(scrollDown.utf8.count))

    var buf = [CChar](repeating: 0, count: 256)
    // Row 0 should now be blank (scroll_down inserts at top)
    vt_parser_get_line(&parser, 0, &buf, 256)
    #expect(String(cString: buf) == "")

    // Row 1 should have the old row 0 content
    vt_parser_get_line(&parser, 1, &buf, 256)
    #expect(String(cString: buf) == "Line0")
}

// MARK: - CSI Insert/Delete Lines Tests

@Test func testCSIInsertLines() {
    var parser = VTParserState()
    vt_parser_init(&parser, 80, 5)
    defer { vt_parser_destroy(&parser) }

    // Fill rows 0-4
    let text = "Row0\r\nRow1\r\nRow2\r\nRow3\r\nRow4"
    vt_parser_feed(&parser, text, Int32(text.utf8.count))

    // Position cursor at row 1 and insert 1 line (CSI L)
    let insertLine = "\u{1B}[2;1H\u{1B}[L"
    vt_parser_feed(&parser, insertLine, Int32(insertLine.utf8.count))

    var buf = [CChar](repeating: 0, count: 256)
    // Row 0 unchanged
    vt_parser_get_line(&parser, 0, &buf, 256)
    #expect(String(cString: buf) == "Row0")

    // Row 1 should be blank (inserted)
    vt_parser_get_line(&parser, 1, &buf, 256)
    #expect(String(cString: buf) == "")

    // Row 2 should have old Row1
    vt_parser_get_line(&parser, 2, &buf, 256)
    #expect(String(cString: buf) == "Row1")
}

@Test func testCSIDeleteLines() {
    var parser = VTParserState()
    vt_parser_init(&parser, 80, 5)
    defer { vt_parser_destroy(&parser) }

    // Fill rows 0-4
    let text = "Row0\r\nRow1\r\nRow2\r\nRow3\r\nRow4"
    vt_parser_feed(&parser, text, Int32(text.utf8.count))

    // Position cursor at row 1 and delete 1 line (CSI M)
    let deleteLine = "\u{1B}[2;1H\u{1B}[M"
    vt_parser_feed(&parser, deleteLine, Int32(deleteLine.utf8.count))

    var buf = [CChar](repeating: 0, count: 256)
    // Row 0 unchanged
    vt_parser_get_line(&parser, 0, &buf, 256)
    #expect(String(cString: buf) == "Row0")

    // Row 1 should now have old Row2 (Row1 was deleted)
    vt_parser_get_line(&parser, 1, &buf, 256)
    #expect(String(cString: buf) == "Row2")

    // Last row should be blank
    vt_parser_get_line(&parser, 4, &buf, 256)
    #expect(String(cString: buf) == "")
}

@Test func testCSIScrollUp() {
    var parser = VTParserState()
    vt_parser_init(&parser, 80, 5)
    defer { vt_parser_destroy(&parser) }

    let text = "Row0\r\nRow1\r\nRow2\r\nRow3\r\nRow4"
    vt_parser_feed(&parser, text, Int32(text.utf8.count))

    // CSI S — scroll up 1 (top row removed, blank row at bottom)
    let scrollUp = "\u{1B}[S"
    vt_parser_feed(&parser, scrollUp, Int32(scrollUp.utf8.count))

    var buf = [CChar](repeating: 0, count: 256)
    vt_parser_get_line(&parser, 0, &buf, 256)
    #expect(String(cString: buf) == "Row1")

    vt_parser_get_line(&parser, 4, &buf, 256)
    #expect(String(cString: buf) == "")
}

// MARK: - OSC ST Terminator Test

@Test func testOSCWithSTTerminator() {
    var parser = VTParserState()
    vt_parser_init(&parser, 80, 24)
    defer { vt_parser_destroy(&parser) }

    // OSC terminated by ST (ESC \) instead of BEL — backslash must not leak
    let text = "\u{1B}]0;Title\u{1B}\\Hello"
    vt_parser_feed(&parser, text, Int32(text.utf8.count))

    var buf = [CChar](repeating: 0, count: 256)
    vt_parser_get_line(&parser, 0, &buf, 256)
    #expect(String(cString: buf) == "Hello")
}

// MARK: - get_line Sparse Content Test

@Test func testGetLineSparseContent() {
    var parser = VTParserState()
    vt_parser_init(&parser, 40, 24)
    defer { vt_parser_destroy(&parser) }

    // Write "AB" at col 0, then jump to col 10 and write "CD"
    let text = "AB\u{1B}[1;11HCD"
    vt_parser_feed(&parser, text, Int32(text.utf8.count))

    var buf = [CChar](repeating: 0, count: 256)
    vt_parser_get_line(&parser, 0, &buf, 256)
    let line = String(cString: buf)

    // Should contain "AB" + 8 spaces + "CD"
    #expect(line == "AB        CD")
}

// MARK: - Wide Character (CJK/Hangul) Tests

@Test func testKoreanHangulWidth() {
    var parser = VTParserState()
    vt_parser_init(&parser, 80, 24)
    defer { vt_parser_destroy(&parser) }

    // Feed Korean "한" (U+D55C)
    let text = "한"
    vt_parser_feed(&parser, text, Int32(text.utf8.count))

    var cell = VTCell()
    vt_parser_get_cell(&parser, 0, 0, &cell)

    #expect(cell.character == 0xD55C) // correct codepoint
    #expect(cell.width == 2)          // wide character

    // Continuation cell at col 1
    var cont = VTCell()
    vt_parser_get_cell(&parser, 0, 1, &cont)
    #expect(cont.character == 0)      // no character
    #expect(cont.width == 0)          // continuation marker

    // Cursor should be at col 2 (after the 2-cell character)
    #expect(parser.cursor_col == 2)
}

@Test func testKoreanMixedWithASCII() {
    var parser = VTParserState()
    vt_parser_init(&parser, 80, 24)
    defer { vt_parser_destroy(&parser) }

    // "A한B" — ASCII + wide + ASCII
    let text = "A한B"
    vt_parser_feed(&parser, text, Int32(text.utf8.count))

    // col 0: 'A' (width=1)
    var cell0 = VTCell()
    vt_parser_get_cell(&parser, 0, 0, &cell0)
    #expect(cell0.character == UInt32(Character("A").asciiValue!))
    #expect(cell0.width == 1)

    // col 1: '한' (width=2)
    var cell1 = VTCell()
    vt_parser_get_cell(&parser, 0, 1, &cell1)
    #expect(cell1.character == 0xD55C)
    #expect(cell1.width == 2)

    // col 2: continuation
    var cell2 = VTCell()
    vt_parser_get_cell(&parser, 0, 2, &cell2)
    #expect(cell2.character == 0)
    #expect(cell2.width == 0)

    // col 3: 'B' (width=1)
    var cell3 = VTCell()
    vt_parser_get_cell(&parser, 0, 3, &cell3)
    #expect(cell3.character == UInt32(Character("B").asciiValue!))
    #expect(cell3.width == 1)

    // Cursor at col 4
    #expect(parser.cursor_col == 4)
}

@Test func testKoreanGetLine() {
    var parser = VTParserState()
    vt_parser_init(&parser, 80, 24)
    defer { vt_parser_destroy(&parser) }

    let text = "한글테스트"
    vt_parser_feed(&parser, text, Int32(text.utf8.count))

    var buf = [CChar](repeating: 0, count: 256)
    vt_parser_get_line(&parser, 0, &buf, 256)
    let line = String(cString: buf)

    #expect(line == "한글테스트")
}

@Test func testCJKIdeograph() {
    var parser = VTParserState()
    vt_parser_init(&parser, 80, 24)
    defer { vt_parser_destroy(&parser) }

    // Chinese character "中" (U+4E2D)
    let text = "中"
    vt_parser_feed(&parser, text, Int32(text.utf8.count))

    var cell = VTCell()
    vt_parser_get_cell(&parser, 0, 0, &cell)
    #expect(cell.character == 0x4E2D)
    #expect(cell.width == 2)
    #expect(parser.cursor_col == 2)
}

@Test func testWideCharAtLastColumn() {
    var parser = VTParserState()
    vt_parser_init(&parser, 10, 24)
    defer { vt_parser_destroy(&parser) }

    // Fill 9 columns with 'A', then write a wide char at col 9 (last column).
    // The wide char doesn't fit, so it should wrap to the next line.
    let text = "AAAAAAAAA한"  // 9 A's + 1 wide char
    vt_parser_feed(&parser, text, Int32(text.utf8.count))

    // Col 9 should be blank (the wide char couldn't fit).
    var cell9 = VTCell()
    vt_parser_get_cell(&parser, 0, 9, &cell9)
    #expect(cell9.character == 0)

    // The wide char should be on row 1, col 0.
    var cellWide = VTCell()
    vt_parser_get_cell(&parser, 1, 0, &cellWide)
    #expect(cellWide.character == 0xD55C)
    #expect(cellWide.width == 2)

    // Continuation at row 1, col 1.
    var cellCont = VTCell()
    vt_parser_get_cell(&parser, 1, 1, &cellCont)
    #expect(cellCont.character == 0)
    #expect(cellCont.width == 0)
}

// MARK: - Cursor Visibility Tests

@Test func testCursorVisibleByDefault() {
    var parser = VTParserState()
    vt_parser_init(&parser, 80, 24)
    defer { vt_parser_destroy(&parser) }

    #expect(parser.cursor_visible == 1)
}

@Test func testCursorStyleDefaultBlock() {
    var parser = VTParserState()
    vt_parser_init(&parser, 80, 24)
    defer { vt_parser_destroy(&parser) }

    #expect(parser.cursor_style == 0)
}
