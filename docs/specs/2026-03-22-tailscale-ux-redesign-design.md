# Tailscale UX Redesign — Design Spec

**Date**: 2026-03-22
**Status**: Draft
**Supersedes**: 2026-03-21-tailscale-integration-design.md (UX portions)

## Problem

The current Tailscale integration requires too many manual steps:

1. Navigate to Settings → Tailscale, enter Headscale URL / pre-auth key / hostname
2. Tap Connect manually (no auto-connect)
3. Navigate back to Servers, edit server, toggle Tailscale ON
4. Manually type Tailscale IP into host field
5. Connect to server

Additional issues:
- Only Headscale supported (no official Tailscale / OAuth)
- No device discovery (manual IP entry)
- Pre-auth key displayed after node registration (confusing)
- Two separate config locations (Settings + ServerEdit) with no linking

## Goals

- **Single-flow server creation**: Tailscale account setup → device selection → server creation in one wizard
- **Zero manual IP entry**: API-based device discovery for both Tailscale and Headscale
- **Auto-connect**: If Tailscale was connected at last app exit, reconnect automatically on launch
- **Dual provider support**: Official Tailscale (OAuth) and Headscale (pre-auth key)
- **Settings for management only**: Account status, disconnect, sign out — not part of server creation flow

## Non-Goals

- Multiple simultaneous tailnet accounts (Tailscale only supports one per device)
- MagicDNS configuration or DNS management
- Tailscale ACL/policy management

---

## Data Model

### TailscaleAccount

Single global account. Secrets in Keychain, config in UserDefaults.

```swift
enum TailscaleProvider: String, Codable {
    case official    // tailscale.com — OAuth
    case headscale   // self-hosted — pre-auth key
}

/// Concrete value type representing the account state.
/// Read/written by TailscaleAccountManager; not persisted as a single blob.
struct TailscaleAccount {
    let provider: TailscaleProvider
    let controlURL: String
    let hostname: String
    var isRegistered: Bool
    var lastConnected: Bool
}
```

**UserDefaults** (non-secret config):
| Key | Type | Description |
|-----|------|-------------|
| `tailscale.provider` | String | "official" or "headscale" |
| `tailscale.controlURL` | String | Control server URL |
| `tailscale.hostname` | String | This device's tailnet hostname |
| `tailscale.isRegistered` | Bool | Node registered with control server |
| `tailscale.lastConnected` | Bool | Was connected at last app exit |

**Keychain** (secrets):
| Account | Description |
|---------|-------------|
| `tailscale.accessToken` | OAuth access token (official) |
| `tailscale.refreshToken` | OAuth refresh token (official) |
| `tailscale.preAuthKey` | Pre-auth key (headscale, cleared after registration) |
| `tailscale.apiKey` | Headscale API key for device listing |

**`isConfigured` semantics** (per provider):
- Official: valid access token exists in Keychain
- Headscale: control URL is set AND node is registered (`isRegistered == true`)

### TailscaleAccountManager

`@MainActor @Observable class` — the UI binds to its published state (provider, connection status, isRegistered). Wraps UserDefaults + Keychain reads/writes. Replaces `TailscaleConfigStore`.

### Server Model Change

Remove `useTailscale: Bool`. Add:

```swift
var tailscaleDeviceID: String?    // nil = Direct, non-nil = Tailscale
var tailscaleDeviceName: String?  // Display name ("my-server")
```

Tailscale connection is determined by `tailscaleDeviceID != nil`. The `host` field is auto-populated with the device's Tailscale IPv4 address.

**SwiftData migration**: Requires `VersionedSchema` + `SchemaMigrationPlan`:
1. Define `ServerSchemaV1` (current schema with `useTailscale: Bool`)
2. Define `ServerSchemaV2` (new schema with `tailscaleDeviceID/Name: String?`)
3. Lightweight migration: `useTailscale == true` → `tailscaleDeviceID = "migrated-\(host)"`, `tailscaleDeviceName = host`
4. Update `ModelContainer` configuration in `MuxiApp.swift` to use the migration plan

---

## Authentication Flows

### Official Tailscale (OAuth)

**OAuth client requirements:**
- Register an OAuth client in Tailscale admin console → yields `client_id` + `client_secret`
- Required scopes: `devices:read` (device listing), `auth-keys` (ephemeral key creation)
- Redirect URI: custom URL scheme registered in `project.yml` Info.plist (e.g., `muxi://tailscale/callback`)
- `client_id` bundled in app; `client_secret` stored in Keychain after initial config

