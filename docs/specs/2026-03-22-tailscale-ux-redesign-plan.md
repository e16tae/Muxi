# Tailscale UX Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign Tailscale integration UX — inline wizard, OAuth + Headscale dual provider, API device discovery, auto-reconnect.

**Architecture:** Replace `TailscaleConfigStore` with `TailscaleAccountManager` (@MainActor @Observable). Add `TailscaleDeviceService` (actor) for API-based device listing. Migrate SwiftData `Server` model from `useTailscale: Bool` to `tailscaleDeviceID: String?`. Inline Tailscale setup wizard in `ServerEditView` replaces the two-location configuration pattern.

**Tech Stack:** SwiftUI, SwiftData (VersionedSchema migration), ASWebAuthenticationSession (OAuth), URLSession (Tailscale/Headscale API), Keychain (secrets), Swift Testing + XCTest.

**Spec:** `docs/specs/2026-03-22-tailscale-ux-redesign-design.md`

**Prerequisites:** Run `cd ios && xcodegen generate` after adding new files (before build/test steps).

**Note:** OAuth flow (`ASWebAuthenticationSession`) is a placeholder in this plan. Full OAuth implementation requires registering an OAuth client with Tailscale admin console first. This will be a follow-up task.

---

## File Map

### New Files
| File | Purpose |
|------|---------|
| `ios/Muxi/Services/TailscaleAccountManager.swift` | @MainActor @Observable — account lifecycle, dual provider config, UserDefaults + Keychain |
| `ios/Muxi/Services/TailscaleDeviceService.swift` | Actor — API-based device discovery (Tailscale + Headscale) |
| `ios/Muxi/ViewModels/TailscaleDeviceListViewModel.swift` | @MainActor @Observable — mediates DeviceService ↔ UI |
| `ios/Muxi/Views/ServerEdit/TailscaleSetupSheet.swift` | Inline wizard: provider picker → OAuth / Headscale form |
| `ios/Muxi/Views/ServerEdit/TailscaleDeviceListView.swift` | Searchable device picker with online status |
| `ios/Muxi/Models/ServerMigration.swift` | VersionedSchema V1→V2 + SchemaMigrationPlan |
| `ios/MuxiTests/Services/TailscaleAccountManagerTests.swift` | Account manager tests |
| `ios/MuxiTests/Services/TailscaleDeviceServiceTests.swift` | Device service JSON parsing tests |
| `ios/MuxiTests/ViewModels/TailscaleDeviceListViewModelTests.swift` | ViewModel tests |

### Modified Files
| File | Change |
|------|--------|
| `ios/Muxi/Models/Server.swift` | Remove `useTailscale`, add `tailscaleDeviceID/Name` |
| `ios/Muxi/Services/ConnectionManager.swift` | Auto-reconnect, `tailscaleDeviceID`-based routing |
| `ios/Muxi/App/MuxiApp.swift` | Migration plan, Tailscale auto-reconnect on scenePhase |
| `ios/Muxi/Views/ServerEdit/ServerEditView.swift` | Connection method picker, Tailscale device selection |
| `ios/Muxi/Views/Settings/TailscaleSettingsView.swift` | Simplify to account management only |
| `ios/Muxi/Views/Settings/SettingsView.swift` | Update status display for new AccountManager |
| `ios/MuxiTests/Services/ConnectionManagerTailscaleTests.swift` | Update for `tailscaleDeviceID` routing |
| `ios/MuxiTests/Models/ServerModelTests.swift` | Update `useTailscale` test to `isTailscale` |
| `ios/Muxi/App/ContentView.swift` | Add `TailscaleAccountManager()` to previews |

### Removed Files
| File | Reason |
|------|--------|
| `ios/Muxi/Services/TailscaleConfigStore.swift` | Replaced by TailscaleAccountManager |
| `ios/MuxiTests/Services/TailscaleConfigStoreTests.swift` | Replaced by TailscaleAccountManagerTests |

---

## Task 1: SwiftData Server Model Migration

**Files:**
- Create: `ios/Muxi/Models/ServerMigration.swift`
- Modify: `ios/Muxi/Models/Server.swift`
- Modify: `ios/Muxi/App/MuxiApp.swift`
- Test: `ios/MuxiTests/Models/ServerMigrationTests.swift`

- [ ] **Step 1: Write the failing test for Server model with new fields**

```swift
// ios/MuxiTests/Models/ServerMigrationTests.swift
import Testing
@testable import Muxi

@Suite("Server Model V2")
struct ServerMigrationTests {
    @Test("Server with tailscaleDeviceID is Tailscale server")
    func tailscaleDeviceIDIndicatesTailscale() {
        let server = Server(name: "ts", host: "100.64.0.1", username: "root", authMethod: .password)
        server.tailscaleDeviceID = "node-abc123"
        server.tailscaleDeviceName = "my-server"
        #expect(server.tailscaleDeviceID != nil)
        #expect(server.tailscaleDeviceName == "my-server")
    }

    @Test("Server without tailscaleDeviceID is direct server")
    func noTailscaleDeviceIDMeansDirect() {
        let server = Server(name: "direct", host: "192.168.1.1", username: "root", authMethod: .password)
        #expect(server.tailscaleDeviceID == nil)
        #expect(server.tailscaleDeviceName == nil)
    }

    @Test("isTailscale computed property")
    func isTailscaleComputed() {
        let server = Server(name: "ts", host: "100.64.0.1", username: "root", authMethod: .password)
        #expect(server.isTailscale == false)
        server.tailscaleDeviceID = "node-123"
        #expect(server.isTailscale == true)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' -only-testing:MuxiTests/ServerMigrationTests 2>&1 | tail -20`
Expected: FAIL — `tailscaleDeviceID` property does not exist

- [ ] **Step 3: Create ServerMigration.swift with VersionedSchema**

```swift
// ios/Muxi/Models/ServerMigration.swift
import Foundation
import SwiftData

// MARK: - Schema V1 (current)

enum ServerSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [ServerV1.self] }

    @Model
    final class ServerV1 {
        @Attribute(.unique) var id: UUID
        var name: String
        var host: String
        var port: UInt16
        var username: String
        var authMethod: AuthMethod
        var agentForwarding: Bool
        var hostKeyFingerprint: String?
        var useTailscale: Bool = false

        init(id: UUID = UUID(), name: String, host: String, port: UInt16 = 22,
             username: String, authMethod: AuthMethod, agentForwarding: Bool = false,
             hostKeyFingerprint: String? = nil) {
            self.id = id; self.name = name; self.host = host; self.port = port
            self.username = username; self.authMethod = authMethod
            self.agentForwarding = agentForwarding; self.hostKeyFingerprint = hostKeyFingerprint
        }
    }
}

// MARK: - Schema V2 (Tailscale UX redesign)

enum ServerSchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] { [Server.self] }
}

// MARK: - Migration Plan

enum ServerMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [ServerSchemaV1.self, ServerSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [migrateV1toV2]
    }

    static let migrateV1toV2 = MigrationStage.custom(
        fromVersion: ServerSchemaV1.self,
        toVersion: ServerSchemaV2.self
    ) { context in
        // Read UserDefaults markers written by willMigrate, apply to V2 model.
        let servers = try context.fetch(FetchDescriptor<Server>())
        for server in servers {
            let key = "migration.tailscale.\(server.id.uuidString)"
            if UserDefaults.standard.bool(forKey: key) {
                server.tailscaleDeviceID = "migrated-\(server.host)"
                server.tailscaleDeviceName = server.host
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        try context.save()
    } willMigrate: { context in
        // In V1 schema, read useTailscale and mark for migration.
        let v1Servers = try context.fetch(FetchDescriptor<ServerSchemaV1.ServerV1>())
        for server in v1Servers where server.useTailscale {
            // Store migration marker in UserDefaults keyed by server ID.
            // The didMigrate stage will read these and set tailscaleDeviceID.
            UserDefaults.standard.set(true, forKey: "migration.tailscale.\(server.id.uuidString)")
        }
    }
}
```

