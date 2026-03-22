# Tailscale Integration (Embedded tsnet via libtailscale)

**Date**: 2026-03-21
**Status**: Proposed
**ADR**: Draft `docs/decisions/0009-tailscale-embedded-userspace.md` upon acceptance

## Problem

Muxi currently requires direct network connectivity to SSH servers. Users on Tailscale/Headscale networks cannot reach their machines without a separate VPN app, and iOS limits the system to one active VPN at a time, causing conflicts.

## Solution

Embed a Tailscale node directly in Muxi using `libtailscale` (C API over tsnet). This provides userspace networking that coexists with any system VPN — no Network Extension or VPN slot required.

## Decisions

- **Networking**: tsnet userspace (no system VPN slot)
- **Control server**: Headscale (self-hosted), single instance
- **Authentication**: Pre-auth key (generated via `headscale preauthkeys create`)
- **Lifecycle**: Manual toggle — user explicitly connects/disconnects; independent of SSH connections
- **Integration**: Global Tailscale config + per-server `useTailscale` toggle
- **Library**: libtailscale (C API) via gomobile xcframework build

## Build Pipeline

### New files

```
scripts/
  build-libtailscale.sh    # gomobile → xcframework

vendor/
  libtailscale.xcframework/ # build output (gitignored)
```

### `build-libtailscale.sh`

1. Verify Go + gomobile installed
2. Fetch libtailscale source (`go get`)
3. `gomobile bind` for iphoneos-arm64, iphonesimulator-arm64, iphonesimulator-x86_64
4. Output to `vendor/libtailscale.xcframework/`

### `build-all.sh`

Add libtailscale build step after OpenSSL + libssh2.

### `project.yml`

Add `libtailscale.xcframework` as **embedded framework** (`embed: true`). This differs from libssh2/openssl (static, `embed: false`) because gomobile produces a dynamic framework containing the Go runtime (~15-25MB binary size increase).

## Data Model & Storage

### Headscale config (global, single instance)

| Field | Storage | Description |
|-------|---------|-------------|
| `controlURL` | UserDefaults | Headscale server URL |
| `preAuthKey` | Keychain | Authentication key (secret) |
| `hostname` | UserDefaults | This device's name in tailnet (default: auto from device name) |

Keychain storage uses existing `KeychainService` pattern with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.

### tsnet state directory

libtailscale/tsnet requires a persistent state directory for WireGuard keys, node identity, and cached peers.

- Path: `FileManager.default.urls(for: .applicationSupportDirectory, ...).appendingPathComponent("tailscale")`
- Excluded from iCloud backup (`URLResourceValues.isExcludedFromBackup = true`)
- Cleaned up on app uninstall (lives inside app container)

### Server model extension

```swift
@Model final class Server {
    // ... existing fields ...
    var useTailscale: Bool = false
}
```

Single `Bool` field with default value. SwiftData lightweight migration handles this automatically (additive field with default) — no `VersionedSchema` / `SchemaMigrationPlan` needed.

When `true`, SSH connection routes through Tailscale. `host` field accepts Tailscale IPs (100.x.x.x) or MagicDNS names.

TOFU host key fingerprint is stored per `Server` record, so a server accessed via direct IP and via Tailscale IP would be separate `Server` entries with independent fingerprints.

## Service Layer

### TailscaleService (new)

```swift
enum TailscaleError: Error {
    case notConnected
    case dialFailed(String)
    case startFailed(String)
}

actor TailscaleService {
    enum State {
        case disconnected
        case connecting
        case connected
        case error(String)
    }

    /// Start the tsnet node and connect to Headscale.
    func start(controlURL: String, authKey: String, hostname: String) async throws

    /// Stop the tsnet node.
    func stop()

    /// Dial a peer. Returns a file descriptor for use with libssh2.
    /// Caller does NOT own the fd — TailscaleService manages its lifecycle.
    /// The fd is invalidated when stop() is called or on connection failure.
    func dial(host: String, port: UInt16) async throws -> Int32
}
```

- `actor` isolation (same pattern as SSHService)
- Wraps libtailscale C API calls (`tailscale_new`, `tailscale_up`, `tailscale_dial`)
- `start()` and `dial()` are `async throws` — network operations that can fail
- State directory passed to libtailscale on `start()`

### fd ownership

**TailscaleService owns the fd.** SSHService must NOT call `close(fd)` on a Tailscale-provided fd.

- SSHService's `cleanupSession()` currently calls `close(self.socketFd)`. When using a Tailscale fd, SSHService must skip this close and instead notify TailscaleService.
- Implementation: SSHService tracks `isTailscaleFD: Bool` flag. If true, skip `close()` in cleanup.
- TailscaleService reclaims the fd when `stop()` is called or the connection drops.

### `poll()` compatibility

SSHService uses `poll()` on the socket fd for read readiness. libtailscale's `dial()` returns a Unix socket fd (created via `socketpair()`), which is fully compatible with `poll()`, `read()`, `write()`. This must be validated in integration testing.

### SSHServiceProtocol (modified)

```swift
protocol SSHServiceProtocol: AnyObject {
    func connect(
        host: String, port: UInt16,
        username: String, auth: SSHAuth,
        expectedFingerprint: String?,
        tailscaleFD: Int32? = nil       // new parameter
    ) async throws
    // ... existing methods unchanged ...
}
```

All conforming types must be updated:
- `SSHService` (production)
- `MockSSHService` in test files (`ConnectionManagerTests`, `ConnectionManagerHostKeyTests`, `ConnectionManagerReconnectTests`, `WindowTrackingTests`)

