# ADR-0001: Use tmux control mode (`-CC`) for session management

## Status

Accepted

## Date

2026-02-28

## Context

Muxi needs to manage tmux sessions, windows, and panes on a remote server via SSH. The app must render each pane as an independent native iOS view with its own Metal renderer. Two approaches exist for interfacing with tmux from a client.

## Decision

Use tmux control mode (`tmux -CC attach`) which provides structured protocol output (`%begin/%end`, `%output %N`, `%layout-change`, `%session-changed`, etc.) instead of parsing raw terminal escape sequences from a PTY.

## Alternatives Considered

### Raw PTY parsing

Connect to the server, run `tmux attach`, and parse the full terminal output stream — including tmux's own status bar, pane borders, and escape sequences — to reconstruct session/window/pane state.

Rejected because:
- Requires reverse-engineering tmux's visual rendering to extract pane boundaries
- Pane content is interleaved in a single byte stream with no structural delimiter
- tmux UI elements (status bar, pane borders) would need to be stripped
- Any tmux configuration change (status bar format, border style) breaks parsing

## Consequences

- (+) Pane output is delivered with explicit pane IDs (`%output %5 ...`) — direct mapping to native views
- (+) Session/window/pane lifecycle events are structured notifications — no screen scraping
- (+) tmux manages all state (session list, window layout, pane dimensions) — client complexity reduced
- (-) Requires implementing a tmux control mode protocol parser (`tmux_protocol` C library)
- (-) Depends on tmux 1.8+ (control mode introduction) — older servers unsupported
- (-) Some tmux features have undocumented control mode behavior (e.g., `%begin/%end` notification interleave)
