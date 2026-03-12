import Foundation
import MuxiCore

// MARK: - TerminalColor

/// Color representation for a terminal cell's foreground or background.
enum TerminalColor: Equatable {
    /// The terminal's default color (no explicit color set).
    case `default`
    /// An ANSI 256-color palette index (0-255).
    case ansi(UInt8)
    /// A 24-bit RGB color.
    case rgb(UInt8, UInt8, UInt8)
}

// MARK: - TerminalCell

/// A single cell in the terminal grid, holding a character and its attributes.
struct TerminalCell {
    let character: Character
    /// Cell width: 0 = continuation (second half of wide char), 1 = normal, 2 = wide (CJK).
    let width: UInt8
    let fgColor: TerminalColor
    let bgColor: TerminalColor
    let isBold: Bool
    let isItalic: Bool
    let isUnderline: Bool
    let isInverse: Bool
    let isStrikethrough: Bool

    static let empty = TerminalCell(
        character: " ",
        width: 1,
        fgColor: .default,
        bgColor: .default,
        isBold: false,
        isItalic: false,
        isUnderline: false,
        isInverse: false,
        isStrikethrough: false
    )
}

// MARK: - CursorStyle

/// Terminal cursor shape, mapped from DECSCUSR values.
enum CursorStyle: Equatable {
    /// Block cursor (DECSCUSR 0, 1, 2).
    case block
    /// Underline cursor (DECSCUSR 3, 4).
    case underline
    /// Vertical bar/beam cursor (DECSCUSR 5, 6).
    case bar

    /// Map raw DECSCUSR value (0-6) to a CursorStyle.
    /// Blink variants map to the same shape (blink is not rendered).
    init(decscusr value: Int32) {
        switch value {
        case 3, 4: self = .underline
        case 5, 6: self = .bar
        default:   self = .block  // 0, 1, 2 and invalid values
        }
    }
}

// MARK: - TerminalBuffer

/// Swift wrapper around the C VT parser. Takes terminal output as strings or
/// raw `Data` and exposes the parsed cell grid with colors and attributes.
///
/// Each ``TerminalBuffer`` owns a ``VTParserState`` and frees its resources on
/// deinitialization.
final class TerminalBuffer {

    // MARK: Internal State

    private var parser: VTParserState

    /// Called after each ``feed(_:)`` or ``feedData(_:)`` to notify listeners
    /// (e.g. the Metal view) that the buffer content has changed.
    var onUpdate: (() -> Void)?

    // MARK: Public Properties

    /// Number of columns in the terminal grid.
    var cols: Int { Int(parser.cols) }

    /// Number of rows in the terminal grid.
    var rows: Int { Int(parser.rows) }

    /// Current cursor row (0-based).
    var cursorRow: Int { Int(parser.cursor_row) }

    /// Current cursor column (0-based).
    var cursorCol: Int { Int(parser.cursor_col) }

    /// Whether the cursor is visible (DECTCEM).
    var cursorVisible: Bool { parser.cursor_visible != 0 }

    /// Current cursor style (DECSCUSR).
    var cursorStyle: CursorStyle { CursorStyle(decscusr: parser.cursor_style) }

    // MARK: Lifecycle

    /// Create a new terminal buffer with the given dimensions.
    init(cols: Int, rows: Int) {
        parser = VTParserState()
        vt_parser_init(&parser, Int32(cols), Int32(rows))
    }

    deinit {
        vt_parser_destroy(&parser)
    }

    // MARK: Feeding Data

    /// Feed a string of terminal output (may contain ANSI escape sequences).
    func feed(_ text: String) {
        let count = text.utf8.count
        text.withCString { ptr in
            vt_parser_feed(&parser, ptr, Int32(count))
        }
        onUpdate?()
    }

    /// Feed raw bytes of terminal output.
    func feedData(_ data: Data) {
        data.withUnsafeBytes { rawBuf in
            guard let ptr = rawBuf.baseAddress?.assumingMemoryBound(to: CChar.self) else {
                return
            }
            vt_parser_feed(&parser, ptr, Int32(data.count))
        }
        onUpdate?()
    }