- [ ] **Step 4: Update Server model — remove useTailscale, add new fields**

```swift
// ios/Muxi/Models/Server.swift — replace useTailscale with:
var tailscaleDeviceID: String?
var tailscaleDeviceName: String?

var isTailscale: Bool { tailscaleDeviceID != nil }
```

Remove `useTailscale: Bool = false` from the model and init.

- [ ] **Step 5: Fix all compilation errors from useTailscale removal**

Search for all remaining `useTailscale` references and update them:

1. `ios/Muxi/Services/ConnectionManager.swift`: Replace all `server.useTailscale` with `server.isTailscale` (4 occurrences at ~lines 410, 438, 446, 483). Also replace `attachOrCreate: server.useTailscale` with `attachOrCreate: server.isTailscale`.

2. `ios/Muxi/Views/ServerEdit/ServerEditView.swift`: Remove `@State private var useTailscale = false`, remove the Network section with the Tailscale toggle, remove `server.useTailscale = useTailscale` in `save()`, remove `useTailscale = server.useTailscale` in `loadServer()`.

3. `ios/MuxiTests/Services/ConnectionManagerTailscaleTests.swift`: Replace `server.useTailscale = true` with `server.tailscaleDeviceID = "node-test"`, replace `server.useTailscale = false` with leaving `tailscaleDeviceID` as nil.

4. `ios/MuxiTests/Models/ServerModelTests.swift`: Replace the `useTailscaleDefault` test with an `isTailscaleDefault` test that checks `server.isTailscale == false` and `server.tailscaleDeviceID == nil`.

5. Run `cd ios && xcodegen generate` to pick up new files.

This ensures the entire project compiles after Task 1.

- [ ] **Step 6: Update MuxiApp.swift ModelContainer with migration plan**

```swift
// In MuxiApp.swift, replace:
//   .modelContainer(for: [Server.self])
// With:
.modelContainer(for: Server.self, migrationPlan: ServerMigrationPlan.self)
```

- [ ] **Step 7: Run test to verify it passes**

Run: `xcodebuild test -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' -only-testing:MuxiTests/ServerMigrationTests 2>&1 | tail -20`
Expected: PASS

- [ ] **Step 8: Verify full build succeeds (no compilation errors)**

Run: `xcodebuild build-for-testing -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' 2>&1 | tail -10`
Expected: BUILD SUCCEEDED — all `useTailscale` references removed

- [ ] **Step 9: Commit**

```bash
git add ios/Muxi/Models/ServerMigration.swift ios/Muxi/Models/Server.swift \
        ios/Muxi/App/MuxiApp.swift ios/MuxiTests/Models/ServerMigrationTests.swift \
        ios/Muxi/Services/ConnectionManager.swift \
        ios/Muxi/Views/ServerEdit/ServerEditView.swift \
        ios/MuxiTests/Services/ConnectionManagerTailscaleTests.swift \
        ios/MuxiTests/Models/ServerModelTests.swift
git commit -m "feat(tailscale): migrate Server model from useTailscale to tailscaleDeviceID

SwiftData VersionedSchema V1→V2 migration. Remove useTailscale: Bool,
add tailscaleDeviceID/Name: String? with isTailscale computed property.
Update all references in ConnectionManager, ServerEditView, and tests."
```

---

## Task 2: TailscaleAccountManager

**Files:**
- Create: `ios/Muxi/Services/TailscaleAccountManager.swift`
- Test: `ios/MuxiTests/Services/TailscaleAccountManagerTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// ios/MuxiTests/Services/TailscaleAccountManagerTests.swift
import Testing
@testable import Muxi

@Suite("TailscaleAccountManager", .serialized)
@MainActor
struct TailscaleAccountManagerTests {
    private func makeManager() -> TailscaleAccountManager {
        let defaults = UserDefaults(suiteName: "test.tailscale.\(UUID().uuidString)")!
        return TailscaleAccountManager(defaults: defaults, keychainService: KeychainService())
    }

    @Test("Initial state has no account configured")
    func initialState() {
        let manager = makeManager()
        #expect(manager.isConfigured == false)
        #expect(manager.provider == nil)
        #expect(manager.lastConnected == false)
    }

    @Test("Save Headscale account")
    func saveHeadscaleAccount() throws {
        let manager = makeManager()
        manager.configureHeadscale(
            controlURL: "https://hs.example.com",
            preAuthKey: "hskey-123",
            apiKey: "hsapi-456",
            hostname: "muxi-test"
        )
        #expect(manager.provider == .headscale)
        #expect(manager.controlURL == "https://hs.example.com")
        #expect(manager.hostname == "muxi-test")
        #expect(manager.isConfigured == false) // not registered yet
    }

    @Test("Headscale isConfigured after registration")
    func headscaleConfiguredAfterRegistration() {
        let manager = makeManager()
        manager.configureHeadscale(
            controlURL: "https://hs.example.com",
            preAuthKey: "hskey-123",
            apiKey: "hsapi-456",
            hostname: "muxi-test"
        )
        manager.markRegistered()
        #expect(manager.isConfigured == true)
    }

    @Test("Save Official Tailscale account")
    func saveOfficialAccount() {
        let manager = makeManager()
        manager.configureOfficial(
            accessToken: "tskey-access-123",
            refreshToken: "tskey-refresh-456",
            hostname: "muxi-test"
        )
        #expect(manager.provider == .official)
        #expect(manager.isConfigured == true) // has access token
    }

    @Test("lastConnected persists")
    func lastConnectedPersists() {
        let defaults = UserDefaults(suiteName: "test.tailscale.\(UUID().uuidString)")!
        let manager1 = TailscaleAccountManager(defaults: defaults, keychainService: KeychainService())
        manager1.lastConnected = true

        let manager2 = TailscaleAccountManager(defaults: defaults, keychainService: KeychainService())
        #expect(manager2.lastConnected == true)
    }

    @Test("Sign out clears all state")
    func signOutClearsAll() {
        let manager = makeManager()
        manager.configureOfficial(
            accessToken: "tskey-access-123",
            refreshToken: "tskey-refresh-456",
            hostname: "muxi-test"
        )
        manager.signOut()
        #expect(manager.provider == nil)
        #expect(manager.isConfigured == false)
        #expect(manager.lastConnected == false)
    }

    @Test("Account struct populated from storage")
    func accountFromStorage() {
        let manager = makeManager()
        manager.configureHeadscale(
            controlURL: "https://hs.example.com",
            preAuthKey: "hskey-123",
            apiKey: "hsapi-456",
            hostname: "muxi-test"
        )
        manager.markRegistered()
        let account = manager.account
        #expect(account != nil)
        #expect(account?.provider == .headscale)
        #expect(account?.controlURL == "https://hs.example.com")
        #expect(account?.isRegistered == true)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' -only-testing:MuxiTests/TailscaleAccountManagerTests 2>&1 | tail -20`
