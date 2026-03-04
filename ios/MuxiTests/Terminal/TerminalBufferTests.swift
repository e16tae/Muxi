import XCTest
@testable import Muxi

final class TerminalBufferTests: XCTestCase {

    // MARK: - Initialization

    func testInitialDimensions() {
        let buffer = TerminalBuffer(cols: 80, rows: 24)
        XCTAssertEqual(buffer.cols, 80)
        XCTAssertEqual(buffer.rows, 24)
    }

    func testInitialCursorAtOrigin() {
        let buffer = TerminalBuffer(cols: 80, rows: 24)
        XCTAssertEqual(buffer.cursorRow, 0)
        XCTAssertEqual(buffer.cursorCol, 0)
    }

    // MARK: - Feed and Cell Access

    func testWriteAndReadCell() {
        let buffer = TerminalBuffer(cols: 80, rows: 24)
        buffer.feed("Hello, Muxi!")

        let cell = buffer.cellAt(row: 0, col: 0)
        XCTAssertEqual(cell.character, Character("H"))

        let cell2 = buffer.cellAt(row: 0, col: 7)
        XCTAssertEqual(cell2.character, Character("M"))
    }

    func testEmptyCellReturnsSpace() {
        let buffer = TerminalBuffer(cols: 80, rows: 24)
        // Row 5 has not been written to.
        let cell = buffer.cellAt(row: 5, col: 0)
        XCTAssertEqual(cell.character, Character(" "))
    }

    func testFeedData() {
        let buffer = TerminalBuffer(cols: 80, rows: 24)
        let data = "Data feed".data(using: .utf8)!
        buffer.feedData(data)

        let cell = buffer.cellAt(row: 0, col: 0)
        XCTAssertEqual(cell.character, Character("D"))

        let line = buffer.lineText(row: 0)
        XCTAssertTrue(line.hasPrefix("Data feed"))
    }

    // MARK: - Line Content

    func testLineContent() {
        let buffer = TerminalBuffer(cols: 80, rows: 24)
        buffer.feed("Test Line")

        let line = buffer.lineText(row: 0)
        XCTAssertTrue(line.hasPrefix("Test Line"))
    }

    func testEmptyLineReturnsEmptyString() {
        let buffer = TerminalBuffer(cols: 80, rows: 24)
        let line = buffer.lineText(row: 10)
        XCTAssertEqual(line, "")
    }

    // MARK: - Cursor Position

    func testCursorPositionAfterFeed() {
        let buffer = TerminalBuffer(cols: 80, rows: 24)
        buffer.feed("AB")
        XCTAssertEqual(buffer.cursorCol, 2)
        XCTAssertEqual(buffer.cursorRow, 0)
    }

    func testCursorAdvancesWithNewline() {
        let buffer = TerminalBuffer(cols: 80, rows: 24)
        buffer.feed("Line1\r\nLine2")
        XCTAssertEqual(buffer.cursorRow, 1)
        XCTAssertEqual(buffer.cursorCol, 5)
    }

    // MARK: - Resize

    func testResize() {
        let buffer = TerminalBuffer(cols: 80, rows: 24)
        buffer.feed("Data")
        buffer.resize(cols: 120, rows: 40)

        XCTAssertEqual(buffer.cols, 120)
        XCTAssertEqual(buffer.rows, 40)
    }

    // MARK: - Colors

    func testDefaultColors() {
        let buffer = TerminalBuffer(cols: 80, rows: 24)
        buffer.feed("X")

        let cell = buffer.cellAt(row: 0, col: 0)
        XCTAssertEqual(cell.fgColor, .default)
        XCTAssertEqual(cell.bgColor, .default)
    }

    func testAnsiColorForeground() {
        let buffer = TerminalBuffer(cols: 80, rows: 24)
        // ESC[31m = set foreground to ANSI red (color index 1 for basic,
        // but many implementations use 31 -> index 31). The C parser stores
        // the raw color index in fg_color.
        buffer.feed("\u{1B}[31mR")

        let cell = buffer.cellAt(row: 0, col: 0)
        XCTAssertEqual(cell.character, Character("R"))
        // The parser should set a non-default foreground color.
        XCTAssertNotEqual(cell.fgColor, .default)
    }

    func testAnsiColorBackground() {
        let buffer = TerminalBuffer(cols: 80, rows: 24)
        // ESC[42m = set background to ANSI green
        buffer.feed("\u{1B}[42mG")

        let cell = buffer.cellAt(row: 0, col: 0)
        XCTAssertEqual(cell.character, Character("G"))
        XCTAssertNotEqual(cell.bgColor, .default)
    }

