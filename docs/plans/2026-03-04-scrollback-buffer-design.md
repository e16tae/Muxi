# Scrollback Buffer Design

## Goal

Allow users to swipe up on the terminal to view past output that has scrolled off screen, using tmux's server-side history via `capture-pane`.

## Approach: tmux On-Demand

Fetch scrollback history from tmux when the user scrolls up, cache it locally in a temporary TerminalBuffer, and render with the existing Metal renderer. No local persistent history storage — tmux manages all history server-side.

## Flow

```
User swipes ↑
  → UIPanGestureRecognizer detects vertical pan
  → ScrollbackState transitions to .loading
  → Show loading indicator overlay
  → ConnectionManager sends: capture-pane -e -p -S -500 -t %<paneId>
  → Response received (ANSI text with colors)
  → Feed into temporary TerminalBuffer (500 rows × current cols)
  → ScrollbackState transitions to .scrolling(offset, cache, totalLines)
  → Renderer reads from cache buffer at current offset
  → User scrolls within cached range → offset changes only (no SSH)
  → User scrolls beyond cache → fetch more (-S -1000)

User swipes ↓ (reaches bottom)
  → scrollOffset = 0
  → ScrollbackState transitions to .live
  → Cache buffer released
  → Resume live rendering
```

## ScrollbackState

```swift
enum ScrollbackState {
    case live                    // Normal mode — render live buffer
    case loading                 // capture-pane request in flight
    case scrolling(
        offset: Int,             // Lines scrolled back from bottom
        cache: TerminalBuffer,   // Captured history buffer
        totalLines: Int          // Total lines in cache
    )
}
```

## Components

| Component | Responsibility |
|-----------|---------------|
| UIPanGestureRecognizer | Detect vertical swipe on MTKView |
| ScrollbackState | Per-pane state: .live / .loading / .scrolling |
| ConnectionManager.fetchScrollback() | Send capture-pane, parse response, create cache buffer |
| Temporary TerminalBuffer | Cache for captured history, reuses VT parser for ANSI parsing |
| TerminalRenderer (modified) | Accept displayRange parameter, render only visible window |
| "↓ New output" indicator | SwiftUI overlay when new output arrives while scrolled back |

## Renderer Modification

Current renderer always iterates rows 0..buffer.rows. Modified renderer accepts a display range:

```swift
func rebuildVertices(displayRange: Range<Int>? = nil) {
    let range = displayRange ?? (0..<buffer.rows)
    // Only generate vertices for rows in range
}
```

This renders only the visible ~24 rows from the 500-row cache buffer — no performance concern.

## Scroll Physics

- Use UIPanGestureRecognizer velocity for inertia scrolling
- CADisplayLink for deceleration animation
- Scroll amount = velocity × factor, decelerating over time
- Snap to whole lines for clean rendering

## Edge Cases

- **New output while scrolled back**: Live buffer continues receiving data but not rendered. Show "↓ New output" indicator. Tapping it returns to live mode.
- **Cache exhausted**: If user scrolls beyond 500-line cache, fetch more with `-S -1000`. If tmux has no more history, stop scrolling.
- **Empty history**: New sessions with no scrollback → ignore scroll gesture.
- **Pane switch**: Scrollback state is per-pane. Switching panes resets to live mode.
- **Resize while scrolled**: Exit scrollback mode, return to live.
- **capture-pane color fidelity**: `-e` flag preserves ANSI escapes. Attributes set before the captured range may be lost — acceptable limitation.

## tmux Dependency

- Scrollback depth depends on tmux's `history-limit` setting (default 2000 lines)
- Muxi does NOT modify this setting (respects user's tmux config)

## Files

- Create: `ios/Muxi/Terminal/ScrollbackState.swift` — state enum
- Modify: `ios/Muxi/Terminal/TerminalView.swift` — add pan gesture recognizer
- Modify: `ios/Muxi/Terminal/TerminalRenderer.swift` — add displayRange support
- Modify: `ios/Muxi/Terminal/TerminalBuffer.swift` — scrollback cache buffer support
- Modify: `ios/Muxi/Services/ConnectionManager.swift` — fetchScrollback() method
- Modify: `ios/Muxi/Views/Terminal/PaneContainerView.swift` — new output indicator overlay

## Out of Scope

- tmux copy mode integration
- Text search within scrollback
- Local persistent history storage
- Pinch zoom
- Pre-fetching scrollback on pane attach (future optimization)
