# Terminal Toolbar Redesign — Session/Window/Pane Interaction

**Date:** 2026-03-11
**Status:** Approved

## Overview

Move the terminal toolbar from the top of the screen to above the keyboard area (Termius-style), and introduce a unified interaction model for tmux's Session → Window → Pane hierarchy.

## Current State

- Top toolbar: close (✕), session switcher dropdown (Menu), keyboard toggle (⌨)
- Pane tab bar (iPhone, panes > 1): bottom of pane area, 36pt
- QuickActionButton: floating ⚡ button, half-sheet with tmux commands
- Window layer not exposed in UI
- No way to navigate between windows within a session

## Design

### Toolbar Layout

The toolbar is always visible at the bottom, above the extended keyboard. Terminal content starts from the top of the screen (edge-to-edge).

```
Terminal content (full screen, from status bar)
────────────────────────────────────────────────
⊞ │ [bash│0│1] [vim│0] │ + ⌨       ← toolbar
esc tab ctrl alt ◄ ▲ ▼ ►            ← extended keyboard (always visible)
[system keyboard]                    ← when active
```

**Toolbar elements (left to right):**

| Element | Action |
|---------|--------|
| `square.stack` (SF Symbol) | Toggle to session mode (changes to `xmark` in session mode) |
| Grouped pills | Window/pane navigation (tap to switch) |
| + | Menu: New Window / Split Horizontal / Split Vertical |
| ⌨ | Keyboard toggle |

### Grouped Pills

Windows and panes are displayed as grouped capsules. Each capsule contains the window name on the left and pane indices on the right.

```
┌─────────────────────┐  ┌───────────┐
│ bash │ 0 │ 1 │      │  │ vim │ 0   │
└─────────────────────┘  └───────────┘
  window   pane pane       window pane
```

**Visual states:**
- Active pane: accent background (#B5A8D5) with dark text
- Active window group: outline border (1.5pt accent)
- Inactive window group: dim colors, no outline

**Tap behavior:**
- Tap pane number → `select-window` + `select-pane` (switch to that window and focus pane)
- Tap window name → `select-window` (switch to that window's first pane)

**When pane count is 1 and window count is 1:** Single capsule `[bash│0]` displayed.

**Horizontal scroll:** Pills overflow with horizontal scroll when many windows/panes exist.

### Session Mode

Pressing `square.stack` toggles the pill area to show session pills instead. The icon changes from `square.stack` to `xmark` (close/return).

```
Normal mode:  ⊞ │ [bash│0│1] [vim│0] │ +  ⌨
Session mode: ✕ │ [work] [monitor]   │ +  ⌨
```

**Session pills:** Simple pills with session name. Active session has accent background.

**In session mode:**
- Tap session pill → switch to that session (`switch-client`)
- `+` → New Session
- ✕ → return to normal mode (window/pane pills)

### Long-Press Menus

All destructive and management actions use long-press context menus, providing a uniform pattern:

| Target | Long-press menu |
|--------|----------------|
| Pane number | Zoom / Close Pane |
| Window name | Rename Window / Close Window |
| Session pill | Rename Session / Close Session |

**Zoom** (`resize-pane -Z`): Toggles the pane to fill the entire window area. Useful on iPhone when multiple panes exist.

**Rename Window:** Shows text input alert, sends `rename-window <name>`.

**Rename Session:** Shows text input alert, sends `rename-session <name>`.

**Close actions:** `kill-pane`, `kill-window`, `kill-session` respectively.

### + Menu

Context-dependent popover menu:

**Normal mode (window/pane):**
```
New Window        → new-window
Split Horizontal  → split-window -h
Split Vertical    → split-window -v
```

**Session mode:**
```
New Session       → new-session
```

### Keyboard & Extended Keyboard

- **Always visible:** Both the toolbar and extended keyboard row are always shown at the bottom, even when the system keyboard is hidden
- **⌨ button:** Toggles the system keyboard on/off
- **Extended keyboard row:** esc, tab, ctrl, alt, ◄, ▲, ▼, ► (same as current)
- **Keyboard height tracking:** `.padding(.bottom, keyboardHeight)` pattern maintained

### iPad Layout

Same toolbar as iPhone. Pane pills serve as focus indicators since iPad shows all panes simultaneously:
- Tap pane pill → `select-pane` (change which pane receives keyboard input)
- Active pane highlighted with accent border in the pane container (existing behavior)

### Disconnect

Removed from UI. Rationale:
- tmux sessions persist on the server regardless of client state
- App background/foreground already handles SSH disconnect/reconnect automatically
- Closing the app returns to server list on next launch
- Can be added back as "Switch Server" when multi-server support is implemented

## Removed Components

- **Top toolbar** (HStack in TerminalSessionView): Replaced by bottom toolbar
- **QuickActionButton** (floating ⚡): All actions absorbed into + menu and long-press
- **QuickActionView** (half-sheet): No longer needed
- **Pane tab bar** (iPhone, panes > 1): Replaced by grouped pills

## tmux Commands Required

New commands that need implementation in ConnectionManager:

| Action | tmux Command | Currently Implemented |
|--------|-------------|----------------------|
| select-window | `select-window -t <id>` | ❌ |
| new-window | `new-window` | ✅ (QuickAction) |
| kill-window | `kill-window -t <id>` | ✅ (QuickAction) |
| rename-window | `rename-window <name>` | ✅ (QuickAction) |
| kill-pane | `kill-pane -t <id>` | ✅ (QuickAction) |
| resize-pane -Z | `resize-pane -Z` | ✅ (QuickAction) |
| split-window -h/-v | `split-window -h/-v` | ✅ (QuickAction) |
| rename-session | `rename-session <name>` | ❌ |
| kill-session | `kill-session -t <name>` | ❌ |
| switch-client | `switch-client -t <name>` | ✅ |
| new-session | `new-session` | ✅ |

New tmux control mode notifications to handle:

| Notification | Purpose | Currently Handled |
|-------------|---------|-------------------|
| `%window-renamed` | Update pill window name | ❌ |
| `%window-add` | Add new window pill | ❌ |
| `%window-close` | Remove window pill | ❌ |
| `%unlinked-window-close` | Window closed in another session | ❌ |

## Data Model Changes

ConnectionManager needs to track windows within the current session:

```swift
struct TmuxWindow: Identifiable, Equatable {
    let id: String          // e.g. "@0"
    var name: String        // e.g. "bash", auto-updates
    var panes: [String]     // pane IDs within this window
    var isActive: Bool
}

// New properties on ConnectionManager:
private(set) var currentWindows: [TmuxWindow] = []
private(set) var activeWindowId: String?
```

## Layout Structure (iPhone)

```
┌─────────────────────────────────┐
│                                 │
│     Terminal Pane Content       │  ← from status bar to toolbar
│     (edge-to-edge)             │
│                                 │
├─────────────────────────────────┤
│ ⊞ │ [bash│0│1] [vim│0] │ + ⌨  │  ← toolbar (~44pt)
│ esc tab ctrl alt ◄ ▲ ▼ ►      │  ← extended keyboard (~36pt)
├─────────────────────────────────┤
│ [system keyboard]              │  ← when active
└─────────────────────────────────┘
```
