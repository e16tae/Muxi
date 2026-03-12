# iPhone Pane Auto-Zoom Design

**Date:** 2026-03-12
**Status:** Approved

## Problem

When a tmux window has multiple panes, tmux distributes the total client size among panes via its layout engine. On iPhone, Muxi shows only the active pane (compact layout), but the pane's PTY size is a fraction of the screen (e.g., 40 columns instead of 80). This violates the terminal invariant: **PTY size must equal display size**.

The result: TUI apps render for 40 columns while the user sees an 80-column screen — either half the screen is blank, or cells are stretched and monospace layout breaks.

## Solution

Use tmux's built-in `resize-pane -Z` (zoom) feature to give the active pane the full window dimensions. On iPhone, whenever multiple panes exist, the active pane is **always zoomed**. This is transparent to the user.

### Core Principle

> On iPhone (compact), when a multi-pane window is active, the active pane is always tmux-zoomed.

iPad (regular) behavior is unchanged — all panes displayed simultaneously with proportional scaling.

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Approach | tmux zoom (`resize-pane -Z`) | Maintains PTY == display invariant; standard tmux mechanism |
| iPad behavior | No auto-zoom | Screen is large enough for split view; user can manually `prefix+z` if needed |
| Pane switching | Two sequential commands: `select-pane` then `resize-pane -Z` | `select-pane` does not accept `-Z`; two commands via control channel are serialized by tmux |
| Auto-zoom policy | Always zoomed on iPhone when pane count > 1 | Consistent experience; no user action needed |
| Manual unzoom (`prefix+z`) | Auto re-zoom on iPhone | Unzoomed state has no valid iPhone UX; likely a desktop habit |
| Zoom on attach | Yes, if multi-pane | Session may already have splits from a previous client |

## Pane State Preservation During Zoom

### The Problem

When tmux zooms a pane, `%layout-change` reports **only the zoomed pane**. The current `onLayoutChange` handler:
1. Overwrites `currentPanes` with just the zoomed pane
2. Removes `paneBuffers` for panes not in the layout
3. Updates `currentWindows[].paneIds` to contain only 1 pane

This destroys all non-active pane state, breaking pane switching and zoom detection.

### Solution: Separate "known panes" from "layout panes"

Introduce `windowKnownPaneIds: [String: Set<String>]` — a per-window map of all known pane IDs, updated independently of `%layout-change`:

- **Grows** when: unzoomed `%layout-change` shows new pane IDs, or `%pane-mode-changed` / output arrives for a pane not yet known
- **Shrinks** when: `%unlinked-window-close` or explicit pane removal detected (pane disappears from an **unzoomed** layout)
- **Never modified** by a zoomed `%layout-change` (which only reports the zoomed pane)

#### Modified `onLayoutChange` behavior

```
onLayoutChange(windowId, layoutPanes):
    knownCount = windowKnownPaneIds[windowId]?.count ?? 0
    layoutCount = layoutPanes.count

    if layoutCount == 1 && knownCount > 1:
        // ZOOMED: only update the zoomed pane's buffer size
        isZoomed = true
        let zoomedId = "%\(layoutPanes[0].paneId)"
        paneBuffers[zoomedId]?.resize(cols: layoutPanes[0].width, rows: layoutPanes[0].height)
        // Do NOT overwrite currentPanes, do NOT remove other buffers
        // Do NOT update currentWindows[].paneIds
    else:
        // UNZOOMED or SINGLE-PANE: normal processing
        isZoomed = false
        currentPanes = layoutPanes
        windowKnownPaneIds[windowId] = Set(layoutPanes.map { "%\($0.paneId)" })
        // Create/resize buffers, remove stale buffers (existing logic)
        // Update currentWindows[].paneIds
```

#### Toolbar pane list source

The toolbar pane pills read from `windowKnownPaneIds[activeWindowId]` (not `currentPanes`) when `isZoomed == true`. This preserves the full pane list for switching even while zoomed.

## Zoom Trigger Points

