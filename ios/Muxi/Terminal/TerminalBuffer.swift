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
    let fgColor: TerminalColor
    let bgColor: TerminalColor
    let isBold: Bool
    let isItalic: Bool
    let isUnderline: Bool
    let isInverse: Bool
    let isStrikethrough: Bool

    static let empty = TerminalCell(
        character: " ",
        fgColor: .default,
        bgColor: .default,
        isBold: false,
        isItalic: false,
        isUnderline: false,
        isInverse: false,
        isStrikethrough: false
    )
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

    // MARK: Public Properties

    /// Number of columns in the terminal grid.
    var cols: Int { Int(parser.cols) }

    /// Number of rows in the terminal grid.
    var rows: Int { Int(parser.rows) }

    /// Current cursor row (0-based).
    var cursorRow: Int { Int(parser.cursor_row) }

    /// Current cursor column (0-based).
    var cursorCol: Int { Int(parser.cursor_col) }

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
    }

    /// Feed raw bytes of terminal output.
    func feedData(_ data: Data) {
        data.withUnsafeBytes { rawBuf in
            guard let ptr = rawBuf.baseAddress?.assumingMemoryBound(to: CChar.self) else {
                return
            }
            vt_parser_feed(&parser, ptr, Int32(data.count))
        }
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
}
