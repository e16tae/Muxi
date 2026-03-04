# Clipboard Paste Design

## Goal

Long-press on the terminal view shows an iOS native edit menu with a "Paste" option. Tapping Paste sends clipboard text to the active tmux pane via `set-buffer` + `paste-buffer`.

## Approach

Add `UIEditMenuInteraction` (iOS 16+) to the `MTKView` in `TerminalView`. On long-press, present the edit menu with a Paste action. The action reads `UIPasteboard.general.string`, escapes it for tmux's double-quote parser, and sends two tmux commands in a single write.

## tmux Command

```
set-buffer -b ios_paste -- "escaped text"\npaste-buffer -b ios_paste -t %N -d\n
```

- Named buffer `ios_paste` avoids clobbering the user's global paste buffer.
- `-d` deletes the named buffer after pasting.
- `paste-buffer` automatically wraps with bracketed paste sequences (`\e[200~...\e[201~`) if the pane's application has enabled bracketed paste mode.

## tmux Escaping (`tmuxQuoted()`)

A new `String.tmuxQuoted()` function escapes text for tmux double-quoted strings. This is NOT `shellEscaped()` — the command goes directly to tmux's control mode parser, not a shell.

| Original | Escaped | Reason |
|----------|---------|--------|
| `\` | `\\` | tmux escape char |
| `"` | `\"` | string delimiter |
| `$` | `\$` | variable expansion |
| newline (0x0A) | `\n` | literal two-char |
| CR (0x0D) | `\r` | literal two-char |
| tab (0x09) | `\t` | literal two-char |
| ESC (0x1B) | `\e` | literal two-char |
| other control chars | `\uXXXX` | no named escape |
| `#` | no escape | `set-buffer` does not expand format strings |
| UTF-8 | passthrough | tmux handles UTF-8 natively |

## Files

- Create: `ios/Muxi/Extensions/String+TmuxEscape.swift` — `tmuxQuoted()` function
- Modify: `ios/Muxi/Views/Terminal/TerminalView.swift` — add `UIEditMenuInteraction`, `UILongPressGestureRecognizer`, `onPaste` callback
- Modify: `ios/Muxi/Views/Terminal/PaneContainerView.swift` — pass `onPaste` through
- Modify: `ios/Muxi/Views/Terminal/TerminalSessionView.swift` — add `pasteToActivePane()` using `sendTmuxCommand()`
- Create: `ios/MuxiTests/TmuxEscapeTests.swift` — unit tests for `tmuxQuoted()`

## Callback Path

```
TerminalView.Coordinator (UIEditMenuInteraction delegate)
  → onPaste(clipboardText)
    → PaneContainerView
      → TerminalSessionView.pasteToActivePane(text)
        → sendTmuxCommand("set-buffer ...\npaste-buffer ...")
          → SSH channel write
```

## Details

- Empty clipboard (`UIPasteboard.general.string == nil`): Paste menu item not shown.
- Gesture coexistence: SwiftUI `onTapGesture` (PaneContainerView) + UIKit `UILongPressGestureRecognizer` (MTKView) work on different layers, no conflict.
- iPad multi-pane: paste targets `activePaneId`. User taps pane first to select, then long-presses to paste.
- iOS paste permission banner: system-handled, no custom UI needed.
- Two tmux commands combined in single SSH write for atomicity.

## Out of Scope

- Copy (requires text selection — separate feature)
- Paste size limit / chunking
- Paste to non-active pane via pane-aware callback
