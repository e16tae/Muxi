# Text Selection & Copy Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add text selection and copy to the terminal via long press to select, drag to extend, and edit menu to copy.

**Architecture:** All selection state lives in `TerminalView.Coordinator`. Long press begins selection, drag extends it, lifting the finger shows Copy/Paste menu. Visual highlight is achieved by overriding `bgColor` in `TerminalRenderer.rebuildVertices()` using the theme's existing `selection` color — no Metal shader changes. Text extraction via a new `TerminalBuffer.text(from:to:)` method.

**Tech Stack:** SwiftUI, UIKit gestures, Metal (existing renderer), UIPasteboard, XCTest

**Design doc:** `docs/plans/2026-03-04-text-selection-design.md`

---

### Task 1: TerminalBuffer Text Extraction + Tests

**Files:**
- Modify: `ios/Muxi/Terminal/TerminalBuffer.swift`
- Modify: `ios/MuxiTests/Terminal/TerminalBufferTests.swift`

**Step 1: Write the tests**

Add to `ios/MuxiTests/Terminal/TerminalBufferTests.swift`:

```swift
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
```

**Step 2: Run tests to verify they fail**

Run: `cd ios && xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' -only-testing:MuxiTests/TerminalBufferTests 2>&1 | tail -20`
Expected: FAIL — `text(from:to:)` not defined

**Step 3: Implement text extraction**

In `ios/Muxi/Terminal/TerminalBuffer.swift`, add after the `lineText(row:)` method (after line 171):

```swift
    // MARK: - Text Extraction

    /// Extract text from a rectangular selection in the buffer.
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

        var lines: [String] = []
        for row in s.row...e.row {
            var line = ""
            let colStart = row == s.row ? s.col : 0
            let colEnd = row == e.row ? e.col : cols - 1
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
            while line.hasSuffix(" ") {
                line.removeLast()
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
```

**Step 4: Run tests to verify they pass**

Run: `cd ios && xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' -only-testing:MuxiTests/TerminalBufferTests 2>&1 | tail -20`
Expected: PASS

**Step 5: Commit**

```bash
git add ios/Muxi/Terminal/TerminalBuffer.swift ios/MuxiTests/Terminal/TerminalBufferTests.swift
git commit -m "feat: add text(from:to:) range extraction to TerminalBuffer

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 2: Selection Highlight in TerminalRenderer

**Files:**
- Modify: `ios/Muxi/Terminal/TerminalRenderer.swift`

**Step 1: Add selectionRange property**

In `ios/Muxi/Terminal/TerminalRenderer.swift`, add after the scrollback properties (after line 92 `var scrollOffset`):

```swift
    // MARK: - Selection

    /// The currently selected range, if any. When set, `rebuildVertices()`
    /// renders selected cells with the theme's selection background color.
    /// Coordinates are in screen-space (0-based row/col of the visible area).
    var selectionRange: (start: (row: Int, col: Int), end: (row: Int, col: Int))?
```

**Step 2: Add selection highlight to rebuildVertices()**

In the second pass of `rebuildVertices()`, after the cursor highlight block (after the `swap(&fg, &bg)` at line 397-398), add selection highlight:

```swift
                // Selection highlight: override background with theme selection color.
                if let sel = selectionRange {
                    let selStart: (row: Int, col: Int)
                    let selEnd: (row: Int, col: Int)
                    if sel.start.row < sel.end.row
                        || (sel.start.row == sel.end.row && sel.start.col <= sel.end.col) {
                        selStart = sel.start
                        selEnd = sel.end
                    } else {
                        selStart = sel.end
                        selEnd = sel.start
                    }

                    let inSelection: Bool
                    if screenRow > selStart.row && screenRow < selEnd.row {
                        inSelection = true
                    } else if screenRow == selStart.row && screenRow == selEnd.row {
                        inSelection = col >= selStart.col && col <= selEnd.col
                    } else if screenRow == selStart.row {
                        inSelection = col >= selStart.col
                    } else if screenRow == selEnd.row {
                        inSelection = col <= selEnd.col
                    } else {
                        inSelection = false
                    }

                    if inSelection {
                        let sc = theme.selection
                        bg = SIMD4<Float>(
                            Float(sc.r) / 255.0,
                            Float(sc.g) / 255.0,
                            Float(sc.b) / 255.0,
                            1.0
                        )
                    }
                }
```

**Step 3: Run all tests to verify no regression**

Run: `cd ios && xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' 2>&1 | tail -30`
Expected: PASS

**Step 4: Commit**

```bash
git add ios/Muxi/Terminal/TerminalRenderer.swift
git commit -m "feat: add selection highlight to TerminalRenderer

Uses theme.selection color for background of selected cells.
No Metal shader changes — bgColor override in rebuildVertices().

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 3: Selection Gestures & Copy in TerminalView

**Files:**
- Modify: `ios/Muxi/Views/Terminal/TerminalView.swift`

This is the largest task — it wires together gestures, selection state, renderer highlight, and clipboard copy.

**Step 1: Add selection state to Coordinator**

In `ios/Muxi/Views/Terminal/TerminalView.swift`, add to the Coordinator class properties (after `currentFontSize` at line 169):

```swift
        /// Selection anchor (where long press started), in screen-space row/col.
        var selectionStart: (row: Int, col: Int)?
        /// Selection end (current drag position), in screen-space row/col.
        var selectionEnd: (row: Int, col: Int)?
        /// Cached cell width for coordinate mapping.
        var cellWidth: CGFloat = 0
