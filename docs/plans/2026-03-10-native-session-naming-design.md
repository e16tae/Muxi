# Native tmux Session Naming

**Date**: 2026-03-10
**Status**: Approved

## Problem

Session auto-create hardcodes `"main"` as the name. Manual "New Session" requires a name. Both bypass tmux's native auto-numbering (0, 1, 2...).

## Decision

Use tmux's native naming by omitting `-s` and capturing the assigned name via `-P -F '#{session_name}'`.

## Changes

### 1. `connect()` auto-create (L270)

Remove `-s "main"`, use `-P -F '#{session_name}'` to capture the name from `execCommand` output.

### 2. `PendingCommand` enum

Add `.createSession` case for handling `-P -F` responses in control mode.

### 3. `createAndSwitchToNewSession(name:)` → `name: String? = nil`

- `name != nil`: existing behavior with `-s`
- `name == nil`: omit `-s`, use `-P -F`, route response through `.createSession`

### 4. TerminalSessionView "New Session" dialog

Allow empty name → passes `nil` → tmux default numbering. Non-empty → custom name.

## Rejected Alternatives

- **B: Rely on `%sessions-changed`** — race conditions, indirect, requires session diff
- **C: Compute next number locally** — duplicates tmux logic, anti-pattern
