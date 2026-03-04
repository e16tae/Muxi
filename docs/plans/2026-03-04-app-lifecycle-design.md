# App Lifecycle Design

## Goal

Observe `ScenePhase` to gracefully disconnect SSH on background, auto-reconnect + re-attach on foreground return. tmux sessions survive on the server — this is the core tmux contract.

## Approach

`MuxiApp.swift` observes `@Environment(\.scenePhase)`. On `.background`, call `connectionManager.handleBackground()` which disconnects SSH cleanly. On `.active`, call `connectionManager.handleForeground()` which auto-reconnects if the disconnect was caused by backgrounding.

## Files

- Modify: `ios/Muxi/App/MuxiApp.swift` — add `scenePhase` observation with `.onChange`
- Modify: `ios/Muxi/Services/ConnectionManager.swift` — add `handleBackground()`, `handleForeground()`, tracking properties

## ConnectionManager Changes

### New Properties

- `disconnectedByBackground: Bool` — distinguishes background disconnect from manual detach
- `lastServer: Server?` — server to reconnect to
- `lastSessionName: String?` — tmux session to re-attach

### `handleBackground()`

1. Set `disconnectedByBackground = true`
2. Cancel `sshMonitorTask` (prevents race condition — monitor detecting disconnect and triggering unwanted reconnect)
3. Save current server and session name to `lastServer`/`lastSessionName`
4. Send tmux `detach\n` (single synchronous write — fast, completes before suspension)
5. Disconnect SSH (best-effort, may be interrupted by suspension)

### `handleForeground()`

1. Guard `disconnectedByBackground == true` (skip if user manually detached)
2. Reset `disconnectedByBackground = false`
3. Auto-reconnect to `lastServer` with `lastSessionName`
4. Reuse existing `reconnect()` logic with exponential backoff

## MuxiApp Changes

```swift
@Environment(\.scenePhase) private var scenePhase

// In body, on the WindowGroup or root view:
.onChange(of: scenePhase) { _, newPhase in
    switch newPhase {
    case .background:
        connectionManager.handleBackground()
    case .active:
        connectionManager.handleForeground()
    case .inactive:
        break // Ignore — Control Center, phone calls, etc.
    @unknown default:
        break
    }
}
```

## Details

- **`.inactive` ignored**: Precedes `.background` but also fires for Control Center, incoming calls. No action needed.
- **Monitor task race**: Cancelled in `handleBackground()` to prevent auto-reconnect during background transition.
- **Background execution**: tmux `detach\n` is a single channel write (~10 bytes) — completes instantly. Full SSH teardown is best-effort.
- **App killed by iOS**: In-memory `lastServer`/`lastSessionName` lost. User sees server list on relaunch. Acceptable for v1.
- **Rapid background/foreground**: Existing `guard state != .reconnecting` prevents duplicate reconnect attempts.
- **ReconnectingOverlay**: Already exists in UI, shown during reconnect. No new UI needed.

## Out of Scope

- Background task / `performExpiringActivity` (detach write is fast enough without it)
- Persisting last connection to UserDefaults
- Background mode entitlement
- Push notifications for session events
