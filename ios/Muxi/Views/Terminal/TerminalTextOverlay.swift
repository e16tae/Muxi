import UIKit

// MARK: - Text Position & Range

/// A position in the terminal grid, used by UITextInput.
final class TerminalTextPosition: UITextPosition {
    let row: Int
    let col: Int

    init(row: Int, col: Int) {
        self.row = row
        self.col = col
    }

    func linearOffset(cols: Int) -> Int {
        row * cols + col
    }
}

/// A range in the terminal grid, used by UITextInput.
final class TerminalTextRange: UITextRange {
    let startPos: TerminalTextPosition
    let endPos: TerminalTextPosition

    override var start: UITextPosition { startPos }
    override var end: UITextPosition { endPos }
    override var isEmpty: Bool {
        startPos.row == endPos.row && startPos.col == endPos.col
    }

    init(start: TerminalTextPosition, end: TerminalTextPosition) {
        self.startPos = start
        self.endPos = end
    }
}

/// A selection rect for a single row within a terminal selection.
final class TerminalSelectionRectValue: UITextSelectionRect {
    private let _rect: CGRect
    private let _containsStart: Bool
    private let _containsEnd: Bool

    override var rect: CGRect { _rect }
    override var containsStart: Bool { _containsStart }
    override var containsEnd: Bool { _containsEnd }
    override var writingDirection: NSWritingDirection { .leftToRight }
    override var isVertical: Bool { false }

    init(rect: CGRect, containsStart: Bool, containsEnd: Bool) {
        _rect = rect
        _containsStart = containsStart
        _containsEnd = containsEnd
    }
}

// MARK: - TerminalTextOverlay

/// Transparent overlay on the MTKView that implements ``UITextInput``
/// with ``UITextInteraction(.nonEditable)`` to provide iOS-standard
/// text selection: handles, loupe, double-tap word selection, triple-tap
/// line selection, and the system edit menu.
///
/// Keyboard input remains on ``TerminalInputAccessor`` (UIKeyInput).
final class TerminalTextOverlay: UIView, UITextInput {

    // MARK: - External references (set by Coordinator)

    weak var buffer: TerminalBuffer?
    weak var scrollbackBuffer: TerminalBuffer?
    var scrollOffset: Int = 0
    var cellWidth: CGFloat = 0
    var cellHeight: CGFloat = 0

    // MARK: - Callbacks

    var onSelectionChanged: (((start: (row: Int, col: Int), end: (row: Int, col: Int))?) -> Void)?
    var onPaste: ((String) -> Void)?
    var onKeyboardReactivate: (() -> Void)?

    // MARK: - UITextInput required properties

    var inputDelegate: UITextInputDelegate?
    lazy var tokenizer: UITextInputTokenizer = UITextInputStringTokenizer(textInput: self)

    // MARK: - UITextInteraction

    private var textInteraction: UITextInteraction!

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = true

        textInteraction = UITextInteraction(for: .nonEditable)
        textInteraction.textInput = self
        addInteraction(textInteraction)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - First Responder

    override var canBecomeFirstResponder: Bool { true }

    // MARK: - Grid helpers

    private var visibleRows: Int {
        buffer?.rows ?? 24
    }

    private var visibleCols: Int {
        buffer?.cols ?? 80
    }

    private func clamp(row: Int, col: Int) -> (row: Int, col: Int) {
        (max(0, min(row, visibleRows - 1)),
         max(0, min(col, visibleCols - 1)))
    }

    /// Normalize a range so start ≤ end in linear order.
    private func normalized(_ r: TerminalTextRange) -> (s: TerminalTextPosition, e: TerminalTextPosition) {
        let cols = visibleCols
        if r.startPos.linearOffset(cols: cols) <= r.endPos.linearOffset(cols: cols) {
            return (r.startPos, r.endPos)
        }
        return (r.endPos, r.startPos)
    }

    // MARK: - selectedTextRange

    private var _selectedTextRange: TerminalTextRange?

