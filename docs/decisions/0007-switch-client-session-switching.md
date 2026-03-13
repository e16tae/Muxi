# ADR-0007: In-place session switching via `switch-client`

## Status

Accepted

## Date

2026-03-09

## Context

When a user taps a different session pill in the toolbar, the app must switch the tmux control mode connection to the new session. The original implementation tore down the SSH shell channel and created a new one with `tmux -CC attach -t <session>`, causing a visible "Attaching to..." loading state on every switch.

## Decision

Use `switch-client -t <session>` sent through the existing tmux control mode channel. The SSH connection and channel remain open. tmux responds with structured events (`%session-changed`, `%layout-change`, `%output`) that the existing handlers process.

Flow:
1. Clear scrollback state (not pane buffers)
2. Send `switch-client -t <session>\n` via active channel
3. tmux fires `%session-changed` → update state, save last-used session
4. tmux fires `%layout-change` → create new pane buffers, remove old
5. tmux fires `%output` → feed content to new panes

Error handling: `switch-client` failure → tmux sends `%error` → existing handler logs it → current session unchanged. No rollback needed since the channel was never torn down.

## Alternatives Considered

### Detach-reattach cycle

Detach from current session, close SSH channel, open new channel, run `tmux -CC attach -t <session>`.

Rejected because:
- Visible loading state ("Attaching to...") on every session switch
- Wastes time re-establishing SSH channel when the connection is healthy
- Race conditions during channel teardown/creation (monitor task, pending commands)
- More code to manage (channel lifecycle, state reset)

## Consequences

- (+) Instant session switching — no loading state, no SSH channel churn
- (+) Simpler code — no channel teardown/creation logic for switches
- (+) Existing `%session-changed` / `%layout-change` handlers do all the work
- (-) In-flight `%output` from old session may arrive after switch — safe because pane IDs are server-global, but pane buffers for old session are briefly kept until `%layout-change` replaces them
- (-) Must clear scrollback state and pending command queue to prevent stale data
