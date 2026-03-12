# Window Switching: Optimistic Update + Contextual Placeholder

**Date**: 2026-03-12
**Status**: Approved

## Problem

Tapping a different window pill in the toolbar does not switch the terminal view.

**Root cause**: `selectWindow()` sends `select-window` to tmux but does not update local state (`activeWindowId`, `currentPanes`, `activePaneId`). The UI relies entirely on `%layout-change` notifications from tmux to reflect the switch, and the stale panes from the previous window remain visible during the gap.

## Decision

**Approach A (Optimistic Update)** with **Option B (contextual placeholder message)**.

- Immediately update `activeWindowId` and clear `currentPanes` on window switch.
- Show a placeholder with contextual message ("Switching window..." vs "Attaching to {session}...").
- Same-window pane switching updates `activePaneId` only — no placeholder.

## Design

### New State

```swift
// ConnectionManager
private(set) var switchingToWindowId: String?
```

- Set when a window switch begins.
- Cleared when `onLayoutChange` delivers the target window's panes.

### Window Switch Flow (different window)

```
1. Guard: windowId != activeWindowId (skip if same)
2. switchingToWindowId = targetWindowId
3. activeWindowId = targetWindowId      → pill highlight switches immediately
4. currentPanes = []                    → terminal area shows placeholder
5. activePaneId = nil
6. scrolledBackPanes = []               → clear stale scrollback state
7. sendControlCommand("select-window -t \(windowId.shellEscaped())")
8. %layout-change received (windowId == switchingToWindowId)
   → currentPanes restored, switchingToWindowId = nil
```

### onLayoutChange Guard

When `switchingToWindowId` is set, ignore `%layout-change` events whose `windowId` does not match `switchingToWindowId`. This prevents a stale layout-change (from the previous window) from prematurely clearing the transition state during rapid taps.

```swift
if let target = switchingToWindowId, windowId != target {
    return  // ignore stale layout-change
}
```

### Same-Window Pane Switch Flow

```
1. isKeyboardActive = true              → show keyboard (existing behavior, TerminalSessionView)
2. activePaneId = targetPaneId          → focus switches immediately
3. sendControlCommand("select-pane -t \(paneId.shellEscaped())")
   (no placeholder, currentPanes unchanged)
```

### Placeholder Message Branching

| Condition | Message |
|-----------|---------|
| `switchingToWindowId != nil` | "Switching window..." |
| Otherwise (initial attach) | "Attaching to {session}..." |

`ProgressView` spinner is shared.

### selectWindowAndPane (cross-window pane tap)

When a pane in a different window is tapped:
```
1. Same as window switch flow (steps 1-8)
2. Additionally send: select-pane -t \(paneId.shellEscaped())
   (activePaneId will be set by onLayoutChange, not optimistically,
    because the pane IDs in the new window may differ)
```

### TerminalSessionView Callback Changes

**onSelectWindow** — all state management moves into `ConnectionManager.selectWindow()`:
```swift
// Before (current):
onSelectWindow: { windowId in
    Task { try? await connectionManager.selectWindow(windowId) }
}

// After:
onSelectWindow: { windowId in
    Task { try? await connectionManager.selectWindow(windowId) }
}
// (same call, but CM now handles optimistic state internally)
```

**onSelectWindowAndPane** — remove direct `activePaneId` assignment from TerminalSessionView:
```swift
// Before (current):
onSelectWindowAndPane: { windowId, paneId in
    isKeyboardActive = true
    connectionManager.activePaneId = paneId  // ← REMOVE
    Task { try? await connectionManager.selectWindowAndPane(...) }
}

// After:
onSelectWindowAndPane: { windowId, paneId in
    isKeyboardActive = true
    Task { try? await connectionManager.selectWindowAndPane(...) }
}
// (activePaneId managed by CM via onLayoutChange)
```

## Edge Cases

- **Same window tapped again**: `windowId == activeWindowId` → no-op.
- **Rapid successive taps**: `switchingToWindowId` overwritten to latest target. `onLayoutChange` guard ignores stale responses; only the matching `%layout-change` clears the transition.
- **Transition timeout**: No explicit timeout. SSH disconnect triggers reconnect which resets all state naturally.
- **paneBuffers on switch**: Existing `onLayoutChange` logic removes buffers for panes not in the new `currentPanes`. This means switching back to a previous window will re-capture via `capture-pane`. This is acceptable — buffers are recreated naturally.
- **Scrollback state**: `scrolledBackPanes` cleared in step 6. `TerminalSessionView.scrollbackState` entries for old panes become inert (keyed by pane ID, no matching panes to render). Cleared naturally when new panes arrive.

## Files Changed

| File | Change |
|------|--------|
| `ConnectionManager.swift` | Add `switchingToWindowId`; update `selectWindow()`/`selectWindowAndPane()` with optimistic state + pane clear + scrollback clear; add guard in `onLayoutChange` to ignore stale layout-change during switch; clear `switchingToWindowId` on matching layout-change |
| `TerminalSessionView.swift` | Branch `placeholderView` message based on `switchingToWindowId`; remove direct `activePaneId` assignment from `onSelectWindowAndPane` callback |
