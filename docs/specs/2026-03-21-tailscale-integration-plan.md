# Tailscale Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Embed a Tailscale node (libtailscale via gomobile) into Muxi so users can SSH to Headscale/Tailscale machines without a separate VPN app.

**Architecture:** A new `TailscaleService` actor wraps the libtailscale C API. Its `dial()` returns a file descriptor that SSHService uses in place of a POSIX socket via `libssh2_session_handshake(session, fd)`. Headscale config is stored in UserDefaults (URL, hostname) + Keychain (pre-auth key). Each `Server` gets a `useTailscale: Bool` toggle.

**Tech Stack:** libtailscale (C API via gomobile xcframework), Swift actors, SwiftUI, SwiftData, Keychain

**Spec:** `docs/specs/2026-03-21-tailscale-integration-design.md`

---

## File Map

### New files

| File | Responsibility |
|------|---------------|
| `scripts/build-libtailscale.sh` | Build libtailscale xcframework via gomobile |
| `ios/Muxi/Services/TailscaleService.swift` | Actor wrapping libtailscale C API — start/stop/dial |
| `ios/Muxi/Services/TailscaleConfigStore.swift` | Headscale config persistence (UserDefaults + Keychain) |
| `ios/Muxi/Views/Settings/TailscaleSettingsView.swift` | Settings UI for Headscale URL, pre-auth key, hostname, connect/disconnect |
| `ios/MuxiTests/Services/TailscaleConfigStoreTests.swift` | Unit tests for config store |
| `ios/MuxiTests/Services/TailscaleServiceTests.swift` | Unit tests for TailscaleService state machine |
| `ios/MuxiTests/Services/ConnectionManagerTailscaleTests.swift` | Integration tests for Tailscale connection flow |
| `docs/decisions/0009-tailscale-embedded-userspace.md` | ADR for this decision |

### Modified files

| File | Change |
|------|--------|
| `scripts/build-all.sh` | Add Step 3: build-libtailscale.sh |
| `ios/project.yml` | Add libtailscale.xcframework dependency (`embed: true`) |
| `ios/Muxi/Models/Server.swift` | Add `var useTailscale: Bool = false` |
| `ios/Muxi/Services/SSHService.swift` | Add `tailscaleFD` param to protocol + connect(); add `isTailscaleFD` flag; skip `close()` for Tailscale fds |
| `ios/Muxi/Services/ConnectionManager.swift` | Add `TailscaleService` integration in connect flow; add `tailscaleState` property |
| `ios/Muxi/Views/Settings/SettingsView.swift` | Add Tailscale section with NavigationLink |
| `ios/Muxi/Views/ServerEdit/ServerEditView.swift` | Add `useTailscale` toggle in form |
| `ios/Muxi/App/ContentView.swift` | Pass `connectionManager` to `SettingsView` (line 179) |
| `ios/MuxiTests/Services/SSHServiceTests.swift` | Update MockSSHService for new `tailscaleFD` param |
| `ios/MuxiTests/Services/ConnectionManagerHostKeyTests.swift` | Update HostKeyMockSSHService for new param |
| `ios/MuxiTests/Services/ConnectionManagerReconnectTests.swift` | Update ReconnectMockSSHService for new param |
| `ios/MuxiTests/Models/ServerModelTests.swift` | Add `useTailscale` default test |
| `ios/Muxi/App/ContentView.swift` | Pass `connectionManager` to `SettingsView` (line 179) |
| `docs/ARCHITECTURE.md` | Add TailscaleService to App Layer |
| `CHANGELOG.md` | Add Tailscale integration entry |

---

### Task 1: TailscaleConfigStore — data persistence

**Files:**
- Create: `ios/Muxi/Services/TailscaleConfigStore.swift`
- Create: `ios/MuxiTests/Services/TailscaleConfigStoreTests.swift`

- [ ] **Step 1: Write failing tests for config store**

Create test file `ios/MuxiTests/Services/TailscaleConfigStoreTests.swift`:

```swift
import Testing
@testable import Muxi

@Suite("TailscaleConfigStore")
struct TailscaleConfigStoreTests {

    private func makeStore() -> TailscaleConfigStore {
        let defaults = UserDefaults(suiteName: "TailscaleConfigStoreTests")!
        defaults.removePersistentDomain(forName: "TailscaleConfigStoreTests")
        return TailscaleConfigStore(defaults: defaults, keychainService: KeychainService())
    }

    @Test("Save and load controlURL")
    func saveLoadControlURL() {
        let store = makeStore()
        store.controlURL = "https://hs.example.com"
        #expect(store.controlURL == "https://hs.example.com")
    }

    @Test("Save and load hostname")
    func saveLoadHostname() {
        let store = makeStore()
        store.hostname = "muxi-iphone"
        #expect(store.hostname == "muxi-iphone")
    }

    @Test("Default hostname from device name")
    func defaultHostname() {
        let store = makeStore()
        #expect(store.hostname.isEmpty == false)
    }

    @Test("isConfigured requires controlURL and preAuthKey")
    func isConfigured() {
        let store = makeStore()
        #expect(store.isConfigured == false)
        store.controlURL = "https://hs.example.com"
        #expect(store.isConfigured == false)
        // preAuthKey requires Keychain — tested separately on device
    }

    @Test("Clear removes all config")
    func clearConfig() {
        let store = makeStore()
        store.controlURL = "https://hs.example.com"
        store.hostname = "test"
        store.clear()
        #expect(store.controlURL == "")
        #expect(store.hostname != "test")  // reverts to default
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' -only-testing:MuxiTests/TailscaleConfigStoreTests 2>&1 | tail -20`