    var selectedTextRange: UITextRange? {
        get { _selectedTextRange }
        set {
            let old = _selectedTextRange
            inputDelegate?.selectionWillChange(self)
            _selectedTextRange = newValue as? TerminalTextRange
            if let r = _selectedTextRange {
                let s = (row: r.startPos.row, col: r.startPos.col)
                let e = (row: r.endPos.row, col: r.endPos.col)
                onSelectionChanged?((start: s, end: e))
            } else {
                onSelectionChanged?(nil)
            }
            if old !== _selectedTextRange {
                inputDelegate?.selectionDidChange(self)
            }
        }
    }

    // MARK: - Document endpoints

    var beginningOfDocument: UITextPosition {
        TerminalTextPosition(row: 0, col: 0)
    }

    var endOfDocument: UITextPosition {
        TerminalTextPosition(row: visibleRows - 1, col: visibleCols - 1)
    }

    // MARK: - Position arithmetic

    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard let from = fromPosition as? TerminalTextPosition,
              let to = toPosition as? TerminalTextPosition else { return nil }
        return TerminalTextRange(start: from, end: to)
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let pos = position as? TerminalTextPosition else { return nil }
        let cols = visibleCols
        let linear = pos.linearOffset(cols: cols) + offset
        guard linear >= 0 else { return nil }
        let maxLinear = visibleRows * cols - 1
        guard linear <= maxLinear else { return nil }
        return TerminalTextPosition(row: linear / cols, col: linear % cols)
    }

    func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        guard let pos = position as? TerminalTextPosition else { return nil }
        switch direction {
        case .left:  return self.position(from: pos, offset: -offset)
        case .right: return self.position(from: pos, offset: offset)
        case .up:    return TerminalTextPosition(row: max(0, pos.row - offset), col: pos.col)
        case .down:  return TerminalTextPosition(row: min(visibleRows - 1, pos.row + offset), col: pos.col)
        @unknown default: return nil
        }
    }

    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        guard let a = position as? TerminalTextPosition,
              let b = other as? TerminalTextPosition else { return .orderedSame }
        let cols = visibleCols
        let la = a.linearOffset(cols: cols)
        let lb = b.linearOffset(cols: cols)
        if la < lb { return .orderedAscending }
        if la > lb { return .orderedDescending }
        return .orderedSame
    }

    func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        guard let a = from as? TerminalTextPosition,
              let b = toPosition as? TerminalTextPosition else { return 0 }
        let cols = visibleCols
        return b.linearOffset(cols: cols) - a.linearOffset(cols: cols)
    }

    // MARK: - Hit testing / geometry

    func closestPosition(to point: CGPoint) -> UITextPosition? {
        guard cellWidth > 0, cellHeight > 0 else { return nil }
        let (row, col) = clamp(
            row: Int(point.y / cellHeight),
            col: Int(point.x / cellWidth)
        )
        return TerminalTextPosition(row: row, col: col)
    }

    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
        closestPosition(to: point)
    }

    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        guard let r = range as? TerminalTextRange else { return nil }
        switch direction {
        case .left, .up: return r.startPos
        case .right, .down: return r.endPos
        @unknown default: return r.startPos
        }
    }

    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        guard let pos = position as? TerminalTextPosition else { return nil }
        switch direction {
        case .left:
            let start = TerminalTextPosition(row: pos.row, col: 0)
            return TerminalTextRange(start: start, end: pos)
        case .right:
            let end = TerminalTextPosition(row: pos.row, col: visibleCols - 1)
            return TerminalTextRange(start: pos, end: end)
        case .up:
            let start = TerminalTextPosition(row: 0, col: pos.col)
            return TerminalTextRange(start: start, end: pos)
        case .down:
            let end = TerminalTextPosition(row: visibleRows - 1, col: pos.col)
            return TerminalTextRange(start: pos, end: end)
        @unknown default:
            return nil
        }
    }

    func characterRange(at point: CGPoint) -> UITextRange? {
        guard let pos = closestPosition(to: point) as? TerminalTextPosition else { return nil }
        let end = TerminalTextPosition(row: pos.row, col: min(pos.col + 1, visibleCols - 1))
        return TerminalTextRange(start: pos, end: end)
    }

    func firstRect(for range: UITextRange) -> CGRect {
        guard let r = range as? TerminalTextRange else { return .zero }
        let (s, e) = normalized(r)
        let x = CGFloat(s.col) * cellWidth
        let y = CGFloat(s.row) * cellHeight
        if s.row == e.row {
            let w = CGFloat(e.col - s.col) * cellWidth
            return CGRect(x: x, y: y, width: max(w, cellWidth), height: cellHeight)
        }
        // Multi-line: return first line rect.
        let w = CGFloat(visibleCols - s.col) * cellWidth
        return CGRect(x: x, y: y, width: w, height: cellHeight)
    }

    func caretRect(for position: UITextPosition) -> CGRect {
        guard let pos = position as? TerminalTextPosition else { return .zero }
        return CGRect(
            x: CGFloat(pos.col) * cellWidth,
            y: CGFloat(pos.row) * cellHeight,
            width: 2,
            height: cellHeight
        )
    }

    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        guard let r = range as? TerminalTextRange else { return [] }
        let (s, e) = normalized(r)
        var rects: [UITextSelectionRect] = []

        if s.row == e.row {
            rects.append(TerminalSelectionRectValue(
                rect: CGRect(
                    x: CGFloat(s.col) * cellWidth,
                    y: CGFloat(s.row) * cellHeight,
                    width: CGFloat(e.col - s.col) * cellWidth,
                    height: cellHeight
                ),
                containsStart: true, containsEnd: true
            ))
        } else {
            for row in s.row...e.row {
                let startCol = (row == s.row) ? s.col : 0
                let endCol = (row == e.row) ? e.col : visibleCols
                rects.append(TerminalSelectionRectValue(
                    rect: CGRect(
                        x: CGFloat(startCol) * cellWidth,
                        y: CGFloat(row) * cellHeight,
                        width: CGFloat(endCol - startCol) * cellWidth,
                        height: cellHeight
                    ),
                    containsStart: row == s.row,
                    containsEnd: row == e.row
                ))
            }
        }
        return rects
    }

    // MARK: - Text extraction (scrollback-aware)

    func text(in range: UITextRange) -> String? {
        guard let r = range as? TerminalTextRange else { return nil }
        let from = (row: r.startPos.row, col: r.startPos.col)
        let to = (row: r.endPos.row, col: r.endPos.col)

        if scrollOffset > 0, let sb = scrollbackBuffer, let live = buffer {
            let startRow = ScrollbackState.startRow(
                offset: scrollOffset, totalLines: sb.rows, visibleRows: live.rows)
            return sb.text(
                from: (row: startRow + from.row, col: from.col),
                to: (row: startRow + to.row, col: to.col))
        }
        return buffer?.text(from: from, to: to)
    }

    // MARK: - UIKeyInput stubs (nonEditable — no text mutation)

    var hasText: Bool { true }
    func insertText(_ text: String) { }
    func deleteBackward() { }

    // MARK: - Marked text stubs (nonEditable)

    var markedTextRange: UITextRange? { nil }
    var markedTextStyle: [NSAttributedString.Key: Any]? {
        get { nil }
        set { }
    }

    func setMarkedText(_ markedText: String?, selectedRange: NSRange) { }
    func unmarkText() { }
    func replace(_ range: UITextRange, withText text: String) { }

    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) { }
    func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection {
        .leftToRight
    }

    // MARK: - Copy / Paste / Select All

    override func copy(_ sender: Any?) {
        guard let range = selectedTextRange as? TerminalTextRange,
              !range.isEmpty,
              let text = text(in: range) else { return }
        UIPasteboard.general.string = text
        selectedTextRange = nil
        onKeyboardReactivate?()
    }

    override func paste(_ sender: Any?) {
        guard let text = UIPasteboard.general.string else { return }
        onPaste?(text)
        selectedTextRange = nil
        onKeyboardReactivate?()
    }

    override func selectAll(_ sender: Any?) {
        selectedTextRange = TerminalTextRange(
            start: TerminalTextPosition(row: 0, col: 0),
            end: TerminalTextPosition(row: visibleRows - 1, col: visibleCols - 1)
        )
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(copy(_:)):
            if let r = selectedTextRange as? TerminalTextRange { return !r.isEmpty }
            return false
        case #selector(paste(_:)):
            return UIPasteboard.general.hasStrings
        case #selector(selectAll(_:)):
            return true
        default:
            return false
        }
    }
}