Expected: FAIL — TailscaleAccountManager does not exist

- [ ] **Step 3: Implement TailscaleAccountManager**

```swift
// ios/Muxi/Services/TailscaleAccountManager.swift
import Foundation
import UIKit

// MARK: - TailscaleProvider

enum TailscaleProvider: String, Codable, Sendable {
    case official
    case headscale
}

// MARK: - TailscaleAccount

struct TailscaleAccount: Sendable {
    let provider: TailscaleProvider
    let controlURL: String
    let hostname: String
    var isRegistered: Bool
    var lastConnected: Bool
}

// MARK: - TailscaleAccountManager

@MainActor @Observable
final class TailscaleAccountManager {
    private let defaults: UserDefaults
    private let keychainService: KeychainService

    // Keys
    private static let providerKey = "tailscale.provider"
    private static let controlURLKey = "tailscale.controlURL"
    private static let hostnameKey = "tailscale.hostname"
    private static let isRegisteredKey = "tailscale.isRegistered"
    private static let lastConnectedKey = "tailscale.lastConnected"
    private static let accessTokenAccount = "tailscale.accessToken"
    private static let refreshTokenAccount = "tailscale.refreshToken"
    private static let preAuthKeyAccount = "tailscale.preAuthKey"
    private static let apiKeyAccount = "tailscale.apiKey"

    // MARK: - Observable state

    private(set) var provider: TailscaleProvider?
    private(set) var controlURL: String = ""
    private(set) var hostname: String = ""
    private(set) var isRegistered: Bool = false
    var lastConnected: Bool {
        didSet { defaults.set(lastConnected, forKey: Self.lastConnectedKey) }
    }

    var isConfigured: Bool {
        guard let provider else { return false }
        switch provider {
        case .official:
            return (try? keychainService.retrievePassword(account: Self.accessTokenAccount)) != nil
        case .headscale:
            return !controlURL.isEmpty && isRegistered
        }
    }

    var account: TailscaleAccount? {
        guard let provider else { return nil }
        return TailscaleAccount(
            provider: provider,
            controlURL: controlURL,
            hostname: hostname,
            isRegistered: isRegistered,
            lastConnected: lastConnected
        )
    }

    // MARK: - Init

    init(defaults: UserDefaults = .standard, keychainService: KeychainService = KeychainService()) {
        self.defaults = defaults
        self.keychainService = keychainService
        self.lastConnected = defaults.bool(forKey: Self.lastConnectedKey)
        loadFromStorage()
    }

    private func loadFromStorage() {
        if let raw = defaults.string(forKey: Self.providerKey),
           let p = TailscaleProvider(rawValue: raw) {
            provider = p
        }
        controlURL = defaults.string(forKey: Self.controlURLKey) ?? ""
        hostname = defaults.string(forKey: Self.hostnameKey) ?? Self.defaultHostname()
        isRegistered = defaults.bool(forKey: Self.isRegisteredKey)
    }

    // MARK: - Configure

    func configureHeadscale(controlURL: String, preAuthKey: String, apiKey: String, hostname: String) {
        provider = .headscale
        self.controlURL = controlURL
        self.hostname = hostname
        isRegistered = false

        defaults.set(TailscaleProvider.headscale.rawValue, forKey: Self.providerKey)
        defaults.set(controlURL, forKey: Self.controlURLKey)
        defaults.set(hostname, forKey: Self.hostnameKey)
        defaults.set(false, forKey: Self.isRegisteredKey)

        try? keychainService.savePassword(preAuthKey, account: Self.preAuthKeyAccount)
        try? keychainService.savePassword(apiKey, account: Self.apiKeyAccount)
    }

    func configureOfficial(accessToken: String, refreshToken: String, hostname: String) {
        provider = .official
        self.controlURL = "https://controlplane.tailscale.com"
        self.hostname = hostname
        isRegistered = true // OAuth implies registered

        defaults.set(TailscaleProvider.official.rawValue, forKey: Self.providerKey)
        defaults.set(controlURL, forKey: Self.controlURLKey)
        defaults.set(hostname, forKey: Self.hostnameKey)
        defaults.set(true, forKey: Self.isRegisteredKey)

        try? keychainService.savePassword(accessToken, account: Self.accessTokenAccount)
        try? keychainService.savePassword(refreshToken, account: Self.refreshTokenAccount)
    }

    func markRegistered() {
        isRegistered = true
        defaults.set(true, forKey: Self.isRegisteredKey)
        // Clear pre-auth key after successful registration
        try? keychainService.deletePassword(account: Self.preAuthKeyAccount)
    }

    // MARK: - Credential Access

    func preAuthKey() -> String? {
        try? keychainService.retrievePassword(account: Self.preAuthKeyAccount)
    }

    func accessToken() -> String? {
        try? keychainService.retrievePassword(account: Self.accessTokenAccount)
    }

    func apiKey() -> String? {
        try? keychainService.retrievePassword(account: Self.apiKeyAccount)
    }

    // MARK: - Sign Out

    func signOut() {
        provider = nil
        controlURL = ""
        hostname = Self.defaultHostname()
        isRegistered = false
        lastConnected = false

        defaults.removeObject(forKey: Self.providerKey)
        defaults.removeObject(forKey: Self.controlURLKey)
        defaults.removeObject(forKey: Self.hostnameKey)
        defaults.removeObject(forKey: Self.isRegisteredKey)
        defaults.removeObject(forKey: Self.lastConnectedKey)

        try? keychainService.deletePassword(account: Self.accessTokenAccount)
        try? keychainService.deletePassword(account: Self.refreshTokenAccount)
        try? keychainService.deletePassword(account: Self.preAuthKeyAccount)
        try? keychainService.deletePassword(account: Self.apiKeyAccount)
    }

    // MARK: - Migration from TailscaleConfigStore

    func migrateIfNeeded() {
        // Check for old keys
        let oldControlURL = defaults.string(forKey: "tailscale.controlURL") ?? ""
        let oldHasKey = (try? keychainService.retrievePassword(account: "tailscale.preAuthKey")) != nil

        guard provider == nil, !oldControlURL.isEmpty, oldHasKey else { return }

        // Migrate as headscale (only provider before redesign)
        provider = .headscale
        controlURL = oldControlURL
        hostname = defaults.string(forKey: "tailscale.hostname") ?? Self.defaultHostname()
        isRegistered = true  // Existing account was already registered

        defaults.set(TailscaleProvider.headscale.rawValue, forKey: Self.providerKey)
        defaults.set(true, forKey: Self.isRegisteredKey)
    }

    // MARK: - Helpers

    private static func defaultHostname() -> String {
        let deviceName = UIDevice.current.name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return deviceName.isEmpty ? "muxi-ios" : "muxi-\(deviceName)"
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' -only-testing:MuxiTests/TailscaleAccountManagerTests 2>&1 | tail -20`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add ios/Muxi/Services/TailscaleAccountManager.swift \
        ios/MuxiTests/Services/TailscaleAccountManagerTests.swift
git commit -m "feat(tailscale): add TailscaleAccountManager with dual provider support