### SSHService (modified)

```swift
actor SSHService: SSHServiceProtocol {
    private var isTailscaleFD: Bool = false

    func connect(
        host: String, port: UInt16,
        username: String, auth: SSHAuth,
        expectedFingerprint: String?,
        tailscaleFD: Int32? = nil
    ) async throws {
        if let fd = tailscaleFD {
            self.socketFd = fd
            self.isTailscaleFD = true
            // Skip socket(), connect(), getaddrinfo()
        } else {
            // Existing POSIX socket logic
            self.isTailscaleFD = false
        }
        // libssh2_session_handshake(session, socketFd) — same for both paths
    }

    private func cleanupSession() {
        // ...
        if !isTailscaleFD {
            close(self.socketFd)
        }
        // ...
    }
}
```

### ConnectionManager (modified)

```swift
@MainActor @Observable
class ConnectionManager {
    private let tailscaleService = TailscaleService()
    var tailscaleState: TailscaleService.State = .disconnected

    func connect(server: Server, password: String?) async {
        if server.useTailscale {
            guard tailscaleState == .connected else {
                // Show error: "Tailscale에 먼저 연결하세요"
                return
            }
            let fd = try await tailscaleService.dial(server.host, server.port)
            try await sshService.connect(
                host: server.host, port: server.port,
                username: server.username, auth: ...,
                expectedFingerprint: server.hostKeyFingerprint,
                tailscaleFD: fd
            )
        } else {
            try await sshService.connect(...)  // existing path
        }
    }
}
```

### Tailscale lifecycle vs SSH lifecycle

Tailscale connection is **independent** of SSH connections:
- User toggles Tailscale ON → stays connected until explicitly toggled OFF
- SSH connect/disconnect does not affect Tailscale state
- Multiple SSH connections can reuse the same Tailscale node
- Tailscale can stay connected with no active SSH session

## App Lifecycle

### Foreground resume

When the app returns from background:
1. tsnet's Go goroutines resume (unfrozen by OS)
2. tsnet internally re-establishes WireGuard tunnel + Headscale control connection
3. If tsnet detects failure, TailscaleService updates state to `.connecting` → `.connected` or `.error`
4. Existing SSH reconnect logic in ConnectionManager checks `tailscaleState` before attempting reconnection for Tailscale-routed servers

### Background suspension

- iOS suspends after ~30s — tsnet goroutines freeze
- No active keepalive or background task needed (terminal already disconnects in background)
- On resume: tsnet handles reconnection; SSH reconnects through existing auto-reconnect flow

## UI

### Settings — Tailscale section

```
┌─ Tailscale ──────────────────────────┐
│  Headscale URL    [https://hs.exam…] │
│  Pre-auth Key     [••••••••••••••••] │
│  Hostname         [muxi-iphone     ] │
│                                      │
│  연결 상태        ● Connected        │
│  [Connect] / [Disconnect]            │
└──────────────────────────────────────┘
```

- Manual connect/disconnect button
- State indicator (disconnected / connecting / connected / error)
- Pre-auth Key via SecureField
- Hostname defaults to auto-generated from device name

### Server add/edit — Tailscale toggle

```
┌─ 연결 설정 ──────────────────────────┐
│  Host             [100.64.0.3      ] │
│  Port             [22              ] │
│  Username         [root            ] │
│  Auth Method      [Password ▼      ] │
│  Tailscale 경유   [  ●━━ ON       ] │
└──────────────────────────────────────┘
```

- Disabled if Tailscale not configured → "설정에서 Tailscale을 먼저 구성하세요"
- Server list shows badge/icon for Tailscale-routed servers

## Error Handling

| Scenario | Behavior |
|----------|----------|
| Headscale URL unreachable | `TailscaleError.startFailed` → `State.error("Headscale 서버에 연결할 수 없습니다")` |
| Pre-auth key expired/invalid | `TailscaleError.startFailed` → `State.error("인증 실패 — Pre-auth Key를 확인하세요")` |
| `dial()` fails (peer unreachable) | `TailscaleError.dialFailed` → `SSHError.connectionFailed` path |
| Tailscale not connected + server.useTailscale | Block connection + "Tailscale에 먼저 연결하세요" |
| App backgrounded → foregrounded | tsnet auto-reconnects; SSH reconnect checks Tailscale state first |
| Tailscale drops during SSH session | fd becomes invalid → libssh2 read/write fails → existing SSH disconnect → auto-reconnect checks Tailscale state |

## Security

- Pre-auth Key: Keychain only (never logged, `CustomStringConvertible` redacts)
- Headscale URL, hostname: UserDefaults (non-secret)
- WireGuard private key: managed by tsnet in state directory (app container, not backed up)
- Follows existing security patterns from CLAUDE.md

## Out of Scope (Future)

- Tailscale ACL/policy display
- Tailnet machine auto-discovery
- Multiple Headscale instances
- Exit node support
- MagicDNS resolution within app

## Testing Strategy

- Unit tests for TailscaleService state machine (mock libtailscale C calls)
- Unit tests for SSHService fd passthrough (verify `isTailscaleFD` skip-close behavior)
- Integration test: `poll()` compatibility on libtailscale fd
- Update all MockSSHService conformances for new `tailscaleFD` parameter
- UI tests: Tailscale settings screen, server toggle behavior
- Manual test on device: end-to-end Headscale → SSH connection
