# Graceful Re-attach on tmux Session Exit

**Date:** 2026-03-09
**Status:** Approved

## Problem

When a user types `exit` in their last tmux window, the session is destroyed and tmux sends `%exit` via control mode. Currently, the `onExit` handler calls `reconnect()`, which:

1. Tears down the SSH connection entirely
2. Re-establishes SSH with exponential backoff
3. Queries remaining sessions
4. Re-attaches

This is wasteful — the SSH session is still alive after `%exit`. We should reuse it.

## Design

### New function: `reattach()`

A lightweight alternative to `reconnect()` that keeps the SSH connection alive.

**Flow:**
```
%exit received
  → cancel sshMonitorTask
  → set activeChannel = nil
  → reset tmux line buffer, pane buffers, pending commands, UI state
  → refreshSessions() (now passes activeChannel == nil guard)
  → sessions found?
      YES → pick target (last-used > first available) → performAttach()
      NO  → disconnect() (back to server list)
  → on error → fallback to reconnect()
```

### Changes

**File:** `ios/Muxi/Services/ConnectionManager.swift`

1. **Add `reattach()` method** — cleans up control mode state without touching SSH, queries sessions, re-attaches or disconnects.

2. **Modify `onExit` handler** — call `reattach()` instead of `reconnect()`.

### Error handling

If `reattach()` fails (e.g., SSH connection died simultaneously), fall back to `reconnect()` which handles full re-establishment with backoff.

### No sessions remaining

Disconnect entirely — return to server list. Consistent with user's explicit choice.

## Scope

- Single file change (`ConnectionManager.swift`)
- No new UI elements
- No protocol/API changes
- Tests: update existing `onExit` tests, add `reattach` tests