@MainActor @Observable class replacing TailscaleConfigStore. Supports
official Tailscale (OAuth tokens) and Headscale (pre-auth key + API key).
Per-provider isConfigured semantics, sign out, migration from old store."
```

---

## Task 3: TailscaleDeviceService

**Files:**
- Create: `ios/Muxi/Services/TailscaleDeviceService.swift`
- Test: `ios/MuxiTests/Services/TailscaleDeviceServiceTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// ios/MuxiTests/Services/TailscaleDeviceServiceTests.swift
import Testing
import Foundation
@testable import Muxi

@Suite("TailscaleDeviceService")
struct TailscaleDeviceServiceTests {
    @Test("Parse official Tailscale API response")
    func parseOfficialResponse() throws {
        let json = """
        {
            "devices": [
                {
                    "id": "node-abc123",
                    "hostname": "my-server",
                    "addresses": ["100.64.0.1", "fd7a:115c:a1e0::1"],
                    "os": "linux",
                    "online": true,
                    "lastSeen": "2026-03-22T10:00:00Z"
                },
                {
                    "id": "node-def456",
                    "hostname": "my-laptop",
                    "addresses": ["100.64.0.2"],
                    "os": "macOS",
                    "online": false,
                    "lastSeen": "2026-03-21T08:00:00Z"
                }
            ]
        }
        """.data(using: .utf8)!

        let devices = try TailscaleDeviceService.parseOfficialResponse(json)
        #expect(devices.count == 2)
        #expect(devices[0].id == "node-abc123")
        #expect(devices[0].name == "my-server")
        #expect(devices[0].isOnline == true)
        #expect(devices[0].os == "linux")
        #expect(devices[0].ipv4Address == "100.64.0.1")
    }

    @Test("Parse Headscale API response")
    func parseHeadscaleResponse() throws {
        let json = """
        {
            "machines": [
                {
                    "id": "1",
                    "givenName": "web-server",
                    "ipAddresses": ["100.64.0.10", "fd7a:115c:a1e0::a"],
                    "online": true,
                    "lastSeen": "2026-03-22T10:00:00Z"
                }
            ]
        }
        """.data(using: .utf8)!

        let devices = try TailscaleDeviceService.parseHeadscaleResponse(json)
        #expect(devices.count == 1)
        #expect(devices[0].id == "1")
        #expect(devices[0].name == "web-server")
        #expect(devices[0].ipv4Address == "100.64.0.10")
    }

    @Test("IPv4 address selection prefers IPv4 over IPv6")
    func ipv4Selection() {
        let device = TailscaleDevice(
            id: "1", name: "test",
            addresses: ["fd7a:115c:a1e0::1", "100.64.0.5"],
            isOnline: true, os: nil, lastSeen: nil
        )
        #expect(device.ipv4Address == "100.64.0.5")
    }

