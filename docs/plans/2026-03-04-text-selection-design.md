# Text Selection & Copy Design

## Goal

Add text selection and copy to the terminal. Long press to start selection, drag to extend, edit menu to copy. Pure client-side — no tmux involvement for copy.

## Approach: Coordinator-Based Selection

All selection state lives in `TerminalView.Coordinator`. Visual highlight via TerminalRenderer's `rebuildVertices()` bgColor override — no Metal shader changes.

## Gesture Flow

```
Long press .began  → record anchor (row, col), enter selection mode
Long press .changed → update selection end (row, col) from touch, redraw
Long press .ended  → show UIEditMenuInteraction (Copy + Paste)
Tap anywhere       → clear selection
```

The existing long press gesture changes from "immediately show paste menu" to "start selection mode". The edit menu appears when the user lifts their finger, now offering both Copy and Paste.

## Visual Highlight

TerminalRenderer gets a `selectionRange` property: `(start: (row: Int, col: Int), end: (row: Int, col: Int))?`. In `rebuildVertices()`, selected cells get their `bgColor` overridden with a theme-derived selection color (accent with reduced opacity). The existing fragment shader (`mix(bgColor, fgColor, alpha)`) handles the rest — no shader changes needed.

## Coordinate Mapping

Touch point → buffer position:
```
col = clamp(Int(touch.x / cellWidth), 0, cols - 1)
row = clamp(Int(touch.y / cellHeight), 0, rows - 1)
```

`cellWidth` needs to be cached in Coordinator alongside `cellHeight`.

## Text Extraction

New `TerminalBuffer.text(from:to:) -> String` method:
- Iterates cells from start to end position
- Skips wide-char continuation cells (width == 0)
- Trims trailing whitespace per line
- Joins lines with `\n`

## Edit Menu

Extend the existing `UIEditMenuInteraction` delegate:
- Selection active: **Copy** (writes to `UIPasteboard.general.string`) + **Paste**
- No selection: **Paste** only (current behavior)
- Copy clears selection after copying

## Affected Components

| Component | Change |
|-----------|--------|
| TerminalView.Coordinator | Selection state, gesture handling, edit menu |
| TerminalRenderer | `selectionRange` property, bgColor override in rebuildVertices() |
| TerminalBuffer | `text(from:to:)` range extraction method |

## Out of Scope

- Double-tap word selection
- Select All
- iOS-style selection handles
- Selection in scrollback mode (live buffer only for v1)
- Selection across panes
