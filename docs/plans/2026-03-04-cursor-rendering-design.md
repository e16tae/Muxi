# Cursor Rendering Design

## Goal

Render a block cursor at the current cursor position by inverting fg/bg colors of the cursor cell.

## Approach

In `TerminalRenderer.rebuildVertices()`, when processing the cell at `(buffer.cursorRow, buffer.cursorCol)`, swap the fg and bg colors. This makes the cursor visible as a color-inverted block without adding extra vertices or shader changes.

## Files

- Modify: `ios/Muxi/Terminal/TerminalRenderer.swift` — swap fg/bg at cursor position in rebuildVertices()

## Details

- No blink (on-demand rendering, battery friendly). Blink can be added later as a setting.
- No separate cursor quad — reuse existing cell vertex with swapped colors.
- `Theme.cursor` color is not used (fg↔bg swap is sufficient for block cursor).
- No new shaders needed.
- `accessibilityReduceMotion` not relevant (no animation).

## Out of Scope

- Cursor blink (future setting)
- Cursor style options (underline, bar)
- Cursor hide/show based on VT escape sequences