    @Test("IPv4 address falls back to first address if no IPv4")
    func ipv4Fallback() {
        let device = TailscaleDevice(
            id: "1", name: "test",
            addresses: ["fd7a:115c:a1e0::1"],
            isOnline: true, os: nil, lastSeen: nil
        )
        #expect(device.ipv4Address == "fd7a:115c:a1e0::1")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' -only-testing:MuxiTests/TailscaleDeviceServiceTests 2>&1 | tail -20`
Expected: FAIL — TailscaleDeviceService does not exist

- [ ] **Step 3: Implement TailscaleDeviceService**

```swift
// ios/Muxi/Services/TailscaleDeviceService.swift
import Foundation
import os

// MARK: - TailscaleDevice

struct TailscaleDevice: Identifiable, Sendable {
    let id: String
    let name: String
    let addresses: [String]
    let isOnline: Bool
    let os: String?
    let lastSeen: Date?

    var ipv4Address: String? {
        addresses.first(where: { $0.contains(".") }) ?? addresses.first
    }
}

// MARK: - TailscaleDeviceService

actor TailscaleDeviceService {
    private let logger = Logger(subsystem: "com.muxi.app", category: "TailscaleDeviceService")
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchDevices(account: TailscaleAccount, accessToken: String?, apiKey: String?) async throws -> [TailscaleDevice] {
        switch account.provider {
        case .official:
            guard let token = accessToken else {
                throw TailscaleDeviceError.missingCredentials
            }
            return try await fetchOfficialDevices(token: token)
        case .headscale:
            guard let key = apiKey else {
                throw TailscaleDeviceError.missingCredentials
            }
            return try await fetchHeadscaleDevices(controlURL: account.controlURL, apiKey: key)
        }
    }

    // MARK: - Official Tailscale API

    private func fetchOfficialDevices(token: String) async throws -> [TailscaleDevice] {
        var request = URLRequest(url: URL(string: "https://api.tailscale.com/api/v2/tailnet/-/devices")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw TailscaleDeviceError.apiFailed(status)
        }

        return try Self.parseOfficialResponse(data)
    }

    static func parseOfficialResponse(_ data: Data) throws -> [TailscaleDevice] {
        let decoded = try JSONDecoder.tailscaleDecoder.decode(OfficialDevicesResponse.self, from: data)
        return decoded.devices.map { d in
            TailscaleDevice(
                id: d.id, name: d.hostname,
                addresses: d.addresses,
                isOnline: d.online,
                os: d.os, lastSeen: d.lastSeen
            )
        }
    }

    // MARK: - Headscale API

    private func fetchHeadscaleDevices(controlURL: String, apiKey: String) async throws -> [TailscaleDevice] {
        guard let url = URL(string: "\(controlURL)/api/v1/machine") else {
            throw TailscaleDeviceError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw TailscaleDeviceError.apiFailed(status)
        }

        return try Self.parseHeadscaleResponse(data)
    }

    static func parseHeadscaleResponse(_ data: Data) throws -> [TailscaleDevice] {
        let decoded = try JSONDecoder.tailscaleDecoder.decode(HeadscaleDevicesResponse.self, from: data)
        return decoded.machines.map { m in
            TailscaleDevice(
                id: String(m.id), name: m.givenName,
                addresses: m.ipAddresses,
                isOnline: m.online,
                os: nil, lastSeen: m.lastSeen
            )
        }
    }
}

// MARK: - API Response Types

private struct OfficialDevicesResponse: Decodable {
    let devices: [OfficialDevice]
}

private struct OfficialDevice: Decodable {
    let id: String
    let hostname: String
    let addresses: [String]
    let online: Bool
    let os: String?
    let lastSeen: Date?
}

private struct HeadscaleDevicesResponse: Decodable {
    let machines: [HeadscaleMachine]
}

private struct HeadscaleMachine: Decodable {
    let id: Int
    let givenName: String
    let ipAddresses: [String]
    let online: Bool
    let lastSeen: Date?
}

// MARK: - Error

enum TailscaleDeviceError: Error, LocalizedError {
    case missingCredentials
    case invalidURL
    case apiFailed(Int)

    var errorDescription: String? {
        switch self {
        case .missingCredentials: "인증 정보가 없습니다"
        case .invalidURL: "잘못된 URL입니다"
        case .apiFailed(let code): "API 오류 (HTTP \(code))"
        }
    }
}

// MARK: - JSONDecoder Extension

private extension JSONDecoder {
    static let tailscaleDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' -only-testing:MuxiTests/TailscaleDeviceServiceTests 2>&1 | tail -20`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add ios/Muxi/Services/TailscaleDeviceService.swift \
        ios/MuxiTests/Services/TailscaleDeviceServiceTests.swift
git commit -m "feat(tailscale): add TailscaleDeviceService for API-based device discovery

Actor wrapping Tailscale and Headscale REST APIs. Parses device lists
with IPv4-preferred address selection. Supports both providers."
```

---

## Task 4: TailscaleDeviceListViewModel

**Files:**
- Create: `ios/Muxi/ViewModels/TailscaleDeviceListViewModel.swift`
- Test: `ios/MuxiTests/ViewModels/TailscaleDeviceListViewModelTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// ios/MuxiTests/ViewModels/TailscaleDeviceListViewModelTests.swift
import Testing
import Foundation
@testable import Muxi

/// Mock device service for testing.
private actor MockDeviceService {
    var devicesToReturn: [TailscaleDevice] = []
    var shouldThrow = false

    func fetchDevices() async throws -> [TailscaleDevice] {
        if shouldThrow { throw TailscaleDeviceError.apiFailed(500) }
        return devicesToReturn
    }
}

@Suite("TailscaleDeviceListViewModel")
@MainActor
struct TailscaleDeviceListViewModelTests {
    @Test("Initial state is idle")
    func initialState() {
        let vm = TailscaleDeviceListViewModel()
        #expect(vm.devices.isEmpty)
        #expect(vm.isLoading == false)
        #expect(vm.errorMessage == nil)
    }

    @Test("Search filters devices by name")
    func searchFilters() {
        let vm = TailscaleDeviceListViewModel()
        vm.devices = [
            TailscaleDevice(id: "1", name: "web-server", addresses: ["100.64.0.1"], isOnline: true, os: nil, lastSeen: nil),
            TailscaleDevice(id: "2", name: "db-server", addresses: ["100.64.0.2"], isOnline: true, os: nil, lastSeen: nil),
        ]
        vm.searchText = "web"
        #expect(vm.filteredDevices.count == 1)
        #expect(vm.filteredDevices[0].name == "web-server")
    }

    @Test("Empty search returns all devices")
    func emptySearchReturnsAll() {
        let vm = TailscaleDeviceListViewModel()
        vm.devices = [
            TailscaleDevice(id: "1", name: "web-server", addresses: ["100.64.0.1"], isOnline: true, os: nil, lastSeen: nil),
            TailscaleDevice(id: "2", name: "db-server", addresses: ["100.64.0.2"], isOnline: true, os: nil, lastSeen: nil),
        ]
        vm.searchText = ""
        #expect(vm.filteredDevices.count == 2)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' -only-testing:MuxiTests/TailscaleDeviceListViewModelTests 2>&1 | tail -20`
Expected: FAIL — TailscaleDeviceListViewModel does not exist

- [ ] **Step 3: Implement TailscaleDeviceListViewModel**

```swift
// ios/Muxi/ViewModels/TailscaleDeviceListViewModel.swift
import Foundation
import os

@MainActor @Observable
final class TailscaleDeviceListViewModel {
    private let deviceService = TailscaleDeviceService()
    private let logger = Logger(subsystem: "com.muxi.app", category: "TailscaleDeviceListVM")

    var devices: [TailscaleDevice] = []
    var searchText: String = ""
    var isLoading = false
    var errorMessage: String?

    var filteredDevices: [TailscaleDevice] {
        if searchText.isEmpty { return devices }
        let query = searchText.lowercased()
        return devices.filter {
            $0.name.lowercased().contains(query) ||
            $0.addresses.contains(where: { $0.contains(query) })
        }
    }

    func fetch(accountManager: TailscaleAccountManager) async {
        guard let account = accountManager.account else { return }

        isLoading = true
        errorMessage = nil

        do {
            devices = try await deviceService.fetchDevices(
                account: account,
                accessToken: accountManager.accessToken(),
                apiKey: accountManager.apiKey()
            )
            logger.info("Fetched \(self.devices.count) devices")
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Device fetch failed: \(error)")
        }

        isLoading = false
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' -only-testing:MuxiTests/TailscaleDeviceListViewModelTests 2>&1 | tail -20`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add ios/Muxi/ViewModels/TailscaleDeviceListViewModel.swift \
        ios/MuxiTests/ViewModels/TailscaleDeviceListViewModelTests.swift
git commit -m "feat(tailscale): add TailscaleDeviceListViewModel with search filtering

@MainActor @Observable ViewModel mediating between TailscaleDeviceService
actor and UI. Searchable by device name and IP address."
```

---

## Task 5: ConnectionManager — Auto-reconnect + tailscaleDeviceID Routing

**Files:**
- Modify: `ios/Muxi/Services/ConnectionManager.swift`
- Modify: `ios/MuxiTests/Services/ConnectionManagerTailscaleTests.swift`

- [ ] **Step 1: Update failing tests for tailscaleDeviceID routing**

```swift
// ios/MuxiTests/Services/ConnectionManagerTailscaleTests.swift
// Update existing tests: replace server.useTailscale = true with
// server.tailscaleDeviceID = "node-test"
// Replace all useTailscale references with tailscaleDeviceID != nil checks
```

Specific changes:
- `server.useTailscale = true` → `server.tailscaleDeviceID = "node-test"`
- `server.useTailscale = false` → leave `tailscaleDeviceID` as nil (default)
- Assert conditions based on `server.isTailscale`

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' -only-testing:MuxiTests/ConnectionManagerTailscaleTests 2>&1 | tail -20`
Expected: FAIL — `useTailscale` no longer exists on Server

- [ ] **Step 3: Update ConnectionManager — replace all useTailscale references**

In `ios/Muxi/Services/ConnectionManager.swift`, replace every `server.useTailscale` with `server.isTailscale`:

- Line ~410: `if server.useTailscale {` → `if server.isTailscale {`
- Line ~438: `if !server.useTailscale {` → `if !server.isTailscale {`
- Line ~446: `if server.useTailscale {` → `if server.isTailscale {`
- Line ~483: `attachOrCreate: server.useTailscale` → `attachOrCreate: server.isTailscale`

- [ ] **Step 4: Add auto-reconnect logic before dial**

In the `connect()` method, replace the hard guard:

```swift
// Before (hard fail):
guard tailscaleState == .connected else {
    throw TailscaleError.notConnected
}

// After (auto-reconnect):
if tailscaleState != .connected {
    connectingStatus = "Tailscale reconnecting..."
    logger.info("Tailscale not connected, attempting auto-reconnect")
    // accountManager is injected or accessible
    if let account = tailscaleAccountManager.account {
        let authKey: String?
        if account.provider == .official {
            authKey = nil // Use persisted node identity in stateDir
        } else {
            authKey = tailscaleAccountManager.preAuthKey() ?? ""
        }
        try await tailscaleService.start(
            controlURL: account.controlURL,
            authKey: authKey ?? "",
            hostname: account.hostname
        )
        tailscaleState = .connected
    } else {
        throw TailscaleError.notConnected
    }
}
```

- [ ] **Step 5: Add TailscaleAccountManager dependency to ConnectionManager**

Add property with default value to avoid breaking existing tests. Full init signature:

```swift
let tailscaleAccountManager: TailscaleAccountManager

init(
    sshService: SSHServiceProtocol? = nil,
    lastSessionStore: LastSessionStore = LastSessionStore(),
    maxReconnectAttempts: Int = 5,
    baseDelay: TimeInterval = 1.0,
    tailscaleAccountManager: TailscaleAccountManager = TailscaleAccountManager()
) {
    self.sshService = sshService ?? SSHService()
    self.lastSessionStore = lastSessionStore
    self.maxReconnectAttempts = maxReconnectAttempts
    self.baseDelay = baseDelay
    self.tailscaleAccountManager = tailscaleAccountManager
}
```

The default value ensures `ConnectionManagerTests`, `ConnectionManagerReconnectTests`, `ConnectionManagerHostKeyTests`, and `WindowTrackingTests` continue to compile without changes. The existing `SSHServiceProtocol?` optional pattern is preserved.

- [ ] **Step 6: Run tests to verify they pass**

Run: `xcodebuild test -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' -only-testing:MuxiTests/ConnectionManagerTailscaleTests 2>&1 | tail -20`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add ios/Muxi/Services/ConnectionManager.swift \
        ios/MuxiTests/Services/ConnectionManagerTailscaleTests.swift
git commit -m "feat(tailscale): update ConnectionManager for tailscaleDeviceID + auto-reconnect

Replace server.useTailscale with server.isTailscale (tailscaleDeviceID != nil).
Auto-reconnect Tailscale before dial if disconnected. Inject TailscaleAccountManager."
```

---

## Task 6: MuxiApp — Foreground Auto-reconnect

**Files:**
- Modify: `ios/Muxi/App/MuxiApp.swift`

- [ ] **Step 1: Add TailscaleAccountManager as @State and wire auto-reconnect**

```swift
// ios/Muxi/App/MuxiApp.swift
@main
struct MuxiApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var connectionManager: ConnectionManager
    @State private var tailscaleAccountManager = TailscaleAccountManager()

    init() {
        let accountManager = TailscaleAccountManager()
        _connectionManager = State(initialValue: ConnectionManager(tailscaleAccountManager: accountManager))
        _tailscaleAccountManager = State(initialValue: accountManager)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(connectionManager)
                .environment(tailscaleAccountManager)
                .preferredColorScheme(.dark)
                .tint(MuxiTokens.Colors.accentDefault)
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .background:
                        tailscaleAccountManager.lastConnected =
                            (connectionManager.tailscaleState == .connected)
                        connectionManager.handleBackground()
                    case .active:
                        Task {
                            await autoReconnectTailscaleIfNeeded()
                            connectionManager.handleForeground()
                        }
                    case .inactive:
                        break
                    @unknown default:
                        break
                    }
                }
        }
        .modelContainer(for: Server.self, migrationPlan: ServerMigrationPlan.self)
    }