| Event | Action |
|-------|--------|
| Attach to multi-pane window | `resize-pane -Z -t %<activePaneId>` |
| Pane switch (toolbar pill tap) | `select-pane -t %N` then `resize-pane -Z -t %N` (two commands) |
| Split detected (knownPaneIds count increases) | Zoom new active pane |
| Pane closed, 1 pane remaining | No action needed — tmux auto-unzooms single pane |
| User manually unzooms (`prefix+z`) | Detect via `%layout-change` (layout shows multiple panes), auto re-zoom |
| Window switch to multi-pane window | Detect via `onLayoutChange`, auto-zoom |
| Size class changes compact → regular | Unzoom via `resize-pane -Z` (only if `isZoomed == true`) |
| Size class changes regular → compact | Zoom if multi-pane |
| Session switch | `onSessionChanged` clears all state; new `%layout-change` triggers `ensureZoomIfNeeded()` |

## Zoom State Detection

Zoom status is determined by comparing layout pane count to known pane count:

- **Zoomed**: `layoutPaneCount == 1 && windowKnownPaneIds[windowId].count > 1`
- **Unzoomed**: `layoutPaneCount == windowKnownPaneIds[windowId].count` (or no known panes yet)

```
zoomed:   %layout-change @0 abcd,80x24,0,0,5           ← 1 pane in layout
unzoomed: %layout-change @0 abcd,80x24,0,0{40x24,...}   ← 2+ panes in layout
```

### `resize-pane -Z` is a toggle

`resize-pane -Z` toggles zoom state — it does NOT idempotently "zoom on". To prevent accidental unzoom:

1. **Always check `isZoomed` before sending**: only send `resize-pane -Z` when `isZoomed == false`
2. **`pendingZoom` guard**: set `true` when zoom command sent, cleared on next zoomed `%layout-change`
3. **Unzoom transition (compact → regular)**: only send `resize-pane -Z` when `isZoomed == true`

This ensures we never toggle in the wrong direction.

### Re-zoom loop prevention

```
ensureZoomIfNeeded():
    guard isCompact else { return }
    guard (windowKnownPaneIds[activeWindowId]?.count ?? 0) > 1 else { return }
    guard !isZoomed else { return }
    guard !pendingZoom else { return }

    pendingZoom = true
    sendControlCommand("resize-pane -Z -t \(activePaneId.shellEscaped())")
```

## Data Flow

```
[Attach / Pane switch / Split / Manual unzoom]
    |
    v
ConnectionManager: isCompact + knownPaneCount > 1 + !isZoomed + !pendingZoom?
    |
    | yes
    v
sendControlCommand("resize-pane -Z -t %N")
    |
    v
tmux: zoomed pane gets full window size (80x24)
    |
    v
%layout-change -> 1 pane in layout, full size
    |
    v
onLayoutChange: detects zoomed state, updates only active buffer size
    |
    v
TerminalBuffer(cols: 80, rows: 24)
    |
    v
iPhone compactLayout: full-screen render of 80x24 buffer (correct)
```

## Code Paths to Modify

### ConnectionManager — New Properties

- `isCompact: Bool` — set by TerminalSessionView when sizeClass changes
- `isZoomed: Bool` — derived from layout vs known pane count in `onLayoutChange`
- `pendingZoom: Bool` — re-zoom loop guard
- `windowKnownPaneIds: [String: Set<String>]` — per-window known pane IDs (survives zoom)

### ConnectionManager — New Methods

- `ensureZoomIfNeeded()` — called after layout-change, attach, and sizeClass change. Sends `resize-pane -Z` if conditions met.
- `ensureUnzoomIfNeeded()` — called on compact → regular transition. Sends `resize-pane -Z` only if `isZoomed == true`.

### ConnectionManager — Modified Methods

- `onLayoutChange` callback: add zoomed-state detection branch (see "Modified `onLayoutChange` behavior" above)
- `selectWindowAndPane()`: append `resize-pane -Z -t %N` when `isCompact` (all three code paths)
- `onSessionChanged`: clear `windowKnownPaneIds`, `isZoomed`, `pendingZoom`

### Pane Switch Code Paths (all three must be updated)

