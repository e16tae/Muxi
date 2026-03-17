# ADR-0008: Window/Pane State Machine

## Status

Accepted

## Date

2026-03-17

## Context

Window/pane state was represented as 10+ independent properties (`currentPanes`, `activePaneId`, `activeWindowId`, `switchingToWindowId`, `isZoomed`, `pendingAutoZoom`, etc.) that relied on implicit invariants. This caused three structural problems:

1. **Triple model duplication**: `TmuxPane`/`TmuxWindow` (dead code), `TmuxWindowInfo` (ConnectionManager), `ParsedPane` (TmuxControlService) all represented the same concepts differently.
2. **Scattered state**: Independent properties allowed impossible combinations (e.g. "zoomed + switching window + auto-zooming") that the code had to guard against at runtime.
3. **Manual initialization**: 12 properties needed resetting at 4 different sites (disconnect, session-switch, reconnect, background) with identical logic copy-pasted.

Additionally, pane/window/session IDs were all plain `String`, making accidental mixups invisible to the compiler.

## Decision

### Phase 1: Unified models with strong-typed IDs

- Introduce `PaneID`, `WindowID`, `SessionID` wrapper types that prevent ID mixups at compile time.
- Replace `TmuxControlService.ParsedPane` and the dead `TmuxPane` with a unified `Pane` model.
- Replace `ConnectionManager.TmuxWindowInfo` and the dead `TmuxWindow` with a unified `Window` model.
- Eliminate the `"%\(pane.paneId)"` string formatting pattern (~11 sites).

### Phase 2: State machine

- Introduce `WindowPaneState` enum with four cases: `.awaitingLayout`, `.active`, `.switchingWindow`, `.autoZooming`.
- Each case carries only the data valid for that state (associated values).
- Replace the scattered properties with computed properties that read from the state machine.
- Unify the 4 reset sites into a single `resetWindowPaneState()` method.

## Alternatives Considered

### Alternative A — Keep independent properties, add validation

Add runtime assertions to guard against impossible state combinations. Rejected because:
- Assertions only catch bugs at runtime, not compile time.
- Doesn't solve the model duplication or manual initialization problems.

### Alternative B — Introduce state machine without strong-typed IDs

Apply only the state machine refactoring. Rejected because:
- The `"%\(pane.paneId)"` pattern and string-typed IDs were a separate, orthogonal source of bugs.
- Combining both changes in one pass avoids touching the same files twice.

## Consequences

- (+) Impossible state combinations are compile-time errors (e.g. accessing `panes` in `switchingWindow` state).
- (+) 4 duplicate initialization sites → 1 `resetWindowPaneState()` call.
- (+) Pane/window ID mixups are compile-time errors via `PaneID`/`WindowID`.
- (+) 11 `"%\(pane.paneId)"` formatting sites eliminated.
- (+) Dead code removed (`PaneSize`, `TmuxPane`, `TmuxWindow`).
- (-) State transitions are less "obvious" than direct property mutation — must understand the state machine diagram.
- (-) Tests reference state machine cases instead of simple property checks.