    private func autoReconnectTailscaleIfNeeded() async {
        guard tailscaleAccountManager.lastConnected,
              tailscaleAccountManager.isConfigured,
              connectionManager.tailscaleState != .connected,
              let account = tailscaleAccountManager.account else { return }
        let authKey: String
        if account.provider == .official {
            authKey = "" // Uses persisted node identity
        } else {
            authKey = tailscaleAccountManager.preAuthKey() ?? ""
        }

        await connectionManager.startTailscale(
            controlURL: account.controlURL,
            authKey: authKey,
            hostname: account.hostname
        )
    }
}
```

- [ ] **Step 2: Update ContentView preview to include TailscaleAccountManager**

In `ios/Muxi/App/ContentView.swift`, add `.environment(TailscaleAccountManager())` to the `#Preview` block so previews don't crash when child views read from `@Environment(TailscaleAccountManager.self)`:

```swift
#Preview {
    ContentView()
        .environment(ConnectionManager())
        .environment(TailscaleAccountManager())
}
```

- [ ] **Step 3: Verify build succeeds**

Run: `xcodebuild build -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add ios/Muxi/App/MuxiApp.swift ios/Muxi/App/ContentView.swift
git commit -m "feat(tailscale): add foreground auto-reconnect and schema migration to MuxiApp

Save lastConnected on background, auto-reconnect on active if was connected.
Tailscale reconnect completes before SSH foreground reconnect runs.
ModelContainer configured with ServerMigrationPlan.
ContentView preview updated with TailscaleAccountManager environment."
```

---

## Task 7: TailscaleSetupSheet (Inline Wizard)

**Files:**
- Create: `ios/Muxi/Views/ServerEdit/TailscaleSetupSheet.swift`

- [ ] **Step 1: Implement TailscaleSetupSheet**

```swift
// ios/Muxi/Views/ServerEdit/TailscaleSetupSheet.swift
import SwiftUI
import AuthenticationServices

struct TailscaleSetupSheet: View {
    let accountManager: TailscaleAccountManager
    let connectionManager: ConnectionManager
    let onComplete: () -> Void

    @State private var step: SetupStep = .providerPicker
    @State private var controlURL = ""
    @State private var preAuthKey = ""
    @State private var apiKey = ""
    @State private var hostname = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?

    enum SetupStep {
        case providerPicker
        case headscaleForm
        case oauthLogin
        case connecting
    }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .providerPicker: providerPickerView
                case .headscaleForm: headscaleFormView
                case .oauthLogin: oauthLoginView
                case .connecting: connectingView
                }
            }
            .navigationTitle("Set up Tailscale")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(MuxiTokens.Colors.surfaceBase)
        }
    }

    // MARK: - Provider Picker

    @ViewBuilder
    private var providerPickerView: some View {
        List {
            Section {
                Button {
                    step = .oauthLogin
                } label: {
                    HStack {
                        Label("Tailscale", systemImage: "globe")
                            .foregroundStyle(MuxiTokens.Colors.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(MuxiTokens.Colors.textSecondary)
                    }
                }
                .listRowBackground(MuxiTokens.Colors.surfaceDefault)

                Button {
                    step = .headscaleForm
                } label: {
                    HStack {
                        Label("Headscale (Self-hosted)", systemImage: "server.rack")
                            .foregroundStyle(MuxiTokens.Colors.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(MuxiTokens.Colors.textSecondary)
                    }
                }
                .listRowBackground(MuxiTokens.Colors.surfaceDefault)
            } header: {
                Text("Provider")
            }
        }
    }

    // MARK: - Headscale Form

    @ViewBuilder
    private var headscaleFormView: some View {
        List {
            Section("Server") {
                TextField("Control URL", text: $controlURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .listRowBackground(MuxiTokens.Colors.surfaceDefault)
                    .foregroundStyle(MuxiTokens.Colors.textPrimary)
            }

            Section("Authentication") {
                SecureField("Pre-auth Key", text: $preAuthKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .listRowBackground(MuxiTokens.Colors.surfaceDefault)
                    .foregroundStyle(MuxiTokens.Colors.textPrimary)

                SecureField("API Key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .listRowBackground(MuxiTokens.Colors.surfaceDefault)
                    .foregroundStyle(MuxiTokens.Colors.textPrimary)
            }

            Section("Device") {
                TextField("Hostname", text: $hostname)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .listRowBackground(MuxiTokens.Colors.surfaceDefault)
                    .foregroundStyle(MuxiTokens.Colors.textPrimary)
            }

            if let error = errorMessage {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                        .listRowBackground(MuxiTokens.Colors.surfaceDefault)
                }
            }

            Section {
                Button(action: connectHeadscale) {
                    if isConnecting {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Connect")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(controlURL.isEmpty || preAuthKey.isEmpty || apiKey.isEmpty || isConnecting)
                .listRowBackground(MuxiTokens.Colors.surfaceDefault)
            }
        }
        .onAppear {
            if hostname.isEmpty {
                hostname = accountManager.hostname
            }
        }
    }

    // MARK: - OAuth Login

    @ViewBuilder
    private var oauthLoginView: some View {
        List {
            Section {
                Text("Tailscale 계정으로 로그인하여 기기 목록에 접근합니다.")
                    .foregroundStyle(MuxiTokens.Colors.textSecondary)
                    .listRowBackground(MuxiTokens.Colors.surfaceDefault)

                Button("Sign in with Tailscale") {
                    // TODO: ASWebAuthenticationSession OAuth flow
                    // This will be implemented when OAuth client is registered
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(MuxiTokens.Colors.surfaceDefault)
            }

            if let error = errorMessage {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                        .listRowBackground(MuxiTokens.Colors.surfaceDefault)
                }
            }
        }
    }

    // MARK: - Connecting

    @ViewBuilder
    private var connectingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Tailscale에 연결 중...")
                .foregroundStyle(MuxiTokens.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func connectHeadscale() {
        isConnecting = true
        errorMessage = nil

        accountManager.configureHeadscale(
            controlURL: controlURL,
            preAuthKey: preAuthKey,
            apiKey: apiKey,
            hostname: hostname
        )

        Task {
            await connectionManager.startTailscale(
                controlURL: controlURL,
                authKey: preAuthKey,
                hostname: hostname
            )

            if connectionManager.tailscaleState == .connected {
                accountManager.markRegistered()
                onComplete()
            } else if case .error(let msg) = connectionManager.tailscaleState {
                errorMessage = msg
            }
            isConnecting = false
        }
    }
}
```