1. **`TerminalSessionView.onPaneTapped`** (line 61): currently calls `sendTmuxCommand("select-pane -t \(paneId)")` directly. Must also send `resize-pane -Z` when `isCompact`. Alternatively, route through ConnectionManager.
2. **`ConnectionManager.selectWindowAndPane()` — same-window branch** (line 729): add `resize-pane -Z -t %N` after `select-pane`.
3. **`ConnectionManager.selectWindowAndPane()` — cross-window branch** (line 723): add `resize-pane -Z -t %N` after `select-pane`.

### TerminalSessionView

- Pass `horizontalSizeClass` to ConnectionManager via `.onChange(of: sizeClass)` → `connectionManager.isCompact = (sizeClass == .compact)`
- Initial value set in `.onAppear`

### PaneContainerView

- No changes needed (compact layout already shows only active pane)

### ToolbarView

- When `isZoomed`, read pane list from `connectionManager.windowKnownPaneIds[activeWindowId]` instead of `currentPanes`

### TmuxControlService / C Parser

- No changes needed (`%layout-change` parsing already works)

### Security

All pane IDs in zoom/select commands must use `shellEscaped()` consistent with project security rules.

## Edge Cases

| Case | Handling |
|------|----------|
| iPhone to iPad transition (Stage Manager, external display) | sizeClass change detected → `ensureUnzoomIfNeeded()` (only if `isZoomed == true`) |
| Network latency delays `%layout-change` after zoom command | `pendingZoom` guard prevents duplicate sends |
| Another tmux client attached to same session | Zoom is window-level state — other client sees zoomed state too. Standard tmux behavior, no special handling. |
| Window switch to window with splits | `onLayoutChange` fires → `ensureZoomIfNeeded()` handles it |
| tmux version < 1.8 | Already blocked by `TmuxError.versionMeetsMinimum()` (minimum 1.8, zoom available since 1.8) |
| Single-pane window | `knownPaneCount <= 1` → no zoom action taken |
| Rapid pane switches | `pendingZoom` guard + tmux serializes commands on control channel |
| Session switch | `onSessionChanged` clears all zoom state; new `%layout-change` triggers fresh `ensureZoomIfNeeded()` |
| Intermediate `%layout-change` between `select-pane` and `resize-pane -Z` | Unzoomed layout arrives → `ensureZoomIfNeeded()` fires → but `pendingZoom` may already be set from the `resize-pane -Z` just sent. If not yet sent (pane switch is two commands), the layout triggers zoom naturally. |

## Testing Strategy

### Unit Tests (Swift Testing)

**Zoom logic:**
- `ensureZoomIfNeeded()`: verify zoom command sent when isCompact + multi-pane + !isZoomed + !pendingZoom
- `ensureZoomIfNeeded()`: verify no command when iPad (isCompact = false)
- `ensureZoomIfNeeded()`: verify no command when single pane
- `ensureZoomIfNeeded()`: verify no command when already zoomed
- `ensureZoomIfNeeded()`: verify no command when pendingZoom = true

**Zoom state detection:**
- Layout with 1 pane + known count > 1 → isZoomed = true
- Layout pane count == known count → isZoomed = false

**Pane state preservation:**
- After zoomed `%layout-change`, `paneBuffers` still contains all known pane IDs
- After zoomed `%layout-change`, `windowKnownPaneIds` unchanged
- After unzoomed `%layout-change`, `windowKnownPaneIds` updated to match layout
- After zoomed `%layout-change`, toolbar data source still lists all panes

**Size class transitions:**
- compact → regular triggers unzoom (only if isZoomed)
- regular → compact triggers zoom (if multi-pane)
- compact → regular when !isZoomed sends no command

**Toggle safety:**
- `resize-pane -Z` not sent when already zoomed (prevents accidental unzoom)
- `resize-pane -Z` (unzoom) not sent when already unzoomed

### Integration Tests (manual)

- Connect to server with existing multi-pane session on iPhone → pane fills screen
- Split pane on iPhone → new pane auto-zooms to full screen
- Switch pane via toolbar → smooth transition, no flicker, both panes remain in pill list
- Close pane until 1 remains → normal single-pane view
- `prefix+z` in terminal → briefly unzooms then re-zooms
- Same session on iPad → all panes visible, no auto-zoom
- Rotate iPad to compact mode (split view) → auto-zoom activates
