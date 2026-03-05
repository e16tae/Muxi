# Hardware Keyboard Design

## Goal

Add hardware keyboard support to the terminal. Arrow keys, Escape, Tab, Delete, Ctrl+letter, and Alt+letter — covers 95% of terminal use. No function keys or Cmd shortcuts in v1.

## Approach: UIKeyCommand on TerminalInputAccessor

`TerminalInputAccessor` (the invisible `UIKeyInput` view) already handles software keyboard input via `insertText` and `deleteBackward`. Adding `keyCommands` to this view captures hardware key events with automatic key repeat, no duplicate input with `insertText`, and no suppression flag complexity.

## Key Mapping

| Key | Count | Handling |
|-----|-------|----------|
| Arrow keys (Up/Down/Left/Right) | 4 | Map to existing `SpecialKey` → `onSpecialKey` callback |
| Escape | 1 | Map to `SpecialKey.escape` → `onSpecialKey` callback |
| Tab | 1 | Map to `SpecialKey.tab` → `onSpecialKey` callback, `wantsPriorityOverSystemBehavior = true` |
| Ctrl+a...z | 26 | `InputHandler.terminalData(for:ctrl:true)` → `onRawData` callback |
| Alt+a...z | 26 | `InputHandler.terminalData(for:alt:true)` → `onRawData` callback |
| Regular characters | — | Unchanged — `insertText` handles (software + hardware) |
| Delete/Backspace | — | Unchanged — `deleteBackward` handles |
| Enter/Return | — | Unchanged — `insertText("\n")` handles |

Total: ~58 UIKeyCommand entries, generated in a loop, cached as a static lazy property.

## Why UIKeyCommand over pressesBegan

| Concern | UIKeyCommand | pressesBegan |
|---------|-------------|-------------|
| Key repeat | Automatic | Must implement timer |
| Duplicate with insertText | Captures first, no duplicate | Both fire, need suppression flag |
| Modifier handling | Declarative via modifierFlags | Manual flag checking |
| Edge cases | Few | Stale suppression flag, timing |
| Enumeration | Must list all keys (~58) | Handles all keys automatically |

UIKeyCommand wins on reliability. The enumeration cost is trivial with loop generation.

## Callback Structure

Existing callbacks (unchanged):
- `onText?(String)` — regular characters from software/hardware keyboard
- `onDelete?()` — backspace
- `onSpecialKey?(SpecialKey)` — arrows, escape, tab (reused by hardware key commands)

New callback:
- `onRawData?(Data)` — Ctrl/Alt+letter terminal bytes, bypasses InputHandler toggle state

## InputHandler Changes

Add a static pure function for hardware keyboard modifier translation:

```swift
static func terminalData(
    for character: String,
    ctrl: Bool = false,
    alt: Bool = false
) -> Data
```

This does not touch `ctrlActive`/`altActive` toggle state (which remains for ExtendedKeyboardView's sticky modifier buttons).

## System Interaction

- **Tab**: `wantsPriorityOverSystemBehavior = true` prevents iOS focus navigation. Correct for terminal input.
- **Escape**: Only captured when TerminalInputAccessor is first responder. Sheets/popovers use a different responder, so no conflict.
- **Discoverability overlay**: No `discoverabilityTitle` set in v1 — commands work but don't appear in the Cmd-hold overlay.
- **ExtendedKeyboardView**: Unchanged. Software buttons and hardware keys coexist independently.

## Affected Components

| Component | Change |
|-----------|--------|
| TerminalInputAccessor | Add `keyCommands` override + `handleKeyCommand` |
| InputHandler | Add static `terminalData(for:ctrl:alt:)` method |
| TerminalSessionView | Wire `onRawData` callback to `sendToActivePane` |
| Tests | Unit tests for `terminalData` + key command mapping |

## Out of Scope

- Function keys (F1-F12)
- Cmd shortcuts (Cmd+C/V — let iOS handle)
- Home/End/PgUp/PgDn via hardware (available via ExtendedKeyboardView)
- Discoverability overlay titles
- Ctrl+[ (Escape alias), Ctrl+Space (NUL)