- [ ] **Step 2: Verify build succeeds**

Run: `xcodebuild build -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add ios/Muxi/Views/ServerEdit/TailscaleSetupSheet.swift
git commit -m "feat(tailscale): add TailscaleSetupSheet inline wizard

Provider picker (Tailscale/Headscale), Headscale form with URL + keys,
OAuth placeholder, connecting state. Completes setup without leaving ServerEditView."
```

---

## Task 8: TailscaleDeviceListView

**Files:**
- Create: `ios/Muxi/Views/ServerEdit/TailscaleDeviceListView.swift`

- [ ] **Step 1: Implement TailscaleDeviceListView**

```swift
// ios/Muxi/Views/ServerEdit/TailscaleDeviceListView.swift
import SwiftUI

struct TailscaleDeviceListView: View {
    let accountManager: TailscaleAccountManager
    let onSelect: (TailscaleDevice) -> Void

    @State private var viewModel = TailscaleDeviceListViewModel()

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.devices.isEmpty {
                ProgressView("기기 목록 로딩 중...")
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else if let error = viewModel.errorMessage, viewModel.devices.isEmpty {
                errorView(error)
            } else {
                searchField
                deviceList
            }
        }
        .task {
            await viewModel.fetch(accountManager: accountManager)
        }
        .refreshable {
            await viewModel.fetch(accountManager: accountManager)
        }
    }

    @ViewBuilder
    private var deviceList: some View {
        ForEach(viewModel.filteredDevices) { device in
            Button {
                onSelect(device)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name)
                            .foregroundStyle(MuxiTokens.Colors.textPrimary)
                        if let ip = device.ipv4Address {
                            Text(ip)
                                .font(.caption)
                                .foregroundStyle(MuxiTokens.Colors.textSecondary)
                        }
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        if let os = device.os {
                            Text(os)
                                .font(.caption2)
                                .foregroundStyle(MuxiTokens.Colors.textSecondary)
                        }
                        Circle()
                            .fill(device.isOnline ? .green : MuxiTokens.Colors.textSecondary)
                            .frame(width: 8, height: 8)
                    }
                }
            }
            .listRowBackground(MuxiTokens.Colors.surfaceDefault)
        }
    }

    // Note: .searchable requires NavigationStack/List level placement.
    // Since this view is embedded in ServerEditView's Form, use a TextField-based
    // search instead to avoid nested-List rendering issues.
    @ViewBuilder
    private var searchField: some View {
        TextField("기기 검색", text: $viewModel.searchText)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .listRowBackground(MuxiTokens.Colors.surfaceDefault)
            .foregroundStyle(MuxiTokens.Colors.textPrimary)
    }

    @ViewBuilder
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(message)
                .foregroundStyle(.red)
            Button("재시도") {
                Task { await viewModel.fetch(accountManager: accountManager) }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 100)
    }
}
```

- [ ] **Step 2: Verify build succeeds**

Run: `xcodebuild build -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add ios/Muxi/Views/ServerEdit/TailscaleDeviceListView.swift
git commit -m "feat(tailscale): add TailscaleDeviceListView with searchable device picker

Shows tailnet devices with name, IP, online status, OS. Searchable.
Pull-to-refresh via .task. Error state with retry."
```

---

## Task 9: ServerEditView — Connection Method Picker + Tailscale Integration

**Files:**
- Modify: `ios/Muxi/Views/ServerEdit/ServerEditView.swift`

- [ ] **Step 1: Add connection method picker and Tailscale device selection**

Replace the "Network" section (Tailscale toggle) with:

```swift
// Connection method segmented control at top of form
Section("Connection") {
    Picker("Method", selection: $connectionMethod) {
        Text("Direct").tag(ConnectionMethod.direct)
        Text("Tailscale").tag(ConnectionMethod.tailscale)
    }
    .pickerStyle(.segmented)
    .listRowBackground(MuxiTokens.Colors.surfaceDefault)
}

// If Tailscale selected:
if connectionMethod == .tailscale {
    if tailscaleAccountManager.isConfigured {
        Section("Tailscale Device") {
            TailscaleDeviceListView(accountManager: tailscaleAccountManager) { device in
                selectedDevice = device
                host = device.ipv4Address ?? ""
                name = name.isEmpty ? device.name : name
            }
        }
        if let device = selectedDevice {
            Section("Selected") {
                HStack {
                    Text(device.name)
                        .foregroundStyle(MuxiTokens.Colors.textPrimary)
                    Spacer()
                    Text(device.ipv4Address ?? "")
                        .foregroundStyle(MuxiTokens.Colors.textSecondary)
                }
                .listRowBackground(MuxiTokens.Colors.surfaceDefault)
            }
        }
    } else {
        Section("Tailscale") {
            Button("Set up Tailscale") {
                showSetupSheet = true
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(MuxiTokens.Colors.surfaceDefault)
        }
    }
}
```

Add state properties:
```swift
enum ConnectionMethod { case direct, tailscale }
@State private var connectionMethod: ConnectionMethod = .direct
@State private var selectedDevice: TailscaleDevice?
@State private var showSetupSheet = false
```

Add environment dependencies:
```swift
@Environment(TailscaleAccountManager.self) private var tailscaleAccountManager
@Environment(ConnectionManager.self) private var connectionManager
```

Update `save()` — set `tailscaleDeviceID` and `tailscaleDeviceName` from selected device.
Update `loadServer()` — set `connectionMethod` from `server.isTailscale`.

- [ ] **Step 2: Remove old Network section (useTailscale toggle)**

Delete the entire `Section("Network")` block that contained the `Toggle(isOn: $useTailscale)`.
Remove `@State private var useTailscale = false`.

- [ ] **Step 3: Add .sheet for TailscaleSetupSheet**

```swift
.sheet(isPresented: $showSetupSheet) {
    TailscaleSetupSheet(
        accountManager: tailscaleAccountManager,
        connectionManager: connectionManager
    ) {
        showSetupSheet = false
    }
}
```