    // MARK: - Attributes

    func testBoldAttribute() {
        let buffer = TerminalBuffer(cols: 80, rows: 24)
        // ESC[1m = bold
        buffer.feed("\u{1B}[1mB")

        let cell = buffer.cellAt(row: 0, col: 0)
        XCTAssertEqual(cell.character, Character("B"))
        XCTAssertTrue(cell.isBold)
    }

    func testItalicAttribute() {
        let buffer = TerminalBuffer(cols: 80, rows: 24)
        // ESC[3m = italic
        buffer.feed("\u{1B}[3mI")

        let cell = buffer.cellAt(row: 0, col: 0)
        XCTAssertEqual(cell.character, Character("I"))
        XCTAssertTrue(cell.isItalic)
    }

    func testUnderlineAttribute() {
        let buffer = TerminalBuffer(cols: 80, rows: 24)
        // ESC[4m = underline
        buffer.feed("\u{1B}[4mU")

        let cell = buffer.cellAt(row: 0, col: 0)
        XCTAssertEqual(cell.character, Character("U"))
        XCTAssertTrue(cell.isUnderline)
    }

    func testNoAttributesByDefault() {
        let buffer = TerminalBuffer(cols: 80, rows: 24)
        buffer.feed("N")

        let cell = buffer.cellAt(row: 0, col: 0)
        XCTAssertFalse(cell.isBold)
        XCTAssertFalse(cell.isItalic)
        XCTAssertFalse(cell.isUnderline)
        XCTAssertFalse(cell.isInverse)
        XCTAssertFalse(cell.isStrikethrough)
    }

    // MARK: - TerminalCell Static

    func testTerminalCellEmptyConstant() {
        let empty = TerminalCell.empty
        XCTAssertEqual(empty.character, " ")
        XCTAssertEqual(empty.fgColor, .default)
        XCTAssertEqual(empty.bgColor, .default)
        XCTAssertFalse(empty.isBold)
        XCTAssertFalse(empty.isItalic)
        XCTAssertFalse(empty.isUnderline)
        XCTAssertFalse(empty.isInverse)
        XCTAssertFalse(empty.isStrikethrough)
    }

    // MARK: - Text Extraction

    func testTextFromSingleLine() {
        let buffer = TerminalBuffer(cols: 80, rows: 24)
        buffer.feed("Hello, World!")
        let text = buffer.text(
            from: (row: 0, col: 0),
            to: (row: 0, col: 12)
        )
        XCTAssertEqual(text, "Hello, World!")
    }

    func testTextFromPartialLine() {
        let buffer = TerminalBuffer(cols: 80, rows: 24)
        buffer.feed("Hello, World!")
        let text = buffer.text(
            from: (row: 0, col: 7),
            to: (row: 0, col: 11)
        )
        XCTAssertEqual(text, "World")
    }

    func testTextFromMultipleLines() {
        let buffer = TerminalBuffer(cols: 80, rows: 24)
        buffer.feed("Line one\r\nLine two\r\nLine three")
        let text = buffer.text(
            from: (row: 0, col: 5),
            to: (row: 2, col: 9)
        )
        XCTAssertEqual(text, "one\nLine two\nLine three")
    }

    func testTextTrimsTrailingSpaces() {
        let buffer = TerminalBuffer(cols: 10, rows: 5)
        buffer.feed("Hi")
        // "Hi" followed by 8 spaces to fill the row — trailing spaces should be trimmed.
        let text = buffer.text(
            from: (row: 0, col: 0),
            to: (row: 0, col: 9)
        )
        XCTAssertEqual(text, "Hi")
    }

    func testTextWithEmptySelection() {
        let buffer = TerminalBuffer(cols: 80, rows: 24)
        buffer.feed("Hello")
        // Single cell selection.
        let text = buffer.text(
            from: (row: 0, col: 0),
            to: (row: 0, col: 0)
        )
        XCTAssertEqual(text, "H")
    }

    // MARK: - TerminalColor Equatable

    func testTerminalColorEquality() {
        XCTAssertEqual(TerminalColor.default, TerminalColor.default)
        XCTAssertEqual(TerminalColor.ansi(1), TerminalColor.ansi(1))
        XCTAssertNotEqual(TerminalColor.ansi(1), TerminalColor.ansi(2))
        XCTAssertEqual(TerminalColor.rgb(255, 0, 0), TerminalColor.rgb(255, 0, 0))
        XCTAssertNotEqual(TerminalColor.rgb(255, 0, 0), TerminalColor.rgb(0, 255, 0))
        XCTAssertNotEqual(TerminalColor.default, TerminalColor.ansi(0))
    }
}