```

**Step 2: Add coordinate mapping helper**

Add after the `requestRedraw()` method (after line 193):

```swift
        /// Convert a touch point (in the MTKView's coordinate space) to
        /// a terminal grid position (row, col).
        func gridPosition(from point: CGPoint) -> (row: Int, col: Int) {
            guard cellWidth > 0, cellHeight > 0 else { return (0, 0) }
            let col = max(0, min(Int(point.x / cellWidth), buffer.cols - 1))
            let row = max(0, min(Int(point.y / cellHeight), buffer.rows - 1))
            return (row, col)
        }
```

**Step 3: Cache cellWidth in makeUIView**

In `makeUIView`, after `context.coordinator.cellHeight = renderer.cellHeight` (line 58), add:

```swift
            context.coordinator.cellWidth = renderer.cellWidth
```

Also in the font size change block in `updateUIView` (after `context.coordinator.cellHeight = ...` at line 149), add:

```swift
            context.coordinator.cellWidth = context.coordinator.renderer?.cellWidth ?? 0
```

**Step 4: Add tap gesture to clear selection**

In `makeUIView`, after the pan gesture recognizer (after line 94), add:

```swift
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        mtkView.addGestureRecognizer(tap)
```

**Step 5: Rewrite handleLongPress for selection**

Replace the existing `handleLongPress` method (lines 224-231) with:

```swift
        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard let view = gesture.view else { return }
            let point = gesture.location(in: view)
            let pos = gridPosition(from: point)

            switch gesture.state {
            case .began:
                // Start selection at the long-press anchor.
                selectionStart = pos
                selectionEnd = pos
                updateRendererSelection()

            case .changed:
                // Extend selection as finger drags.
                selectionEnd = pos
                updateRendererSelection()

            case .ended:
                // Show edit menu at the touch location.
                selectionEnd = pos
                updateRendererSelection()
                if let interaction = editMenuInteraction {
                    let config = UIEditMenuConfiguration(
                        identifier: nil, sourcePoint: point
                    )
                    interaction.presentEditMenu(with: config)
                }

            case .cancelled, .failed:
                clearSelection()

            default:
                break
            }
        }
```

**Step 6: Add handleTap and selection helpers**

Add after `handleLongPress`:

```swift
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }
            if selectionStart != nil {
                clearSelection()
            }
        }

        private func clearSelection() {
            selectionStart = nil
            selectionEnd = nil
            renderer?.selectionRange = nil
            requestRedraw()
        }

        private func updateRendererSelection() {
            guard let start = selectionStart, let end = selectionEnd else {
                renderer?.selectionRange = nil
                return
            }
            renderer?.selectionRange = (start: start, end: end)
            requestRedraw()
        }
```

**Step 7: Update editMenuInteraction to support Copy + Paste**

Replace the existing `editMenuInteraction(_:menuFor:suggestedActions:)` method (lines 233-244) with:

```swift
        func editMenuInteraction(
            _ interaction: UIEditMenuInteraction,
            menuFor configuration: UIEditMenuConfiguration,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            var actions: [UIAction] = []

            // Copy action — available when text is selected.
            if let start = selectionStart, let end = selectionEnd {
                let copy = UIAction(
                    title: "Copy",
                    image: UIImage(systemName: "doc.on.doc")
                ) { [weak self] _ in
                    let text = self?.buffer.text(from: start, to: end) ?? ""
                    UIPasteboard.general.string = text
                    self?.clearSelection()
                }
                actions.append(copy)
            }

            // Paste action — available when clipboard has text.
            if UIPasteboard.general.hasStrings {
                let paste = UIAction(
                    title: "Paste",
                    image: UIImage(systemName: "doc.on.clipboard")
                ) { [weak self] _ in
                    guard let text = UIPasteboard.general.string else { return }
                    self?.onPaste?(text)
                }
                actions.append(paste)
            }

            return actions.isEmpty ? nil : UIMenu(children: actions)
        }
```

**Step 8: Run all tests**

Run: `cd ios && xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' 2>&1 | tail -30`
Expected: PASS

**Step 9: Commit**

```bash
git add ios/Muxi/Views/Terminal/TerminalView.swift
git commit -m "feat: add text selection and copy via long press + drag

Long press starts selection, drag extends, lift shows Copy/Paste menu.
Tap clears selection. Uses theme selection color for highlight.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Notes for Implementer

### Key files to read first
- `docs/plans/2026-03-04-text-selection-design.md` — design rationale
- `ios/Muxi/Views/Terminal/TerminalView.swift` — Coordinator with gesture handling
- `ios/Muxi/Terminal/TerminalRenderer.swift:318-441` — `rebuildVertices()` vertex builder
- `ios/Muxi/Terminal/TerminalBuffer.swift:119-159` — `cellAt()` for per-cell access
- `ios/Muxi/Models/Theme.swift:33` — `theme.selection` color already exists

### Selection coordinate system
Selection uses **screen-space** coordinates (0-based row/col of visible cells), not buffer-space. This means:
- In live mode: screen row == buffer row
- In scrollback mode: screen row != buffer row (offset by startRow)
- For `text(from:to:)` extraction in scrollback, you'd need to add the startRow offset — but v1 is live buffer only

### Testing strategy
- Task 1: Unit tests for `text(from:to:)` (pure model, no UI)
- Task 2-3: Visual verification on simulator (gesture + render integration)
- Full test suite run after each task to catch regressions

### Edit menu flow
```
Long press began  → selectionStart = gridPosition
Long press changed → selectionEnd = gridPosition, renderer.selectionRange updated
Long press ended  → editMenuInteraction.presentEditMenu()
  → editMenuInteraction delegate builds [Copy, Paste] menu
  → User taps Copy → buffer.text(from:to:) → UIPasteboard, clearSelection()
  → User taps Paste → onPaste callback (existing flow)
Tap → clearSelection()
```