- [ ] **Step 4: Verify build succeeds**

Run: `xcodebuild build -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add ios/Muxi/Views/ServerEdit/ServerEditView.swift
git commit -m "feat(tailscale): redesign ServerEditView with connection method picker

Segmented control (Direct/Tailscale) replaces toggle. Tailscale path shows
inline device list or setup wizard sheet. Auto-fills host/name from selected device."
```

---

## Task 10: TailscaleSettingsView — Simplify to Account Management

**Files:**
- Modify: `ios/Muxi/Views/Settings/TailscaleSettingsView.swift`
- Modify: `ios/Muxi/Views/Settings/SettingsView.swift`

- [ ] **Step 1: Rewrite TailscaleSettingsView**

Replace entire file with account management view:

```swift
// ios/Muxi/Views/Settings/TailscaleSettingsView.swift
import SwiftUI

struct TailscaleSettingsView: View {
    @Environment(TailscaleAccountManager.self) private var accountManager
    @Environment(ConnectionManager.self) private var connectionManager

    var body: some View {
        List {
            if accountManager.provider != nil {
                accountSection
                actionsSection
            } else {
                noAccountSection
            }
        }
        .scrollContentBackground(.hidden)
        .background(MuxiTokens.Colors.surfaceBase)
        .navigationTitle("Tailscale")
    }

    @ViewBuilder
    private var accountSection: some View {
        Section("Account") {
            row("Provider", value: providerText)
            row("Status", value: statusText, color: statusColor)
            row("This device", value: accountManager.hostname)
            if accountManager.provider == .headscale {
                row("Control URL", value: accountManager.controlURL)
            }
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        Section {
            Button(action: toggleConnection) {
                Text(isConnected ? "Disconnect" : "Connect")
                    .frame(maxWidth: .infinity)
            }
            .disabled(connectionManager.tailscaleState == .connecting)
            .listRowBackground(MuxiTokens.Colors.surfaceDefault)

            Button(role: .destructive) {
                Task {
                    await connectionManager.stopTailscale()
                    accountManager.signOut()
                }
            } label: {
                Text("Sign Out")
                    .frame(maxWidth: .infinity)
            }
            .listRowBackground(MuxiTokens.Colors.surfaceDefault)
        }
    }

    @ViewBuilder
    private var noAccountSection: some View {
        Section {
            Text("Tailscale 계정이 설정되지 않았습니다.\n서버 추가 시 Tailscale을 선택하면 설정할 수 있습니다.")
                .foregroundStyle(MuxiTokens.Colors.textSecondary)
                .listRowBackground(MuxiTokens.Colors.surfaceDefault)
        }
    }

    private func row(_ label: String, value: String, color: Color = MuxiTokens.Colors.textSecondary) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(MuxiTokens.Colors.textPrimary)
            Spacer()
            Text(value)
                .foregroundStyle(color)
        }
        .listRowBackground(MuxiTokens.Colors.surfaceDefault)
    }

    private var isConnected: Bool {
        connectionManager.tailscaleState == .connected
    }

    private var providerText: String {
        switch accountManager.provider {
        case .official: "Tailscale"
        case .headscale: "Headscale (Self-hosted)"
        case nil: "—"
        }
    }

    private var statusText: String {
        switch connectionManager.tailscaleState {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .error(let msg): msg
        }
    }

    private var statusColor: Color {
        switch connectionManager.tailscaleState {
        case .connected: .green
        case .error: .red
        default: MuxiTokens.Colors.textSecondary
        }
    }

    private func toggleConnection() {
        Task {
            if isConnected {
                await connectionManager.stopTailscale()
            } else if let account = accountManager.account {
                let authKey: String
                if account.provider == .official {
                    authKey = ""
                } else {
                    authKey = accountManager.preAuthKey() ?? ""
                }
                await connectionManager.startTailscale(
                    controlURL: account.controlURL,
                    authKey: authKey,
                    hostname: account.hostname
                )
            }
        }
    }
}
```

- [ ] **Step 2: Update SettingsView — remove connectionManager dependency from TailscaleSettingsView init**

The `TailscaleSettingsView` now reads `ConnectionManager` and `TailscaleAccountManager` from environment, so the `SettingsView` NavigationLink simplifies:

```swift
NavigationLink {
    TailscaleSettingsView()
} label: { ... }
```

Update `tailscaleStatusText` and `tailscaleStatusColor` to remain unchanged (they read from `connectionManager` which is still passed as a parameter).

- [ ] **Step 3: Verify build succeeds**

Run: `xcodebuild build -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add ios/Muxi/Views/Settings/TailscaleSettingsView.swift \
        ios/Muxi/Views/Settings/SettingsView.swift
git commit -m "feat(tailscale): simplify TailscaleSettingsView to account management only

Shows provider, status, hostname, disconnect/sign-out. No more config fields.
Account setup happens via ServerEditView wizard. Reads from environment."
```

---

## Task 11: Cleanup — Remove Old Code + Update Tests

**Files:**
- Delete: `ios/Muxi/Services/TailscaleConfigStore.swift`
- Delete: `ios/MuxiTests/Services/TailscaleConfigStoreTests.swift`
- Modify: `ios/MuxiTests/Services/ConnectionManagerTailscaleTests.swift` (final verification)

- [ ] **Step 1: Delete TailscaleConfigStore and its tests**

```bash
git rm ios/Muxi/Services/TailscaleConfigStore.swift
git rm ios/MuxiTests/Services/TailscaleConfigStoreTests.swift
```

- [ ] **Step 2: Fix any remaining compilation errors**

Search for remaining references to `TailscaleConfigStore`:
- `ServerEditView.swift` — already replaced in Task 9
- `TailscaleSettingsView.swift` — already replaced in Task 10
- Any other files — update to use `TailscaleAccountManager`

- [ ] **Step 3: Run full test suite**

Run: `xcodebuild test -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' 2>&1 | tail -30`
Expected: All tests PASS

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "chore(tailscale): remove TailscaleConfigStore, replaced by TailscaleAccountManager

Delete old config store and tests. All references updated to use
TailscaleAccountManager. Full test suite passing."
```

---

## Task 12: Integration Verification

- [ ] **Step 1: Run full test suite one final time**

Run: `xcodebuild test -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' 2>&1 | tail -30`
Expected: All tests PASS

- [ ] **Step 2: Add Tailscale badge to server list**

In the server list view, add a Tailscale icon badge for servers with `server.isTailscale`:

```swift
if server.isTailscale {
    Image(systemName: "network")
        .font(.caption2)
        .foregroundStyle(MuxiTokens.Colors.textSecondary)
}
```

- [ ] **Step 3: Update ARCHITECTURE.md if needed**

Check if Tailscale section needs updating for new components (TailscaleAccountManager, TailscaleDeviceService, TailscaleDeviceListViewModel).

- [ ] **Step 4: Update CHANGELOG.md**

Add under "Changed":
- Tailscale UX redesigned: inline wizard, API device discovery, auto-reconnect
- Official Tailscale (OAuth) support alongside Headscale
- Server model migrated from `useTailscale` to `tailscaleDeviceID`

- [ ] **Step 5: Final commit**

```bash
git add docs/
git commit -m "docs: update ARCHITECTURE.md and CHANGELOG.md for Tailscale UX redesign"
```