**tsnet auth bridge** (tsnet does not accept OAuth tokens directly):
1. User completes OAuth → access token received
2. App calls `POST https://api.tailscale.com/api/v2/tailnet/-/keys` with the access token to create a short-lived, single-use, ephemeral auth key (`tskey-auth-...`)
3. Auth key passed to `muxits_start(controlURL, authKey, hostname, stateDir)`
4. After node registration succeeds, the auth key is consumed and not stored
5. Subsequent reconnects use the node identity persisted in `stateDir` (WireGuard keys) — no auth key needed

**Token refresh**: Standard OAuth2 refresh flow triggered reactively on 401 responses from the Tailscale API. Implemented in `TailscaleAccountManager`. If refresh fails → prompt user to re-login.

**Flow:**
1. User selects "Tailscale" provider in setup wizard
2. "Sign in with Tailscale" → `ASWebAuthenticationSession` opens OAuth page
3. Authorization code exchange → access + refresh tokens → Keychain
4. Create ephemeral auth key via API → `muxits_start()` → node joins tailnet
5. Device list fetched via `GET https://api.tailscale.com/api/v2/tailnet/-/devices`

### Headscale (Self-hosted)

1. User selects "Headscale" provider
2. User enters: control URL, pre-auth key, API key (required for device discovery)
3. `muxits_start()` called with control URL + pre-auth key
4. On successful registration: `isRegistered = true`, pre-auth key no longer displayed in UI
5. Device list fetched via `GET {controlURL}/api/v1/machine` (using API key)

**Note**: API key is required (not optional). The design goal is zero manual IP entry. Without an API key, device discovery cannot work.

### Auto-reconnect

**On app exit/background**: save `lastConnected = (tailscaleState == .connected)`

**On app foreground** (`scenePhase == .active`) — ordering is critical:
1. Check `lastConnected == true` and account is configured
2. Call `muxits_start()` and **await completion** (node reconnects using persisted identity in `stateDir`)
3. Set `tailscaleState = .connected`
4. Only then proceed with existing SSH foreground reconnect in `ConnectionManager.handleForeground()`

This ordering prevents `handleForeground()` from attempting SSH reconnect on Tailscale servers before the tunnel is ready.

**On server connect** with `tailscaleDeviceID != nil`:
- If Tailscale disconnected → auto-reconnect (await `muxits_start()`) before dial
- If reconnect fails → surface error to user

---

## UI Flows

### Server Creation — Tailscale Path (Primary Flow)

```
ServerEditView
├─ Connection method: [Direct] [Tailscale]    ← segmented control
│
├─ Direct: existing flow (host, port, username, auth)
│
└─ Tailscale:
   ├─ Account NOT configured → "Set up Tailscale" button
   │  └─ Presents TailscaleSetupSheet (modal)
   │     ├─ Step 1: Provider picker [Tailscale] [Headscale]
   │     ├─ Step 2a (Official): "Sign in with Tailscale" → OAuth → ephemeral key → node join
   │     ├─ Step 2b (Headscale): URL + Pre-auth key + API key → Connect → node join
   │     └─ Success → dismiss sheet → device list appears
   │
   └─ Account configured → Device list inline
      ├─ Searchable list: device name, IPv4, online status, OS icon
      ├─ Pull-to-refresh
      ├─ Select device → auto-fill: host, name, tailscaleDeviceID
      └─ User completes: username, auth method → Save
```

### Settings → Tailscale (Management Only)

```
TailscaleSettingsView
├─ Account section
│  ├─ Provider: "Tailscale" or "Headscale (self-hosted)"
│  ├─ Status: Connected / Disconnected / Error
│  ├─ This device: hostname on tailnet
│  └─ Control URL (Headscale only)
│
├─ Actions
│  ├─ Disconnect / Connect toggle
│  └─ Sign out (clears account, disconnects)
│
└─ (Headscale + not registered) Re-register option
```

### Server List Display

- Tailscale servers show device name with a Tailscale badge icon
- Connection to Tailscale server: auto-reconnect Tailscale if needed (no manual step)

---

## Device Discovery Service