    // MARK: Cursor

    /// Set the cursor position (clamped to grid bounds by the C layer).
    func setCursor(row: Int, col: Int) {
        vt_parser_set_cursor(&parser, Int32(row), Int32(col))
    }

    // MARK: Resize

    /// Resize the terminal grid. Existing content is preserved where possible.
    func resize(cols: Int, rows: Int) {
        vt_parser_resize(&parser, Int32(cols), Int32(rows))
    }

    // MARK: Cell Access

    /// Retrieve the cell at the given row and column.
    func cellAt(row: Int, col: Int) -> TerminalCell {
        var cell = VTCell()
        vt_parser_get_cell(&parser, Int32(row), Int32(col), &cell)

        let ch: Character
        if cell.character > 0, let scalar = Unicode.Scalar(cell.character) {
            ch = Character(scalar)
        } else {
            ch = " "
        }

        let fg: TerminalColor
        if cell.fg_is_rgb != 0 {
            fg = .rgb(cell.fg_r, cell.fg_g, cell.fg_b)
        } else if cell.fg_has_color != 0 {
            fg = .ansi(cell.fg_color)
        } else {
            fg = .default
        }

        let bg: TerminalColor
        if cell.bg_is_rgb != 0 {
            bg = .rgb(cell.bg_r, cell.bg_g, cell.bg_b)
        } else if cell.bg_has_color != 0 {
            bg = .ansi(cell.bg_color)
        } else {
            bg = .default
        }

        return TerminalCell(
            character: ch,
            width: cell.width,
            fgColor: fg,
            bgColor: bg,
            isBold: cell.attrs & 1 != 0,
            isItalic: cell.attrs & 4 != 0,
            isUnderline: cell.attrs & 2 != 0,
            isInverse: cell.attrs & 8 != 0,
            isStrikethrough: cell.attrs & 16 != 0
        )
    }

    // MARK: Line Access

    /// Get the plain text content of a row (trailing spaces trimmed by the C layer).
    /// The buffer is sized to handle multi-byte UTF-8 characters (up to 4 bytes each).
    func lineText(row: Int) -> String {
        // Each cell can produce up to 4 UTF-8 bytes, plus a null terminator.
        let bufSize = cols * 4 + 1
        var buf = [CChar](repeating: 0, count: bufSize)
        vt_parser_get_line(&parser, Int32(row), &buf, Int32(bufSize))
        return String(cString: buf)
    }

    // MARK: - Text Extraction

    /// Extract text from a linear selection in the buffer.
    ///
    /// Iterates cell-by-cell from `start` to `end`, skipping wide-character
    /// continuation cells (width == 0) and trimming trailing whitespace per line.
    ///
    /// - Parameters:
    ///   - start: The (row, col) of the selection start.
    ///   - end: The (row, col) of the selection end.
    /// - Returns: The selected text with lines joined by `\n`.
    func text(
        from start: (row: Int, col: Int),
        to end: (row: Int, col: Int)
    ) -> String {
        // Normalize so start is always before end.
        let (s, e): ((row: Int, col: Int), (row: Int, col: Int))
        if start.row < end.row || (start.row == end.row && start.col <= end.col) {
            (s, e) = (start, end)
        } else {
            (s, e) = (end, start)
        }

        // Clamp to buffer bounds.
        let sRow = max(0, min(s.row, rows - 1))
        let sCol = max(0, min(s.col, cols - 1))
        let eRow = max(0, min(e.row, rows - 1))
        let eCol = max(0, min(e.col, cols - 1))

        var lines: [String] = []
        for row in sRow...eRow {
            var line = ""
            let colStart = row == sRow ? sCol : 0
            let colEnd = row == eRow ? eCol : cols - 1
            guard colStart <= colEnd else {
                lines.append("")
                continue
            }
            for col in colStart...colEnd {
                let cell = cellAt(row: row, col: col)
                if cell.width == 0 { continue }
                line.append(cell.character)
            }
            // Trim trailing whitespace (match lineText behavior).
            while line.last == " " {
                line.removeLast()
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}
