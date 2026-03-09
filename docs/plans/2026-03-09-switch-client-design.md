# Session Switching via `switch-client`

**Date**: 2026-03-09
**Status**: Approved

## Problem

`ConnectionManager.switchSession()` tears down the SSH shell channel and creates a new one with `tmux -CC attach`. This causes a visible "Attaching to..." loading state on every session switch, even though the tmux control mode channel can switch sessions in-place.

## Design

Replace the detach-reattach cycle with `switch-client -t <session>`, sent through the existing control mode channel.

### Flow

```
switchSession("work")
  → clear scrollback state (not pane buffers)
  → send "switch-client -t work\n" via activeChannel
  → tmux responds with events:
      %session-changed $2 work
      %layout-change @3 <new-layout>
      %output %5 <content>
  → onSessionChanged: update state to .attached(work), save last-used
  → onLayoutChange: creates new pane buffers, removes old (existing logic)
  → onPaneOutput: feeds content to new panes (existing logic)
```

### Changes

1. **`ConnectionManager.wireCallbacks()`** — Wire `onSessionChanged` to update `state`, save last-used session via `LastSessionStore`, and send `refresh-client` to ensure correct terminal size.

2. **`ConnectionManager.switchSession()`** — Replace channel teardown with:
   - Cancel pending scrollback continuation
   - Clear scrollback state (`scrolledBackPanes`, `paneHasNewOutput`)
   - Reset `capturePaneQueue`
   - Send `switch-client -t <session>\n` through existing channel
   - Set `pendingInitialResize = true` (first layout triggers capture-pane after resize)
   - Do NOT clear `paneBuffers` or `currentPanes` (tmux events handle this)
   - Do NOT close/reopen SSH channel

3. **No changes needed to**: `TmuxControlService` (already parses `%session-changed`), `onLayoutChange` handler (already creates/removes pane buffers), `TerminalSessionView` (reacts to state/pane changes).

### Error Handling

- `switch-client` failure → tmux sends `%error` → existing `onError` logs it → current session unchanged
- No rollback needed since we don't tear down the channel

### Edge Cases

- **Pane ID safety**: tmux pane IDs are server-global, no collision across sessions
- **In-flight output**: Old session `%output` may arrive after `switch-client` is sent. Safe because pane IDs are unique — output goes to correct (soon-to-be-removed) buffer
- **Scrollback state**: Keyed by pane ID, orphaned entries from old session are harmless
- **`activePaneId`**: Existing `onChange(of: panes)` in TerminalSessionView handles stale pane IDs