```swift
/// Fetches tailnet peer list. Called from @MainActor ViewModel via `await`.
actor TailscaleDeviceService {
    /// Fetch devices from the tailnet.
    /// - Official: GET https://api.tailscale.com/api/v2/tailnet/-/devices
    ///   (Bearer token auth with access token)
    /// - Headscale: GET {controlURL}/api/v1/machine
    ///   (Bearer token auth with API key)
    func fetchDevices(account: TailscaleAccount) async throws -> [TailscaleDevice]
}

struct TailscaleDevice: Identifiable {
    let id: String
    let name: String           // "my-server"
    let addresses: [String]    // ["100.64.0.1", "fd7a:115c:..."]
    let isOnline: Bool
    let os: String?            // "linux", "windows"
    let lastSeen: Date?
}
```

**Data flow to UI**: `TailscaleDeviceListView` uses a `@MainActor @Observable` ViewModel that calls `TailscaleDeviceService.fetchDevices()` via `await` and stores results as published state. Same pattern as `TailscaleService` (actor called from `@MainActor` context).

**IPv4 address selection**: Filter for IPv4 first (`addresses.first(where: { $0.contains(".") })`), fall back to IPv6 if no IPv4 available.

Device selection auto-fills:
- `server.host` ← `device.addresses.first(where: { $0.contains(".") })` (IPv4 preferred)
- `server.tailscaleDeviceID` ← `device.id`
- `server.tailscaleDeviceName` ← `device.name`
- `server.name` ← `device.name` (user can override)

---

## Component Map

### New Components
| Component | Layer | Type | Purpose |
|-----------|-------|------|---------|
| `TailscaleAccountManager` | App | `@MainActor @Observable class` | Replaces `TailscaleConfigStore`. Account lifecycle, storage split, token refresh |
| `TailscaleDeviceService` | App | `actor` | API-based device discovery |
| `TailscaleSetupSheet` | UI | View | Inline wizard for first-time Tailscale setup |
| `TailscaleDeviceListView` | UI | View | Searchable device picker |
| `TailscaleDeviceListViewModel` | App | `@MainActor @Observable class` | Mediates between `TailscaleDeviceService` actor and UI |

### Modified Components
| Component | Change |
|-----------|--------|
| `Server` | Remove `useTailscale: Bool`, add `tailscaleDeviceID/Name: String?` via schema migration |
| `ServerEditView` | Add connection method picker, Tailscale device selection |
| `TailscaleSettingsView` | Simplify to account management only |
| `ConnectionManager` | Auto-reconnect logic, `tailscaleDeviceID`-based routing, foreground ordering |
| `TailscaleService` | No change (C API wrapper stays the same) |
| `MuxiApp` | Add `ModelContainer` migration plan, Tailscale auto-reconnect on `scenePhase` |

### Removed Components
| Component | Reason |
|-----------|--------|
| `TailscaleConfigStore` | Replaced by `TailscaleAccountManager` |

---

## Migration

### SwiftData Schema Migration

Requires `VersionedSchema` + `SchemaMigrationPlan`:

1. `ServerSchemaV1`: current schema (includes `useTailscale: Bool`)
2. `ServerSchemaV2`: new schema (`tailscaleDeviceID: String?`, `tailscaleDeviceName: String?`, no `useTailscale`)
3. Lightweight migration mapping:
   - `useTailscale == true` → `tailscaleDeviceID = "migrated-\(host)"`, `tailscaleDeviceName = host`
   - `useTailscale == false` → `tailscaleDeviceID = nil`, `tailscaleDeviceName = nil`
4. `MuxiApp.swift` updated to configure `ModelContainer` with migration plan

**Placeholder reconciliation**: When a user edits a migrated server and selects a device from the API-based device list, the placeholder `"migrated-..."` ID is replaced with the real Tailscale device ID.

### Config Migration

Existing Tailscale config (UserDefaults + Keychain):
- Migrated to new key names by `TailscaleAccountManager.migrateIfNeeded()`
- `provider` defaults to `.headscale` (only option before this redesign)
- Existing pre-auth key and control URL preserved

---

## Error Handling

| Scenario | Behavior |
|----------|----------|
| OAuth cancelled by user | Dismiss sheet, no state change |
| OAuth token expired | Auto-refresh via refresh token (on 401); if fails → prompt re-login |
| Ephemeral auth key creation fails | Show error in setup sheet, allow retry |
| Headscale pre-auth key invalid | Show error inline in setup sheet, allow retry |
| Tailscale auto-reconnect fails on foreground | Show banner in server list, allow manual retry; block SSH reconnect for Tailscale servers |
| Device offline at connection time | Proceed with dial (may timeout), show clear error |
| API device list fetch fails | Show error + retry button, allow manual IP fallback |