Expected: Compile error — `TailscaleConfigStore` not found.

- [ ] **Step 3: Implement TailscaleConfigStore**

Create `ios/Muxi/Services/TailscaleConfigStore.swift`:

```swift
import Foundation
import UIKit

/// Persists Headscale configuration (controlURL, hostname in UserDefaults;
/// pre-auth key in Keychain).
struct TailscaleConfigStore {
    private let defaults: UserDefaults
    private let keychainService: KeychainService

    private static let controlURLKey = "tailscale.controlURL"
    private static let hostnameKey = "tailscale.hostname"
    private static let preAuthKeyAccount = "tailscale.preAuthKey"

    init(defaults: UserDefaults = .standard, keychainService: KeychainService = KeychainService()) {
        self.defaults = defaults
        self.keychainService = keychainService
    }

    var controlURL: String {
        get { defaults.string(forKey: Self.controlURLKey) ?? "" }
        set { defaults.set(newValue, forKey: Self.controlURLKey) }
    }

    var hostname: String {
        get {
            let stored = defaults.string(forKey: Self.hostnameKey) ?? ""
            if stored.isEmpty {
                return Self.defaultHostname()
            }
            return stored
        }
        set { defaults.set(newValue, forKey: Self.hostnameKey) }
    }

    var preAuthKey: String {
        get { (try? keychainService.retrievePassword(account: Self.preAuthKeyAccount)) ?? "" }
        set {
            if newValue.isEmpty {
                try? keychainService.deletePassword(account: Self.preAuthKeyAccount)
            } else {
                try? keychainService.savePassword(newValue, account: Self.preAuthKeyAccount)
            }
        }
    }

    var isConfigured: Bool {
        !controlURL.isEmpty && !preAuthKey.isEmpty
    }

    func clear() {
        defaults.removeObject(forKey: Self.controlURLKey)
        defaults.removeObject(forKey: Self.hostnameKey)
        try? keychainService.deletePassword(account: Self.preAuthKeyAccount)
    }

    private static func defaultHostname() -> String {
        let deviceName = UIDevice.current.name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return deviceName.isEmpty ? "muxi-ios" : "muxi-\(deviceName)"
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' -only-testing:MuxiTests/TailscaleConfigStoreTests 2>&1 | tail -20`

Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/Muxi/Services/TailscaleConfigStore.swift ios/MuxiTests/Services/TailscaleConfigStoreTests.swift
git commit -m "feat(tailscale): add TailscaleConfigStore for Headscale config persistence"
```

---

### Task 2: Server model — add useTailscale field

**Files:**
- Modify: `ios/Muxi/Models/Server.swift`
- Existing test: `ios/MuxiTests/Models/ServerModelTests.swift`

- [ ] **Step 1: Write failing test for useTailscale default**

Add to `ios/MuxiTests/Models/ServerModelTests.swift`:

```swift
@Test("useTailscale defaults to false")
func useTailscaleDefault() {
    let server = Server(name: "test", host: "10.0.0.1", username: "root", authMethod: .password)
    #expect(server.useTailscale == false)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' -only-testing:MuxiTests/ServerModelTests 2>&1 | tail -20`

Expected: Compile error — `useTailscale` not found on `Server`.

- [ ] **Step 3: Add useTailscale to Server model**

In `ios/Muxi/Models/Server.swift`, add the field to the `Server` class (after `hostKeyFingerprint`):

```swift
/// Whether SSH connections to this server should route through Tailscale.
var useTailscale: Bool = false
```

SwiftData lightweight migration handles this automatically (additive field with default value).

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' -only-testing:MuxiTests/ServerModelTests 2>&1 | tail -20`

Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/Muxi/Models/Server.swift ios/MuxiTests/Models/ServerModelTests.swift
git commit -m "feat(tailscale): add useTailscale field to Server model"
```

---

### Task 3: SSHServiceProtocol + SSHService + all mocks — fd passthrough (atomic)

> **Note:** This task modifies the protocol and ALL conformances in a single commit to avoid a broken intermediate state.

**Files:**
- Modify: `ios/Muxi/Services/SSHService.swift` (protocol at line 118, connect at line 304, cleanupSession at line 820)
- Modify: `ios/MuxiTests/Services/SSHServiceTests.swift` (MockSSHService at line 96)
- Modify: `ios/MuxiTests/Services/ConnectionManagerHostKeyTests.swift` (HostKeyMockSSHService at line 5)
- Modify: `ios/MuxiTests/Services/ConnectionManagerReconnectTests.swift` (ReconnectMockSSHService at line 10)

> **Spec deviation:** `TailscaleState` is defined as a top-level enum (not nested `TailscaleService.State`) for ergonomic access from `ConnectionManager` and UI.

- [ ] **Step 1: Update SSHServiceProtocol**

In `ios/Muxi/Services/SSHService.swift`, update the protocol's `connect` method (line 141):

```swift
/// Open an SSH connection to the given host.
/// - Parameter tailscaleFD: If non-nil, use this file descriptor (from TailscaleService)
///   instead of creating a new POSIX socket. SSHService must NOT close this fd.
func connect(host: String, port: UInt16, username: String, auth: SSHAuth, expectedFingerprint: String?, tailscaleFD: Int32?) async throws
```

- [ ] **Step 2: Add isTailscaleFD property to SSHService**

In `ios/Muxi/Services/SSHService.swift`, after `private var socketFd: Int32 = -1` (line 281), add:

```swift
/// When true, socketFd was provided by TailscaleService and must NOT be closed by us.
private var isTailscaleFD: Bool = false
```

- [ ] **Step 3: Update SSHService.connect() for fd passthrough**

In `ios/Muxi/Services/SSHService.swift`, update the `connect` method signature (line 304) to accept `tailscaleFD`:

```swift
func connect(
    host: String,
    port: UInt16,
    username: String,
    auth: SSHAuth,
    expectedFingerprint: String? = nil,
    tailscaleFD: Int32? = nil
) async throws {
```

After `updateState(.connecting)` (line 320) and before DNS resolution (line 329), add the fd passthrough branch:

```swift
if let fd = tailscaleFD {
    // Use the Tailscale-provided fd — skip DNS resolution, socket creation, and connect.
    socketFd = fd
    isTailscaleFD = true
    sshLog.info("Using Tailscale fd=\(fd) for \(host):\(port)")
} else {
    isTailscaleFD = false
    // Existing DNS resolution + socket creation + connect code follows...
```

Wrap the existing DNS/socket/connect code (lines 329–378) inside the `else` block.

- [ ] **Step 4: Update cleanupSession() to respect isTailscaleFD**

In `ios/Muxi/Services/SSHService.swift`, modify `cleanupSession()` (line 830):

```swift
if socketFd >= 0 {
    if !isTailscaleFD {
        Darwin.close(socketFd)
    }
    socketFd = -1
    isTailscaleFD = false
}
```

- [ ] **Step 5: Update MockSSHService in SSHServiceTests.swift**

In `ios/MuxiTests/Services/SSHServiceTests.swift`, update the `connect` method in `MockSSHService` (line 116):

```swift
func connect(host: String, port: UInt16, username: String, auth: SSHAuth, expectedFingerprint: String? = nil, tailscaleFD: Int32? = nil) async throws {
    if let error = mockConnectError { throw error }
    state = .connected
}
```

- [ ] **Step 6: Update HostKeyMockSSHService in ConnectionManagerHostKeyTests.swift**

In `ios/MuxiTests/Services/ConnectionManagerHostKeyTests.swift`, update the `connect` method (line 23):

```swift
func connect(
    host: String,
    port: UInt16,
    username: String,
    auth: SSHAuth,
    expectedFingerprint: String? = nil,
    tailscaleFD: Int32? = nil
) async throws {
```

- [ ] **Step 7: Update ReconnectMockSSHService in ConnectionManagerReconnectTests.swift**

In `ios/MuxiTests/Services/ConnectionManagerReconnectTests.swift`, update the `connect` method (line 29):

```swift
func connect(host: String, port: UInt16, username: String, auth: SSHAuth, expectedFingerprint: String? = nil, tailscaleFD: Int32? = nil) async throws {
    connectCallCount += 1
    if connectCallCount <= shouldFailConnectCount {
        throw SSHError.connectionFailed("simulated failure #\(connectCallCount)")
    }
    state = .connected
}
```

- [ ] **Step 8: Verify all existing tests pass**

Run: `xcodebuild test -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' 2>&1 | tail -30`

Expected: All existing tests PASS.

- [ ] **Step 9: Commit**

```bash
git add ios/Muxi/Services/SSHService.swift ios/MuxiTests/
git commit -m "feat(tailscale): add tailscaleFD passthrough to SSHServiceProtocol + all conformances"
```

---

### Task 4: TailscaleService — actor with state machine

**Files:**
- Create: `ios/Muxi/Services/TailscaleService.swift`
- Create: `ios/MuxiTests/Services/TailscaleServiceTests.swift`

- [ ] **Step 1: Write failing tests for TailscaleService state machine**

Create `ios/MuxiTests/Services/TailscaleServiceTests.swift`:

```swift
import Testing
@testable import Muxi

@Suite("TailscaleService")
struct TailscaleServiceTests {

    @Test("Initial state is disconnected")
    func initialState() async {
        let service = TailscaleService()
        let state = await service.state
        #expect(state == .disconnected)
    }

    @Test("State transitions to connecting on start")
    func startTransitionsToConnecting() async throws {
        let service = TailscaleService()
        // Without actual libtailscale, start will fail — but state should transition to connecting first
        do {
            try await service.start(controlURL: "https://invalid.test", authKey: "test-key", hostname: "test")
        } catch {
            // Expected to fail without real libtailscale
        }
        let state = await service.state
        // State should be .error after failed start
        if case .error = state {
            // OK
        } else if state == .disconnected {
            // Also acceptable if start failed immediately
        } else {
            Issue.record("Unexpected state after failed start: \(state)")
        }
    }

    @Test("Stop returns to disconnected")
    func stopReturnsToDisconnected() async {
        let service = TailscaleService()
        await service.stop()
        let state = await service.state
        #expect(state == .disconnected)
    }

    @Test("Dial throws when not connected")
    func dialThrowsWhenNotConnected() async {
        let service = TailscaleService()
        await #expect(throws: TailscaleError.notConnected) {
            _ = try await service.dial(host: "100.64.0.1", port: 22)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' -only-testing:MuxiTests/TailscaleServiceTests 2>&1 | tail -20`

Expected: Compile error — `TailscaleService` not found.

- [ ] **Step 3: Implement TailscaleService**

Create `ios/Muxi/Services/TailscaleService.swift`:

```swift
import Foundation
import os

// MARK: - TailscaleError

enum TailscaleError: Error, Equatable {
    case notConnected
    case dialFailed(String)
    case startFailed(String)
}

// MARK: - TailscaleState

enum TailscaleState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case error(String)
}

// MARK: - TailscaleService

/// Manages an embedded Tailscale node via the libtailscale C API.
///
/// Uses tsnet userspace networking — does NOT consume the system VPN slot.
/// The `dial()` method returns a file descriptor that can be passed directly
/// to `libssh2_session_handshake()`.
///
/// **fd ownership:** TailscaleService owns all fds returned by `dial()`.
/// Callers must NOT call `close()` on them.
actor TailscaleService {
    private let logger = Logger(subsystem: "com.muxi.app", category: "TailscaleService")

    private(set) var state: TailscaleState = .disconnected

    /// Opaque handle to the libtailscale server instance.
    private var tsHandle: Int32 = -1

    /// File descriptors created by dial(), tracked for cleanup.
    private var activeFDs: Set<Int32> = []

    /// Persistent state directory for WireGuard keys and node identity.
    private var stateDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("tailscale", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDir = dir
        try? mutableDir.setResourceValues(values)
        return dir
    }

    // MARK: - Lifecycle

    /// Start the Tailscale node and connect to the Headscale control server.
    func start(controlURL: String, authKey: String, hostname: String) async throws {
        guard state == .disconnected || isErrorState else {
            logger.warning("start() called in state \(String(describing: self.state))")
            return
        }

        state = .connecting
        logger.info("Starting Tailscale node, control=\(controlURL) hostname=\(hostname)")

        // TODO: Replace with actual libtailscale C API calls when framework is built:
        //   tsHandle = tailscale_new()
        //   tailscale_set_dir(tsHandle, stateDir.path)
        //   tailscale_set_hostname(tsHandle, hostname)
        //   tailscale_set_authkey(tsHandle, authKey)
        //   tailscale_set_control_url(tsHandle, controlURL)
        //   let rc = tailscale_up(tsHandle)
        //   if rc != 0 { throw TailscaleError.startFailed(errMsg) }

        state = .error("libtailscale framework not yet linked")
        throw TailscaleError.startFailed("libtailscale framework not yet linked")
    }

    /// Stop the Tailscale node and clean up resources.
    func stop() {
        logger.info("Stopping Tailscale node")

        // Close all tracked fds
        for fd in activeFDs {
            Darwin.close(fd)
        }
        activeFDs.removeAll()

        // TODO: Replace with actual libtailscale C API calls:
        //   if tsHandle >= 0 {
        //       tailscale_close(tsHandle)
        //       tsHandle = -1
        //   }

        tsHandle = -1
        state = .disconnected
    }

    // MARK: - Dial

    /// Connect to a Tailscale peer and return a file descriptor.
    ///
    /// The returned fd is suitable for `libssh2_session_handshake(session, fd)`.
    /// **Caller must NOT close this fd** — TailscaleService manages its lifecycle.
    ///
    /// - Returns: A file descriptor connected to the peer.
    func dial(host: String, port: UInt16) async throws -> Int32 {
        guard state == .connected else {
            throw TailscaleError.notConnected
        }

        logger.info("Dialing \(host):\(port) via Tailscale")

        // TODO: Replace with actual libtailscale C API call:
        //   var conn: Int32 = -1
        //   let rc = tailscale_dial(tsHandle, "tcp", "\(host):\(port)", &conn)
        //   if rc != 0 { throw TailscaleError.dialFailed(errMsg) }
        //   activeFDs.insert(conn)
        //   return conn

        throw TailscaleError.dialFailed("libtailscale framework not yet linked")
    }

    /// Release a specific fd from tracking (called when SSH disconnects cleanly).
    func releaseFD(_ fd: Int32) {
        activeFDs.remove(fd)
    }

    // MARK: - Helpers

    private var isErrorState: Bool {
        if case .error = state { return true }
        return false
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' -only-testing:MuxiTests/TailscaleServiceTests 2>&1 | tail -20`

Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/Muxi/Services/TailscaleService.swift ios/MuxiTests/Services/TailscaleServiceTests.swift
git commit -m "feat(tailscale): add TailscaleService actor with state machine"
```

---

### Task 5: ConnectionManager — Tailscale integration

**Files:**
- Modify: `ios/Muxi/Services/ConnectionManager.swift` (lines 40-46 for properties, line 388 for connect)
- Create: `ios/MuxiTests/Services/ConnectionManagerTailscaleTests.swift`

- [ ] **Step 1: Write failing tests for Tailscale connection flow**

Create `ios/MuxiTests/Services/ConnectionManagerTailscaleTests.swift`:

```swift
import XCTest
@testable import Muxi

/// Mock SSHService for Tailscale-specific tests.
private final class TailscaleMockSSHService: SSHServiceProtocol {
    var state: SSHConnectionState = .disconnected
    var lastTailscaleFD: Int32?

    func connect(host: String, port: UInt16, username: String, auth: SSHAuth, expectedFingerprint: String? = nil, tailscaleFD: Int32? = nil) async throws {
        lastTailscaleFD = tailscaleFD
        state = .connected
    }

    func disconnect() { state = .disconnected }
    func execCommand(_ command: String) async throws -> String { "" }
    func startShell(onData: @escaping (Data) -> Void) async throws -> SSHChannel {
        fatalError("Not used in these tests")
    }
    func writeToChannel(_ data: Data) async throws {}
    func closeShell() async {}
}

@MainActor
final class ConnectionManagerTailscaleTests: XCTestCase {

    func testConnectWithTailscaleBlockedWhenNotConnected() async {
        let mockSSH = TailscaleMockSSHService()
        let cm = ConnectionManager(sshService: mockSSH)

        let server = Server(name: "ts-server", host: "100.64.0.1", username: "root", authMethod: .password)
        server.useTailscale = true

        // Tailscale is disconnected — connect should throw TailscaleError.notConnected
        do {
            try await cm.connect(server: server, password: "test")
            XCTFail("Expected TailscaleError.notConnected")
        } catch let error as TailscaleError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertNil(mockSSH.lastTailscaleFD, "SSH should not be called when Tailscale is not connected")
    }

    func testConnectWithoutTailscalePassesNilFD() async throws {
        let mockSSH = TailscaleMockSSHService()
        let cm = ConnectionManager(sshService: mockSSH)

        let server = Server(name: "direct-server", host: "192.168.1.1", username: "root", authMethod: .password)
        server.useTailscale = false

        // This will fail at tmux check, but SSH connect should be called
        do {
            try await cm.connect(server: server, password: "test")
        } catch {
            // Expected — mock doesn't support full flow
        }
        XCTAssertNil(mockSSH.lastTailscaleFD, "Direct connection should pass nil tailscaleFD")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' -only-testing:MuxiTests/ConnectionManagerTailscaleTests 2>&1 | tail -20`

Expected: Compile error or test failure — no Tailscale logic in ConnectionManager yet.

- [ ] **Step 3: Add TailscaleService property to ConnectionManager**

In `ios/Muxi/Services/ConnectionManager.swift`, add after `lastSessionStore` (line 45):

```swift
private let tailscaleService = TailscaleService()

/// Current Tailscale node state, observable by UI.
private(set) var tailscaleState: TailscaleState = .disconnected
```

Add Tailscale lifecycle methods (after the existing `connect` method):

```swift
// MARK: - Tailscale Lifecycle

/// Start the embedded Tailscale node.
func startTailscale(controlURL: String, authKey: String, hostname: String) async {
    do {
        tailscaleState = .connecting
        try await tailscaleService.start(controlURL: controlURL, authKey: authKey, hostname: hostname)
        tailscaleState = .connected
        logger.info("Tailscale connected")
    } catch {
        tailscaleState = .error(error.localizedDescription)
        logger.error("Tailscale start failed: \(error)")
    }
}

/// Stop the embedded Tailscale node.
func stopTailscale() async {
    await tailscaleService.stop()
    tailscaleState = .disconnected
    logger.info("Tailscale disconnected")
}
```

- [ ] **Step 4: Modify connect() for Tailscale routing**

In `ios/Muxi/Services/ConnectionManager.swift`, in the `connect(server:password:)` method (line 388), before the existing `try await sshService.connect(...)` call (line 399), add Tailscale gate logic:

```swift
var tailscaleFD: Int32? = nil
if server.useTailscale {
    guard tailscaleState == .connected else {
        logger.error("Tailscale not connected — cannot connect to server \(server.host)")
        state = .disconnected
        currentServer = nil
        throw TailscaleError.notConnected
    }
    tailscaleFD = try await tailscaleService.dial(host: server.host, port: server.port)
    logger.info("Got Tailscale fd=\(tailscaleFD!) for \(server.host):\(server.port)")
}
```

Then update the existing `sshService.connect()` call to pass `tailscaleFD`:

```swift
try await sshService.connect(
    host: server.host,
    port: server.port,
    username: server.username,
    auth: auth,
    expectedFingerprint: server.hostKeyFingerprint,
    tailscaleFD: tailscaleFD
)
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' -only-testing:MuxiTests/ConnectionManagerTailscaleTests 2>&1 | tail -20`

Expected: All tests PASS.

- [ ] **Step 6: Run all existing tests to verify no regressions**

Run: `xcodebuild test -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' 2>&1 | tail -30`

Expected: All tests PASS.

- [ ] **Step 7: Commit**

```bash
git add ios/Muxi/Services/ConnectionManager.swift ios/MuxiTests/Services/ConnectionManagerTailscaleTests.swift
git commit -m "feat(tailscale): integrate TailscaleService into ConnectionManager connect flow"
```

---

### Task 6: TailscaleSettingsView — Settings UI

**Files:**
- Create: `ios/Muxi/Views/Settings/TailscaleSettingsView.swift`
- Modify: `ios/Muxi/Views/Settings/SettingsView.swift`

- [ ] **Step 1: Create TailscaleSettingsView**

Create `ios/Muxi/Views/Settings/TailscaleSettingsView.swift`:

```swift
import SwiftUI

/// Settings screen for configuring the embedded Tailscale node.
struct TailscaleSettingsView: View {
    let connectionManager: ConnectionManager

    @State private var controlURL: String = ""
    @State private var preAuthKey: String = ""
    @State private var hostname: String = ""

    private let configStore = TailscaleConfigStore()

    var body: some View {
        List {
            configSection
            connectionSection
        }
        .scrollContentBackground(.hidden)
        .background(MuxiTokens.Colors.surfaceBase)
        .navigationTitle("Tailscale")
        .onAppear { loadConfig() }
    }

    // MARK: - Config Section

    @ViewBuilder
    private var configSection: some View {
        Section("Headscale") {
            TextField("URL", text: $controlURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .listRowBackground(MuxiTokens.Colors.surfaceDefault)
                .foregroundStyle(MuxiTokens.Colors.textPrimary)
                .onSubmit { saveConfig() }

            SecureField("Pre-auth Key", text: $preAuthKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .listRowBackground(MuxiTokens.Colors.surfaceDefault)
                .foregroundStyle(MuxiTokens.Colors.textPrimary)
                .onSubmit { saveConfig() }

            TextField("Hostname", text: $hostname)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .listRowBackground(MuxiTokens.Colors.surfaceDefault)
                .foregroundStyle(MuxiTokens.Colors.textPrimary)
                .onSubmit { saveConfig() }
        }
    }

    // MARK: - Connection Section

    @ViewBuilder
    private var connectionSection: some View {
        Section("Connection") {
            HStack {
                Label("Status", systemImage: statusIcon)
                    .foregroundStyle(MuxiTokens.Colors.textPrimary)
                Spacer()
                Text(statusText)
                    .foregroundStyle(statusColor)
            }
            .listRowBackground(MuxiTokens.Colors.surfaceDefault)

            Button(action: toggleConnection) {
                Text(isConnected ? "Disconnect" : "Connect")
                    .frame(maxWidth: .infinity)
            }
            .disabled(!configStore.isConfigured && !isConnected)
            .listRowBackground(MuxiTokens.Colors.surfaceDefault)
        }
    }

    // MARK: - Helpers

    private var isConnected: Bool {
        connectionManager.tailscaleState == .connected
    }

    private var statusText: String {
        switch connectionManager.tailscaleState {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .error(let msg): msg
        }
    }

    private var statusIcon: String {
        switch connectionManager.tailscaleState {
        case .disconnected: "circle"
        case .connecting: "circle.dotted"
        case .connected: "checkmark.circle.fill"
        case .error: "exclamationmark.circle"
        }
    }

    private var statusColor: Color {
        switch connectionManager.tailscaleState {
        case .disconnected: MuxiTokens.Colors.textSecondary
        case .connecting: MuxiTokens.Colors.textSecondary
        case .connected: .green
        case .error: .red
        }
    }

    private func loadConfig() {
        controlURL = configStore.controlURL
        preAuthKey = configStore.preAuthKey
        hostname = configStore.hostname
    }

    private func saveConfig() {
        configStore.controlURL = controlURL
        configStore.preAuthKey = preAuthKey
        configStore.hostname = hostname
    }

    private func toggleConnection() {
        saveConfig()
        Task {
            if isConnected {
                await connectionManager.stopTailscale()
            } else {
                await connectionManager.startTailscale(
                    controlURL: controlURL,
                    authKey: preAuthKey,
                    hostname: hostname
                )
            }
        }
    }
}
```

- [ ] **Step 2: Add Tailscale section to SettingsView**

In `ios/Muxi/Views/Settings/SettingsView.swift`, add a `connectionManager` property and Tailscale section.

Update the struct to accept `connectionManager`:

```swift
struct SettingsView: View {
    let themeManager: ThemeManager
    let connectionManager: ConnectionManager
```

Add a `tailscaleSection` between `appearanceSection` and `aboutSection` in the body's `List`:

```swift
var body: some View {
    List {
        appearanceSection
        tailscaleSection
        aboutSection
    }
    // ...
}
```

Add the section:

```swift
@ViewBuilder
private var tailscaleSection: some View {
    Section("Tailscale") {
        NavigationLink {
            TailscaleSettingsView(connectionManager: connectionManager)
        } label: {
            HStack {
                Label("Tailscale", systemImage: "network")
                    .foregroundStyle(MuxiTokens.Colors.textPrimary)
                Spacer()
                Text(tailscaleStatusText)
                    .foregroundStyle(tailscaleStatusColor)
            }
        }
        .listRowBackground(MuxiTokens.Colors.surfaceDefault)
    }
}

private var tailscaleStatusText: String {
    switch connectionManager.tailscaleState {
    case .disconnected: "Off"
    case .connecting: "Connecting…"
    case .connected: "Connected"
    case .error: "Error"
    }
}

private var tailscaleStatusColor: Color {
    switch connectionManager.tailscaleState {
    case .connected: .green
    case .error: .red
    default: MuxiTokens.Colors.textSecondary
    }
}
```

- [ ] **Step 3: Update SettingsView call site in ContentView**

In `ios/Muxi/App/ContentView.swift` (line 179), `connectionManager` is available via `@Environment(ConnectionManager.self)`. Update:

```swift
// Before:
SettingsView(themeManager: themeManager)

// After:
SettingsView(themeManager: themeManager, connectionManager: connectionManager)
```

- [ ] **Step 4: Build to verify compilation**

Run: `xcodebuild build -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' 2>&1 | tail -20`

Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add ios/Muxi/Views/Settings/TailscaleSettingsView.swift ios/Muxi/Views/Settings/SettingsView.swift ios/Muxi/App/ContentView.swift
git commit -m "feat(tailscale): add TailscaleSettingsView and integrate into Settings"
```

---

### Task 7: ServerEditView — useTailscale toggle

**Files:**
- Modify: `ios/Muxi/Views/ServerEdit/ServerEditView.swift`

- [ ] **Step 1: Add useTailscale state to ServerEditView**

In `ios/Muxi/Views/ServerEdit/ServerEditView.swift`, add after `@State private var password = ""` (line 17):

```swift
@State private var useTailscale = false
```

- [ ] **Step 2: Add Tailscale toggle to the form**

After the "Authentication" section (line 55), add:

```swift
Section("Network") {
    Toggle(isOn: $useTailscale) {
        Label("Tailscale", systemImage: "network")
            .foregroundStyle(MuxiTokens.Colors.textPrimary)
    }
    .disabled(!TailscaleConfigStore().isConfigured)

    if !TailscaleConfigStore().isConfigured && useTailscale == false {
        Text("설정에서 Tailscale을 먼저 구성하세요")
            .font(.caption)
            .foregroundStyle(MuxiTokens.Colors.textSecondary)
    }
}
```

- [ ] **Step 3: Update loadServer() to load useTailscale**

In `loadServer()` (line 79), add after the `agentForwarding` line (line 85):

```swift
useTailscale = server.useTailscale
```

- [ ] **Step 4: Update save() to persist useTailscale**

In `save()`, after `server.agentForwarding = agentForwarding` (line 114), add:

```swift
server.useTailscale = useTailscale
```

And in the new server branch, update the `Server` initializer call (line 117) — since `Server.init` doesn't have a `useTailscale` param, set it after creation:

After `modelContext.insert(newServer)` (line 122), add:

```swift
newServer.useTailscale = useTailscale
```

- [ ] **Step 5: Build to verify compilation**

Run: `xcodebuild build -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' 2>&1 | tail -20`

Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add ios/Muxi/Views/ServerEdit/ServerEditView.swift
git commit -m "feat(tailscale): add useTailscale toggle to ServerEditView"
```

---

### Task 8: Build pipeline

**Files:**
- Create: `scripts/build-libtailscale.sh`
- Modify: `scripts/build-all.sh`
- Modify: `ios/project.yml`

- [ ] **Step 1: Create build-libtailscale.sh**

Create `scripts/build-libtailscale.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$ROOT_DIR/build/libtailscale"
OUTPUT_DIR="$ROOT_DIR/vendor"

# libtailscale version
LIBTAILSCALE_VERSION="v1.80.3"

echo "=== Building libtailscale ${LIBTAILSCALE_VERSION} ==="

# Check prerequisites
if ! command -v go &>/dev/null; then
    echo "ERROR: Go is required. Install from https://go.dev/dl/"
    exit 1
fi

GO_VERSION=$(go version | awk '{print $3}')
echo "Using Go: ${GO_VERSION}"

# Install gomobile if needed
if ! command -v gomobile &>/dev/null; then
    echo "Installing gomobile..."
    go install golang.org/x/mobile/cmd/gomobile@latest
    go install golang.org/x/mobile/cmd/gobind@latest
fi

echo "Initializing gomobile..."
gomobile init

# Create build workspace
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Create Go module for building libtailscale
cat > go.mod <<EOF
module libtailscale-build

go 1.23

require tailscale.com ${LIBTAILSCALE_VERSION}
EOF

cat > main.go <<'EOF'
package main

import _ "tailscale.com/libtailscale"

func main() {}
EOF

go mod tidy

echo "Building xcframework via gomobile bind..."
gomobile bind \
    -target ios \
    -o "$OUTPUT_DIR/libtailscale.xcframework" \
    tailscale.com/libtailscale

echo "=== libtailscale build complete ==="
echo "Output: $OUTPUT_DIR/libtailscale.xcframework/"
```

- [ ] **Step 2: Make script executable**

```bash
chmod +x scripts/build-libtailscale.sh
```

- [ ] **Step 3: Update build-all.sh**

In `scripts/build-all.sh`, make these exact changes:

1. Update header comment (line 3): `libssh2 1.11.x as xcframeworks.` → `libssh2 1.11.x and libtailscale as xcframeworks.`
2. Update output comment (line 7): add `#   vendor/libtailscale.xcframework/`
3. Update step labels: `Step 0/3` → `Step 0/4`, `Step 1/3` → `Step 1/4`, `Step 2/3` → `Step 2/4` (lines 40, 44, 48)
4. Add after line 49 (`"$SCRIPT_DIR/build-libssh2.sh"`):

```bash

# ── Step 3: Build libtailscale ───────────────────────────────────────────
log "Step 3/4: Building libtailscale"
"$SCRIPT_DIR/build-libtailscale.sh"
```

5. Update output summary (line 56): add `echo "  $PROJECT_ROOT/vendor/libtailscale.xcframework/"`

- [ ] **Step 4: Update project.yml**

In `ios/project.yml`, add to the dependencies section (after openssl):

```yaml
      - framework: ../vendor/libtailscale.xcframework
        embed: true
```

Note: `embed: true` because gomobile produces a dynamic framework (unlike libssh2/openssl which are static).

- [ ] **Step 5: Commit**

```bash
git add scripts/build-libtailscale.sh scripts/build-all.sh ios/project.yml
git commit -m "feat(tailscale): add libtailscale build pipeline and project.yml dependency"
```

---

### Task 9: ADR document

**Files:**
- Create: `docs/decisions/0009-tailscale-embedded-userspace.md`

- [ ] **Step 1: Create ADR**

Create `docs/decisions/0009-tailscale-embedded-userspace.md`:

```markdown
# ADR-0009: Embedded Tailscale Userspace Networking

## Status

Accepted

## Context

Users on Tailscale/Headscale networks need to SSH to machines that are only reachable via their tailnet. iOS allows only one system VPN at a time, so a Network Extension approach would conflict with any existing VPN.

## Decision

Embed a Tailscale node using **libtailscale** (C API over tsnet via gomobile) with **userspace networking**. This runs entirely within Muxi's process, does not consume the system VPN slot, and coexists with any active VPN.

Key choices:
- **libtailscale** over raw WireGuard+Headscale API — uses the official Tailscale client stack, minimizing reimplementation
- **Userspace (tsnet)** over Network Extension — avoids VPN slot conflict and Apple entitlement requirements
- **gomobile xcframework** — consistent with existing libssh2/OpenSSL build pipeline
- **fd passthrough** — libtailscale's `dial()` returns a file descriptor that plugs directly into `libssh2_session_handshake(session, fd)`, requiring minimal changes to the SSH stack

## Consequences

- Binary size increases ~15-25MB due to embedded Go runtime
- Go toolchain (+ gomobile) added as build dependency
- TailscaleService actor manages fd lifecycle — SSHService must not close Tailscale-provided fds
- Pre-auth key authentication only (Headscale); OAuth not supported initially
- Background behavior: tsnet goroutines freeze when iOS suspends the app; reconnection happens automatically on foreground resume
```

- [ ] **Step 2: Commit**

```bash
git add docs/decisions/0009-tailscale-embedded-userspace.md
git commit -m "docs: add ADR-0009 embedded Tailscale userspace networking"
```

---

### Task 10: Full integration verification

- [ ] **Step 1: Run all tests**

```bash
xcodebuild test -project ios/Muxi.xcodeproj -scheme Muxi \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' 2>&1 | tail -40
```

Expected: All tests PASS (new + existing).

- [ ] **Step 2: Verify build succeeds**

```bash
xcodebuild build -project ios/Muxi.xcodeproj -scheme Muxi \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Update ARCHITECTURE.md**

Add TailscaleService to the App Layer table in `docs/ARCHITECTURE.md`:

```markdown
| `TailscaleService` | Embedded Tailscale node via libtailscale — userspace networking for Headscale |
```

Add libtailscale to the dependency chain diagram.

- [ ] **Step 4: Update CHANGELOG.md**

Add under "Added":

```markdown
- Tailscale integration: embedded tsnet node for SSH over Headscale/Tailscale networks
- TailscaleSettingsView for Headscale configuration
- Per-server "Tailscale" toggle in server settings
```

- [ ] **Step 5: Commit**

```bash
git add docs/ARCHITECTURE.md CHANGELOG.md
git commit -m "docs: update ARCHITECTURE.md and CHANGELOG.md for Tailscale integration"
```
