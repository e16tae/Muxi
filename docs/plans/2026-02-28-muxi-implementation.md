# Muxi Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build an iOS terminal app that renders tmux panes as native SwiftUI views via tmux control mode (`tmux -CC`).

**Architecture:** 4-layer architecture (UI → App → Bridge → Core). Core layer in C for cross-platform sharing. SSH via libssh2, tmux via control mode protocol, terminal rendering via Metal. SwiftData for server persistence, Keychain for secrets.

**Tech Stack:** Swift 5.9+, SwiftUI, SwiftData, iOS 17+, Metal, C (VT parser, tmux protocol parser), libssh2, XcodeGen, SPM

**Design Document:** `docs/plans/2026-02-28-muxi-design.md`

---

## Phase 1: Project Foundation

### Task 1: Initialize Xcode Project with XcodeGen

**Why first:** Everything depends on having a buildable project.

**Files:**
- Create: `project.yml` (XcodeGen spec)
- Create: `Muxi/App/MuxiApp.swift`
- Create: `Muxi/App/ContentView.swift`
- Create: `MuxiTests/MuxiTests.swift`

**Step 1: Install XcodeGen if needed**

```bash
brew install xcodegen
```

**Step 2: Create project.yml**

```yaml
name: Muxi
options:
  bundleIdPrefix: com.muxi
  deploymentTarget:
    iOS: "17.0"
  xcodeVersion: "15.0"
  generateEmptyDirectories: true

settings:
  base:
    SWIFT_VERSION: "5.9"
    DEVELOPMENT_TEAM: ""

targets:
  Muxi:
    type: application
    platform: iOS
    sources:
      - path: Muxi
    settings:
      base:
        INFOPLIST_KEY_UIApplicationSceneManifest_Generation: true
        INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents: true
        INFOPLIST_KEY_UILaunchScreen_Generation: true
        INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad: "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"
        INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone: "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"
    dependencies:
      - package: MuxiCore

  MuxiTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - path: MuxiTests
    dependencies:
      - target: Muxi

packages:
  MuxiCore:
    path: MuxiCore
```

**Step 3: Create app entry point**

Create `Muxi/App/MuxiApp.swift`:
```swift
import SwiftUI
import SwiftData

@main
struct MuxiApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [Server.self])
    }
}
```

Create `Muxi/App/ContentView.swift`:
```swift
import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            Text("Muxi")
                .navigationTitle("Servers")
        }
    }
}
```

**Step 4: Create MuxiCore SPM package skeleton**

Create `MuxiCore/Package.swift`:
```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MuxiCore",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "MuxiCore", targets: ["MuxiCore"]),
        .library(name: "VTParser", targets: ["VTParser"]),
        .library(name: "TmuxProtocol", targets: ["TmuxProtocol"]),
    ],
    targets: [
        // Swift umbrella target
        .target(
            name: "MuxiCore",
            dependencies: ["VTParser", "TmuxProtocol"]
        ),
        // C target: VT escape sequence parser
        .target(
            name: "VTParser",
            path: "Sources/VTParser",
            publicHeadersPath: "include"
        ),
        // C target: tmux control mode message parser
        .target(
            name: "TmuxProtocol",
            path: "Sources/TmuxProtocol",
            publicHeadersPath: "include"
        ),
        // Tests
        .testTarget(
            name: "VTParserTests",
            dependencies: ["VTParser"]
        ),
        .testTarget(
            name: "TmuxProtocolTests",
            dependencies: ["TmuxProtocol"]
        ),
    ]
)
```

Create placeholder files so SPM compiles:

`MuxiCore/Sources/MuxiCore/MuxiCore.swift`:
```swift
@_exported import VTParser
@_exported import TmuxProtocol
```

`MuxiCore/Sources/VTParser/include/vt_parser.h`:
```c
#ifndef VT_PARSER_H
#define VT_PARSER_H

// VT escape sequence parser — implemented in later tasks

#endif
```

`MuxiCore/Sources/VTParser/vt_parser.c`:
```c
#include "vt_parser.h"
```

`MuxiCore/Sources/TmuxProtocol/include/tmux_protocol.h`:
```c
#ifndef TMUX_PROTOCOL_H
#define TMUX_PROTOCOL_H

// tmux control mode protocol parser — implemented in later tasks

#endif
```

`MuxiCore/Sources/TmuxProtocol/tmux_protocol.c`:
```c
#include "tmux_protocol.h"
```

`MuxiCore/Tests/VTParserTests/VTParserTests.swift`:
```swift
import XCTest
@testable import VTParser

final class VTParserTests: XCTestCase {
    func testPlaceholder() {
        XCTAssertTrue(true, "VTParser target compiles")
    }
}
```

`MuxiCore/Tests/TmuxProtocolTests/TmuxProtocolTests.swift`:
```swift
import XCTest
@testable import TmuxProtocol

final class TmuxProtocolTests: XCTestCase {
    func testPlaceholder() {
        XCTAssertTrue(true, "TmuxProtocol target compiles")
    }
}
```

**Step 5: Create empty test file**

`MuxiTests/MuxiTests.swift`:
```swift
import XCTest
@testable import Muxi

final class MuxiTests: XCTestCase {
    func testAppLaunches() {
        XCTAssertTrue(true)
    }
}
```

**Step 6: Generate Xcode project and verify build**

```bash
cd /path/to/Muxi
xcodegen generate
xcodebuild -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

**Step 7: Run SPM package tests**

```bash
cd MuxiCore
swift test 2>&1 | tail -10
```

Expected: `Test Suite 'All tests' passed`

**Step 8: Initialize git and commit**

```bash
git init
cat > .gitignore << 'EOF'
# Xcode
*.xcodeproj/xcuserdata/
*.xcodeproj/project.xcworkspace/xcuserdata/
*.xcworkspace/xcuserdata/
DerivedData/
build/
*.pbxuser
*.mode1v3
*.mode2v3
*.perspectivev3
*.hmap
*.ipa
*.dSYM.zip
*.dSYM

# Swift Package Manager
.build/
.swiftpm/
Package.resolved

# macOS
.DS_Store
*.swp
*~

# IDE
*.xccheckout
*.moved-aside
EOF

git add -A
git commit -m "feat: initialize Muxi project with XcodeGen and MuxiCore SPM package"
```

---

### Task 2: Data Models

**Why now:** Models are referenced by everything — persistence, ViewModels, views.

**Files:**
- Create: `Muxi/Models/Server.swift`
- Create: `Muxi/Models/AuthMethod.swift`
- Create: `Muxi/Models/SSHKey.swift`
- Create: `Muxi/Models/TmuxSession.swift`
- Create: `Muxi/Models/TmuxWindow.swift`
- Create: `Muxi/Models/TmuxPane.swift`
- Test: `MuxiTests/Models/ServerModelTests.swift`
- Test: `MuxiTests/Models/TmuxModelsTests.swift`

**Step 1: Write Server model tests**

`MuxiTests/Models/ServerModelTests.swift`:
```swift
import XCTest
import SwiftData
@testable import Muxi

final class ServerModelTests: XCTestCase {
    var container: ModelContainer!

    override func setUp() {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Server.self, configurations: config)
    }

    func testServerCreation() {
        let server = Server(
            name: "Dev Server",
            host: "192.168.1.100",
            port: 22,
            username: "admin",
            authMethod: .password,
            agentForwarding: false
        )
        XCTAssertEqual(server.name, "Dev Server")
        XCTAssertEqual(server.port, 22)
        XCTAssertEqual(server.authMethod, .password)
    }

    func testServerWithKeyAuth() {
        let keyId = UUID()
        let server = Server(
            name: "Prod",
            host: "10.0.0.1",
            port: 2222,
            username: "deploy",
            authMethod: .key(keyId: keyId),
            agentForwarding: true
        )
        if case .key(let id) = server.authMethod {
            XCTAssertEqual(id, keyId)
        } else {
            XCTFail("Expected key auth")
        }
        XCTAssertTrue(server.agentForwarding)
    }

    func testServerPersistence() throws {
        let context = ModelContext(container)
        let server = Server(
            name: "Test",
            host: "localhost",
            port: 22,
            username: "user",
            authMethod: .password,
            agentForwarding: false
        )
        context.insert(server)
        try context.save()

        let descriptor = FetchDescriptor<Server>()
        let servers = try context.fetch(descriptor)
        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers.first?.host, "localhost")
    }

    func testAuthMethodCodable() throws {
        let password = AuthMethod.password
        let keyAuth = AuthMethod.key(keyId: UUID())

        let encoder = JSONEncoder()
        let passwordData = try encoder.encode(password)
        let keyData = try encoder.encode(keyAuth)

        let decoder = JSONDecoder()
        let decodedPassword = try decoder.decode(AuthMethod.self, from: passwordData)
        let decodedKey = try decoder.decode(AuthMethod.self, from: keyData)

        XCTAssertEqual(decodedPassword, password)
        if case .key = decodedKey {
            // success
        } else {
            XCTFail("Expected key auth after decode")
        }
    }
}
```

**Step 2: Run tests to verify they fail**

```bash
xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "(Test|error|FAIL)"
```

Expected: Compile errors — `Server`, `AuthMethod` not defined.

**Step 3: Implement models**

`Muxi/Models/AuthMethod.swift`:
```swift
import Foundation

enum AuthMethod: Codable, Equatable {
    case password
    case key(keyId: UUID)
}
```

`Muxi/Models/SSHKey.swift`:
```swift
import Foundation

struct SSHKey: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var type: KeyType
}

enum KeyType: String, Codable {
    case ed25519
    case rsa
}
```

`Muxi/Models/Server.swift`:
```swift
import Foundation
import SwiftData

@Model
final class Server {
    @Attribute(.unique) var id: UUID
    var name: String
    var host: String
    var port: UInt16
    var username: String
    var authMethod: AuthMethod
    var agentForwarding: Bool

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: UInt16 = 22,
        username: String,
        authMethod: AuthMethod,
        agentForwarding: Bool = false
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.agentForwarding = agentForwarding
    }
}
```

`Muxi/Models/TmuxSession.swift`:
```swift
import Foundation

struct TmuxSession: Identifiable, Equatable {
    let id: String
    var name: String
    var windows: [TmuxWindow]
    var createdAt: Date
    var lastActivity: Date
}
```

`Muxi/Models/TmuxWindow.swift`:
```swift
import Foundation

struct TmuxWindow: Identifiable, Equatable {
    let id: String
    var name: String
    var panes: [TmuxPane]
    var layout: String
}
```

`Muxi/Models/TmuxPane.swift`:
```swift
import Foundation

struct TmuxPane: Identifiable, Equatable {
    let id: String
    var isActive: Bool
    var size: PaneSize
}

struct PaneSize: Equatable {
    var columns: Int
    var rows: Int
}
```

**Step 4: Write tmux model tests**

`MuxiTests/Models/TmuxModelsTests.swift`:
```swift
import XCTest
@testable import Muxi

final class TmuxModelsTests: XCTestCase {
    func testTmuxSessionCreation() {
        let pane = TmuxPane(id: "%0", isActive: true, size: PaneSize(columns: 80, rows: 24))
        let window = TmuxWindow(id: "@0", name: "bash", panes: [pane], layout: "80x24,0,0,0")
        let session = TmuxSession(
            id: "$0",
            name: "main",
            windows: [window],
            createdAt: Date(),
            lastActivity: Date()
        )

        XCTAssertEqual(session.name, "main")
        XCTAssertEqual(session.windows.count, 1)
        XCTAssertEqual(session.windows[0].panes.count, 1)
        XCTAssertEqual(session.windows[0].panes[0].size.columns, 80)
    }

    func testPaneSize() {
        let size = PaneSize(columns: 120, rows: 40)
        XCTAssertEqual(size.columns, 120)
        XCTAssertEqual(size.rows, 40)
    }
}
```

**Step 5: Regenerate project, run all tests**

```bash
xcodegen generate
xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "(Test Suite|Executed|PASS|FAIL)"
```

Expected: All tests pass.

**Step 6: Commit**

```bash
git add -A
git commit -m "feat: add data models — Server (SwiftData), AuthMethod, SSHKey, tmux runtime models"
```

---

## Phase 2: Persistence Layer

### Task 3: KeychainService

**Why now:** Server edit needs to store passwords/keys. Needed before UI.

**Files:**
- Create: `Muxi/Services/KeychainService.swift`
- Test: `MuxiTests/Services/KeychainServiceTests.swift`

**Step 1: Write tests**

`MuxiTests/Services/KeychainServiceTests.swift`:
```swift
import XCTest
@testable import Muxi

final class KeychainServiceTests: XCTestCase {
    let service = KeychainService()
    let testAccount = "test-\(UUID().uuidString)"

    override func tearDown() {
        try? service.deletePassword(account: testAccount)
        try? service.deleteSSHKey(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    }

    func testSaveAndRetrievePassword() throws {
        try service.savePassword("s3cret", account: testAccount)
        let retrieved = try service.retrievePassword(account: testAccount)
        XCTAssertEqual(retrieved, "s3cret")
    }

    func testUpdatePassword() throws {
        try service.savePassword("old", account: testAccount)
        try service.savePassword("new", account: testAccount)
        let retrieved = try service.retrievePassword(account: testAccount)
        XCTAssertEqual(retrieved, "new")
    }

    func testDeletePassword() throws {
        try service.savePassword("temp", account: testAccount)
        try service.deletePassword(account: testAccount)
        XCTAssertThrowsError(try service.retrievePassword(account: testAccount))
    }

    func testRetrieveNonexistentPassword() {
        XCTAssertThrowsError(try service.retrievePassword(account: "nonexistent-\(UUID())"))
    }

    func testSaveAndRetrieveSSHKey() throws {
        let keyId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let keyData = Data("fake-private-key-data".utf8)
        let sshKey = SSHKey(id: keyId, name: "My Key", type: .ed25519)

        try service.saveSSHKey(sshKey, privateKeyData: keyData)

        let (retrieved, data) = try service.retrieveSSHKey(id: keyId)
        XCTAssertEqual(retrieved.name, "My Key")
        XCTAssertEqual(retrieved.type, .ed25519)
        XCTAssertEqual(data, keyData)
    }

    func testListSSHKeys() throws {
        let keyId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let keyData = Data("key-data".utf8)
        let sshKey = SSHKey(id: keyId, name: "Listed Key", type: .rsa)

        try service.saveSSHKey(sshKey, privateKeyData: keyData)

        let keys = try service.listSSHKeys()
        XCTAssertTrue(keys.contains(where: { $0.id == keyId }))
    }
}
```

**Step 2: Run tests — should fail (KeychainService not defined)**

**Step 3: Implement KeychainService**

`Muxi/Services/KeychainService.swift`:
```swift
import Foundation
import Security

enum KeychainError: Error {
    case itemNotFound
    case duplicateItem
    case unexpectedStatus(OSStatus)
    case dataConversionFailed
}

final class KeychainService {
    private let serviceName = "com.muxi.app"
    private let sshKeyService = "com.muxi.ssh-keys"

    // MARK: - Passwords

    func savePassword(_ password: String, account: String) throws {
        guard let data = password.data(using: .utf8) else {
            throw KeychainError.dataConversionFailed
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
        ]

        // Try to update first
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)

        if updateStatus == errSecItemNotFound {
            // Item doesn't exist, add it
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    func retrievePassword(account: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            if status == errSecItemNotFound {
                throw KeychainError.itemNotFound
            }
            throw KeychainError.unexpectedStatus(status)
        }

        guard let password = String(data: data, encoding: .utf8) else {
            throw KeychainError.dataConversionFailed
        }
        return password
    }

    func deletePassword(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: - SSH Keys

    func saveSSHKey(_ key: SSHKey, privateKeyData: Data) throws {
        let metadata = try JSONEncoder().encode(key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sshKeyService,
            kSecAttrAccount as String: key.id.uuidString,
            kSecAttrLabel as String: key.name,
            kSecAttrComment as String: String(data: metadata, encoding: .utf8)!,
            kSecValueData as String: privateKeyData,
        ]

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sshKeyService,
            kSecAttrAccount as String: key.id.uuidString,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func retrieveSSHKey(id: UUID) throws -> (SSHKey, Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sshKeyService,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let dict = result as? [String: Any],
              let privateKeyData = dict[kSecValueData as String] as? Data,
              let comment = dict[kSecAttrComment as String] as? String,
              let metadataData = comment.data(using: .utf8),
              let sshKey = try? JSONDecoder().decode(SSHKey.self, from: metadataData)
        else {
            if status == errSecItemNotFound {
                throw KeychainError.itemNotFound
            }
            throw KeychainError.unexpectedStatus(status)
        }

        return (sshKey, privateKeyData)
    }

    func deleteSSHKey(id: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sshKeyService,
            kSecAttrAccount as String: id.uuidString,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func listSSHKeys() throws -> [SSHKey] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sshKeyService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return []
        }

        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw KeychainError.unexpectedStatus(status)
        }

        return items.compactMap { dict in
            guard let comment = dict[kSecAttrComment as String] as? String,
                  let data = comment.data(using: .utf8),
                  let key = try? JSONDecoder().decode(SSHKey.self, from: data)
            else { return nil }
            return key
        }
    }
}
```

**Step 4: Run tests**

```bash
xcodegen generate
xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "(Test Suite|Executed|PASS|FAIL)"
```

Expected: All tests pass. (Note: Keychain tests work in Simulator.)

**Step 5: Commit**

```bash
git add -A
git commit -m "feat: add KeychainService for password and SSH key storage"
```

---

### Task 4: Server Management UI (ServerList + ServerEdit)

**Why now:** First visible screen. Validates SwiftData + Keychain + MVVM setup.

**Files:**
- Create: `Muxi/ViewModels/ServerListViewModel.swift`
- Create: `Muxi/Views/ServerList/ServerListView.swift`
- Create: `Muxi/Views/ServerList/ServerRowView.swift`
- Create: `Muxi/Views/ServerEdit/ServerEditView.swift`
- Modify: `Muxi/App/ContentView.swift`
- Test: `MuxiTests/ViewModels/ServerListViewModelTests.swift`

**Step 1: Write ViewModel tests**

`MuxiTests/ViewModels/ServerListViewModelTests.swift`:
```swift
import XCTest
import SwiftData
@testable import Muxi

@MainActor
final class ServerListViewModelTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!

    override func setUp() {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Server.self, configurations: config)
        context = ModelContext(container)
    }

    func testAddServer() throws {
        let vm = ServerListViewModel(modelContext: context)
        vm.addServer(
            name: "Test",
            host: "1.2.3.4",
            port: 22,
            username: "root",
            authMethod: .password,
            agentForwarding: false
        )

        let descriptor = FetchDescriptor<Server>()
        let servers = try context.fetch(descriptor)
        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers[0].host, "1.2.3.4")
    }

    func testDeleteServer() throws {
        let server = Server(name: "Del", host: "x", port: 22, username: "u", authMethod: .password)
        context.insert(server)
        try context.save()

        let vm = ServerListViewModel(modelContext: context)
        vm.deleteServer(server)

        let descriptor = FetchDescriptor<Server>()
        let servers = try context.fetch(descriptor)
        XCTAssertEqual(servers.count, 0)
    }
}
```

**Step 2: Run tests — fail**

**Step 3: Implement ViewModel**

`Muxi/ViewModels/ServerListViewModel.swift`:
```swift
import Foundation
import SwiftData

@MainActor
@Observable
final class ServerListViewModel {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func addServer(
        name: String,
        host: String,
        port: UInt16,
        username: String,
        authMethod: AuthMethod,
        agentForwarding: Bool
    ) {
        let server = Server(
            name: name,
            host: host,
            port: port,
            username: username,
            authMethod: authMethod,
            agentForwarding: agentForwarding
        )
        modelContext.insert(server)
        try? modelContext.save()
    }

    func deleteServer(_ server: Server) {
        modelContext.delete(server)
        try? modelContext.save()
    }

    func updateServer(_ server: Server) {
        try? modelContext.save()
    }
}
```

**Step 4: Implement Views**

`Muxi/Views/ServerList/ServerRowView.swift`:
```swift
import SwiftUI

struct ServerRowView: View {
    let server: Server

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(server.name)
                .font(.headline)
            Text("\(server.username)@\(server.host):\(server.port)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
```

`Muxi/Views/ServerList/ServerListView.swift`:
```swift
import SwiftUI
import SwiftData

struct ServerListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Server.name) private var servers: [Server]
    @State private var showingAddServer = false

    var body: some View {
        List {
            ForEach(servers) { server in
                NavigationLink(value: server.id) {
                    ServerRowView(server: server)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        modelContext.delete(server)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("Servers")
        .toolbar {
            Button {
                showingAddServer = true
            } label: {
                Image(systemName: "plus")
            }
        }
        .sheet(isPresented: $showingAddServer) {
            ServerEditView(server: nil)
        }
    }
}
```

`Muxi/Views/ServerEdit/ServerEditView.swift`:
```swift
import SwiftUI
import SwiftData

struct ServerEditView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let server: Server?

    @State private var name = ""
    @State private var host = ""
    @State private var port: UInt16 = 22
    @State private var username = ""
    @State private var useKeyAuth = false
    @State private var agentForwarding = false
    @State private var password = ""

    private var isEditing: Bool { server != nil }
    private let keychainService = KeychainService()

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Name", text: $name)
                    TextField("Host", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack {
                        Text("Port")
                        Spacer()
                        TextField("22", value: $port, format: .number)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                    }
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Authentication") {
                    Picker("Method", selection: $useKeyAuth) {
                        Text("Password").tag(false)
                        Text("SSH Key").tag(true)
                    }
                    .pickerStyle(.segmented)

                    if !useKeyAuth {
                        SecureField("Password", text: $password)
                    }

                    Toggle("Agent Forwarding", isOn: $agentForwarding)
                }
            }
            .navigationTitle(isEditing ? "Edit Server" : "New Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.isEmpty || host.isEmpty || username.isEmpty)
                }
            }
            .onAppear { loadServer() }
        }
    }

    private func loadServer() {
        guard let server else { return }
        name = server.name
        host = server.host
        port = server.port
        username = server.username
        agentForwarding = server.agentForwarding
        if case .key = server.authMethod {
            useKeyAuth = true
        }
    }

    private func save() {
        let authMethod: AuthMethod = useKeyAuth ? .key(keyId: UUID()) : .password

        if let server {
            server.name = name
            server.host = host
            server.port = port
            server.username = username
            server.authMethod = authMethod
            server.agentForwarding = agentForwarding
        } else {
            let newServer = Server(
                name: name,
                host: host,
                port: port,
                username: username,
                authMethod: authMethod,
                agentForwarding: agentForwarding
            )
            modelContext.insert(newServer)
        }

        if !useKeyAuth && !password.isEmpty {
            let accountId = server?.id.uuidString ?? UUID().uuidString
            try? keychainService.savePassword(password, account: accountId)
        }

        try? modelContext.save()
        dismiss()
    }
}
```

**Step 5: Update ContentView**

`Muxi/App/ContentView.swift`:
```swift
import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            ServerListView()
        }
    }
}
```

**Step 6: Regenerate project, build, and run tests**

```bash
xcodegen generate
xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "(Test Suite|Executed|PASS|FAIL)"
```

Expected: All tests pass, app builds.

**Step 7: Commit**

```bash
git add -A
git commit -m "feat: add server management — list, add, edit, delete with SwiftData + Keychain"
```

---

## Phase 3: Core C Libraries

### Task 5: tmux Control Mode Protocol Parser (C)

**Why now:** This is the foundational protocol that the entire app depends on. Needs to be correct and well-tested before building Swift layers on top.

**Files:**
- Modify: `MuxiCore/Sources/TmuxProtocol/include/tmux_protocol.h`
- Modify: `MuxiCore/Sources/TmuxProtocol/tmux_protocol.c`
- Modify: `MuxiCore/Tests/TmuxProtocolTests/TmuxProtocolTests.swift`

**Step 1: Write tests for protocol parsing**

`MuxiCore/Tests/TmuxProtocolTests/TmuxProtocolTests.swift`:
```swift
import XCTest
@testable import TmuxProtocol

final class TmuxProtocolTests: XCTestCase {

    func testParseOutputMessage() {
        let line = "%output %0 Hello world\\n"
        var msg = TmuxMessage()
        let result = tmux_parse_line(line, &msg)

        XCTAssertEqual(result, TMUX_MSG_OUTPUT)
        XCTAssertEqual(String(cString: msg.pane_id), "%0")
        // output data contains the escaped string
    }

    func testParseLayoutChange() {
        let line = "%layout-change @0 abcd,80x24,0,0{40x24,0,0,0,39x24,41,0,1}"
        var msg = TmuxMessage()
        let result = tmux_parse_line(line, &msg)

        XCTAssertEqual(result, TMUX_MSG_LAYOUT_CHANGE)
        XCTAssertEqual(String(cString: msg.window_id), "@0")
    }

    func testParseWindowAdd() {
        let line = "%window-add @1"
        var msg = TmuxMessage()
        let result = tmux_parse_line(line, &msg)

        XCTAssertEqual(result, TMUX_MSG_WINDOW_ADD)
        XCTAssertEqual(String(cString: msg.window_id), "@1")
    }

    func testParseWindowClose() {
        let line = "%window-close @2"
        var msg = TmuxMessage()
        let result = tmux_parse_line(line, &msg)

        XCTAssertEqual(result, TMUX_MSG_WINDOW_CLOSE)
        XCTAssertEqual(String(cString: msg.window_id), "@2")
    }

    func testParseSessionChanged() {
        let line = "%session-changed $0 my-session"
        var msg = TmuxMessage()
        let result = tmux_parse_line(line, &msg)

        XCTAssertEqual(result, TMUX_MSG_SESSION_CHANGED)
        XCTAssertEqual(String(cString: msg.session_id), "$0")
        XCTAssertEqual(String(cString: msg.session_name), "my-session")
    }

    func testParseBegin() {
        let line = "%begin 1234567890 1 0"
        var msg = TmuxMessage()
        let result = tmux_parse_line(line, &msg)

        XCTAssertEqual(result, TMUX_MSG_BEGIN)
    }

    func testParseEnd() {
        let line = "%end 1234567890 1 0"
        var msg = TmuxMessage()
        let result = tmux_parse_line(line, &msg)

        XCTAssertEqual(result, TMUX_MSG_END)
    }

    func testParseExit() {
        let line = "%exit"
        var msg = TmuxMessage()
        let result = tmux_parse_line(line, &msg)

        XCTAssertEqual(result, TMUX_MSG_EXIT)
    }

    func testParseUnknownLine() {
        let line = "some random output"
        var msg = TmuxMessage()
        let result = tmux_parse_line(line, &msg)

        XCTAssertEqual(result, TMUX_MSG_UNKNOWN)
    }

    func testParseEmptyLine() {
        let line = ""
        var msg = TmuxMessage()
        let result = tmux_parse_line(line, &msg)

        XCTAssertEqual(result, TMUX_MSG_UNKNOWN)
    }

    func testParseLayoutString() {
        // Layout: "80x24,0,0{40x24,0,0,0,39x24,41,0,1}"
        // This means: 80x24 window split vertically into two panes
        let layout = "abcd,80x24,0,0{40x24,0,0,0,39x24,41,0,1}"
        var panes = [TmuxLayoutPane](repeating: TmuxLayoutPane(), count: 16)
        var count: Int32 = 0

        let result = tmux_parse_layout(layout, &panes, 16, &count)

        XCTAssertEqual(result, 0)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(panes[0].width, 40)
        XCTAssertEqual(panes[0].height, 24)
        XCTAssertEqual(panes[0].x, 0)
        XCTAssertEqual(panes[0].y, 0)
        XCTAssertEqual(panes[1].width, 39)
        XCTAssertEqual(panes[1].x, 41)
    }
}
```

**Step 2: Run tests — fail**

```bash
cd MuxiCore && swift test 2>&1 | tail -20
```

**Step 3: Implement tmux protocol parser**

`MuxiCore/Sources/TmuxProtocol/include/tmux_protocol.h`:
```c
#ifndef TMUX_PROTOCOL_H
#define TMUX_PROTOCOL_H

#include <stdint.h>
#include <stddef.h>

// Message types returned by tmux_parse_line
#define TMUX_MSG_UNKNOWN          0
#define TMUX_MSG_OUTPUT           1
#define TMUX_MSG_LAYOUT_CHANGE    2
#define TMUX_MSG_WINDOW_ADD       3
#define TMUX_MSG_WINDOW_CLOSE     4
#define TMUX_MSG_SESSION_CHANGED  5
#define TMUX_MSG_BEGIN            6
#define TMUX_MSG_END              7
#define TMUX_MSG_EXIT             8
#define TMUX_MSG_ERROR            9
#define TMUX_MSG_PANE_MODE_CHANGED 10

#define TMUX_ID_MAX    32
#define TMUX_NAME_MAX  256
#define TMUX_DATA_MAX  8192

// Parsed message from tmux control mode
typedef struct {
    char pane_id[TMUX_ID_MAX];       // e.g. "%0"
    char window_id[TMUX_ID_MAX];     // e.g. "@0"
    char session_id[TMUX_ID_MAX];    // e.g. "$0"
    char session_name[TMUX_NAME_MAX];
    char layout[TMUX_DATA_MAX];
    const char *output_data;          // points into the original line
    size_t output_len;
    int64_t timestamp;
    int command_number;
    int flags;
} TmuxMessage;

// Parsed pane from layout string
typedef struct {
    int32_t x;
    int32_t y;
    int32_t width;
    int32_t height;
    int32_t pane_id;
} TmuxLayoutPane;

// Parse a single line of tmux control mode output.
// Returns TMUX_MSG_* type. Fills `msg` with parsed data.
int tmux_parse_line(const char *line, TmuxMessage *msg);

// Parse a tmux layout string into pane geometries.
// Returns 0 on success, -1 on error.
// `panes` must be pre-allocated with at least `max_panes` entries.
// `out_count` is set to the number of panes parsed.
int tmux_parse_layout(const char *layout, TmuxLayoutPane *panes,
                      int max_panes, int *out_count);

#endif
```

`MuxiCore/Sources/TmuxProtocol/tmux_protocol.c`:
```c
#include "tmux_protocol.h"
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

static int starts_with(const char *str, const char *prefix) {
    return strncmp(str, prefix, strlen(prefix)) == 0;
}

// Copy token from src into dst, up to max chars or next space.
// Returns pointer past the copied token in src.
static const char *copy_token(const char *src, char *dst, size_t max) {
    size_t i = 0;
    while (*src && *src != ' ' && i < max - 1) {
        dst[i++] = *src++;
    }
    dst[i] = '\0';
    if (*src == ' ') src++;
    return src;
}

int tmux_parse_line(const char *line, TmuxMessage *msg) {
    if (!line || !msg) return TMUX_MSG_UNKNOWN;

    memset(msg, 0, sizeof(TmuxMessage));

    if (line[0] != '%') return TMUX_MSG_UNKNOWN;

    if (starts_with(line, "%output ")) {
        const char *p = line + 8; // skip "%output "
        p = copy_token(p, msg->pane_id, TMUX_ID_MAX);
        msg->output_data = p;
        msg->output_len = strlen(p);
        return TMUX_MSG_OUTPUT;
    }

    if (starts_with(line, "%layout-change ")) {
        const char *p = line + 15;
        p = copy_token(p, msg->window_id, TMUX_ID_MAX);
        strncpy(msg->layout, p, TMUX_DATA_MAX - 1);
        return TMUX_MSG_LAYOUT_CHANGE;
    }

    if (starts_with(line, "%window-add ")) {
        copy_token(line + 12, msg->window_id, TMUX_ID_MAX);
        return TMUX_MSG_WINDOW_ADD;
    }

    if (starts_with(line, "%window-close ")) {
        copy_token(line + 14, msg->window_id, TMUX_ID_MAX);
        return TMUX_MSG_WINDOW_CLOSE;
    }

    if (starts_with(line, "%session-changed ")) {
        const char *p = line + 17;
        p = copy_token(p, msg->session_id, TMUX_ID_MAX);
        strncpy(msg->session_name, p, TMUX_NAME_MAX - 1);
        return TMUX_MSG_SESSION_CHANGED;
    }

    if (starts_with(line, "%begin ")) {
        // %begin <timestamp> <command_number> <flags>
        const char *p = line + 7;
        msg->timestamp = strtoll(p, NULL, 10);
        return TMUX_MSG_BEGIN;
    }

    if (starts_with(line, "%end ")) {
        const char *p = line + 5;
        msg->timestamp = strtoll(p, NULL, 10);
        return TMUX_MSG_END;
    }

    if (starts_with(line, "%exit")) {
        return TMUX_MSG_EXIT;
    }

    if (starts_with(line, "%error ")) {
        return TMUX_MSG_ERROR;
    }

    return TMUX_MSG_UNKNOWN;
}

// Internal: parse a layout node recursively.
// Layout format: <checksum>,<width>x<height>,<x>,<y>[{<children>}|,<pane_id>]
static const char *parse_layout_node(const char *p, TmuxLayoutPane *panes,
                                     int max_panes, int *count) {
    if (!p || *p == '\0' || *count >= max_panes) return p;

    int w = 0, h = 0, x = 0, y = 0, pane_id = -1;

    // Parse: <width>x<height>,<x>,<y>
    w = (int)strtol(p, NULL, 10);
    p = strchr(p, 'x');
    if (!p) return NULL;
    p++;
    h = (int)strtol(p, NULL, 10);
    p = strchr(p, ',');
    if (!p) return NULL;
    p++;
    x = (int)strtol(p, NULL, 10);
    p = strchr(p, ',');
    if (!p) return NULL;
    p++;
    y = (int)strtol(p, NULL, 10);

    // Check what follows: '{' means vertical split, '[' means horizontal split, ',' means pane_id
    // Skip past the y value
    while (*p && *p != '{' && *p != '[' && *p != ',' && *p != '}' && *p != ']') p++;

    if (*p == ',') {
        // Terminal pane with id
        p++;
        pane_id = (int)strtol(p, NULL, 10);
        while (*p && *p >= '0' && *p <= '9') p++;

        panes[*count].x = x;
        panes[*count].y = y;
        panes[*count].width = w;
        panes[*count].height = h;
        panes[*count].pane_id = pane_id;
        (*count)++;
    } else if (*p == '{' || *p == '[') {
        // Container with children
        char close = (*p == '{') ? '}' : ']';
        p++; // skip open bracket

        while (*p && *p != close) {
            p = parse_layout_node(p, panes, max_panes, count);
            if (!p) return NULL;
            if (*p == ',') p++; // skip separator between siblings
        }
        if (*p == close) p++; // skip close bracket
    }

    return p;
}

int tmux_parse_layout(const char *layout, TmuxLayoutPane *panes,
                      int max_panes, int *out_count) {
    if (!layout || !panes || !out_count) return -1;

    *out_count = 0;

    // Skip checksum (4 hex chars + comma)
    const char *p = strchr(layout, ',');
    if (!p) return -1;
    p++; // skip the comma after checksum

    p = parse_layout_node(p, panes, max_panes, out_count);
    return (p != NULL) ? 0 : -1;
}
```

**Step 4: Run tests**

```bash
cd MuxiCore && swift test 2>&1 | grep -E "(Test Suite|Test Case|passed|failed)"
```

Expected: All TmuxProtocolTests pass.

**Step 5: Commit**

```bash
cd /path/to/Muxi
git add -A
git commit -m "feat: add tmux control mode protocol parser in C with layout parsing"
```

---

### Task 6: VT Parser (C)

**Why now:** Terminal rendering needs VT escape sequence parsing. Core C component.

**Files:**
- Modify: `MuxiCore/Sources/VTParser/include/vt_parser.h`
- Modify: `MuxiCore/Sources/VTParser/vt_parser.c`
- Modify: `MuxiCore/Tests/VTParserTests/VTParserTests.swift`

**Step 1: Write VT parser tests**

`MuxiCore/Tests/VTParserTests/VTParserTests.swift`:
```swift
import XCTest
@testable import VTParser

final class VTParserTests: XCTestCase {

    func testPlainText() {
        var parser = VTParserState()
        vt_parser_init(&parser, 80, 24)

        let text = "Hello, World!"
        vt_parser_feed(&parser, text, Int32(text.utf8.count))

        // Check that characters were written to the buffer
        var buf = [CChar](repeating: 0, count: 256)
        let len = vt_parser_get_line(&parser, 0, &buf, 256)
        let line = String(cString: buf)
        XCTAssertTrue(line.hasPrefix("Hello, World!"))
        XCTAssertGreaterThan(len, 0)

        vt_parser_destroy(&parser)
    }

    func testNewline() {
        var parser = VTParserState()
        vt_parser_init(&parser, 80, 24)

        let text = "Line1\r\nLine2"
        vt_parser_feed(&parser, text, Int32(text.utf8.count))

        var buf1 = [CChar](repeating: 0, count: 256)
        vt_parser_get_line(&parser, 0, &buf1, 256)
        XCTAssertTrue(String(cString: buf1).hasPrefix("Line1"))

        var buf2 = [CChar](repeating: 0, count: 256)
        vt_parser_get_line(&parser, 1, &buf2, 256)
        XCTAssertTrue(String(cString: buf2).hasPrefix("Line2"))

        vt_parser_destroy(&parser)
    }

    func testCursorMovement() {
        var parser = VTParserState()
        vt_parser_init(&parser, 80, 24)

        // ESC[2;5H = move cursor to row 2, col 5
        let text = "\u{1b}[2;5HX"
        vt_parser_feed(&parser, text, Int32(text.utf8.count))

        XCTAssertEqual(parser.cursor_row, 1)  // 0-indexed
        XCTAssertEqual(parser.cursor_col, 5)  // past 'X'

        vt_parser_destroy(&parser)
    }

    func testColorSGR() {
        var parser = VTParserState()
        vt_parser_init(&parser, 80, 24)

        // ESC[31m = set foreground red
        let text = "\u{1b}[31mR"
        vt_parser_feed(&parser, text, Int32(text.utf8.count))

        // Cell at (0,0) should have fg color = red (1)
        var cell = VTCell()
        vt_parser_get_cell(&parser, 0, 0, &cell)
        XCTAssertEqual(cell.fg_color, 1) // ANSI red
        XCTAssertEqual(cell.character, UInt32(Character("R").asciiValue!))

        vt_parser_destroy(&parser)
    }

    func testTrueColor() {
        var parser = VTParserState()
        vt_parser_init(&parser, 80, 24)

        // ESC[38;2;255;128;0m = set fg to RGB(255, 128, 0)
        let text = "\u{1b}[38;2;255;128;0mX"
        vt_parser_feed(&parser, text, Int32(text.utf8.count))

        var cell = VTCell()
        vt_parser_get_cell(&parser, 0, 0, &cell)
        XCTAssertEqual(cell.fg_r, 255)
        XCTAssertEqual(cell.fg_g, 128)
        XCTAssertEqual(cell.fg_b, 0)
        XCTAssertTrue(cell.fg_is_rgb != 0)

        vt_parser_destroy(&parser)
    }

    func testEraseDisplay() {
        var parser = VTParserState()
        vt_parser_init(&parser, 80, 24)

        let text = "AAAA\u{1b}[2J"  // write AAAA, then erase display
        vt_parser_feed(&parser, text, Int32(text.utf8.count))

        var cell = VTCell()
        vt_parser_get_cell(&parser, 0, 0, &cell)
        XCTAssertEqual(cell.character, 0) // blank after erase

        vt_parser_destroy(&parser)
    }

    func testResize() {
        var parser = VTParserState()
        vt_parser_init(&parser, 80, 24)
        XCTAssertEqual(parser.cols, 80)
        XCTAssertEqual(parser.rows, 24)

        vt_parser_resize(&parser, 120, 40)
        XCTAssertEqual(parser.cols, 120)
        XCTAssertEqual(parser.rows, 40)

        vt_parser_destroy(&parser)
    }
}
```

**Step 2: Run tests — fail**

**Step 3: Implement VT parser**

This is a substantial C file. The key components:
- State machine for escape sequence parsing (GROUND, ESCAPE, CSI_ENTRY, CSI_PARAM, etc.)
- Screen buffer (2D grid of cells)
- Cursor management
- SGR (Select Graphic Rendition) for colors/attributes

`MuxiCore/Sources/VTParser/include/vt_parser.h`:
```c
#ifndef VT_PARSER_H
#define VT_PARSER_H

#include <stdint.h>
#include <stddef.h>

// Cell in the terminal buffer
typedef struct {
    uint32_t character;    // Unicode codepoint
    uint8_t  fg_color;     // ANSI 0-255 foreground (when fg_is_rgb == 0)
    uint8_t  bg_color;     // ANSI 0-255 background (when bg_is_rgb == 0)
    uint8_t  fg_r, fg_g, fg_b;  // RGB foreground
    uint8_t  bg_r, bg_g, bg_b;  // RGB background
    uint8_t  fg_is_rgb;    // 1 if using RGB fg
    uint8_t  bg_is_rgb;    // 1 if using RGB bg
    uint8_t  attrs;        // bold=1, underline=2, italic=4, inverse=8, strikethrough=16
    uint8_t  width;        // 1 for normal, 2 for wide (CJK)
} VTCell;

// Parser state machine states
typedef enum {
    VT_STATE_GROUND = 0,
    VT_STATE_ESCAPE,
    VT_STATE_CSI_ENTRY,
    VT_STATE_CSI_PARAM,
    VT_STATE_OSC,
    VT_STATE_DCS,
} VTState;

// Parser instance (one per pane)
typedef struct {
    VTCell  *buffer;       // rows * cols cells
    int32_t  cols;
    int32_t  rows;
    int32_t  cursor_row;
    int32_t  cursor_col;
    VTState  state;
    VTCell   current_attrs; // current color/attribute state

    // CSI parameter accumulation
    int      csi_params[16];
    int      csi_param_count;
    int      csi_private;   // '?' prefix

    // Scroll region
    int      scroll_top;
    int      scroll_bottom;

    // UTF-8 accumulation
    uint8_t  utf8_buf[4];
    int      utf8_len;
    int      utf8_expected;
} VTParserState;

// Initialize parser with given dimensions
void vt_parser_init(VTParserState *parser, int cols, int rows);

// Free parser resources
void vt_parser_destroy(VTParserState *parser);

// Feed data into the parser
void vt_parser_feed(VTParserState *parser, const char *data, int len);

// Resize the terminal
void vt_parser_resize(VTParserState *parser, int cols, int rows);

// Get a line as plain text (for debugging). Returns chars written.
int vt_parser_get_line(VTParserState *parser, int row, char *buf, int buf_size);

// Get a specific cell
void vt_parser_get_cell(VTParserState *parser, int row, int col, VTCell *out);

#endif
```

`MuxiCore/Sources/VTParser/vt_parser.c`:
```c
#include "vt_parser.h"
#include <stdlib.h>
#include <string.h>

static VTCell *cell_at(VTParserState *p, int row, int col) {
    if (row < 0 || row >= p->rows || col < 0 || col >= p->cols) return NULL;
    return &p->buffer[row * p->cols + col];
}

static void clear_row(VTParserState *p, int row) {
    for (int c = 0; c < p->cols; c++) {
        VTCell *cell = cell_at(p, row, c);
        if (cell) memset(cell, 0, sizeof(VTCell));
    }
}

static void scroll_up(VTParserState *p) {
    int top = p->scroll_top;
    int bot = p->scroll_bottom;
    memmove(&p->buffer[top * p->cols],
            &p->buffer[(top + 1) * p->cols],
            (size_t)(bot - top) * (size_t)p->cols * sizeof(VTCell));
    clear_row(p, bot);
}

static void put_char(VTParserState *p, uint32_t ch) {
    if (p->cursor_col >= p->cols) {
        p->cursor_col = 0;
        p->cursor_row++;
        if (p->cursor_row > p->scroll_bottom) {
            p->cursor_row = p->scroll_bottom;
            scroll_up(p);
        }
    }

    VTCell *cell = cell_at(p, p->cursor_row, p->cursor_col);
    if (cell) {
        *cell = p->current_attrs;
        cell->character = ch;
        cell->width = 1;
    }
    p->cursor_col++;
}

static void handle_sgr(VTParserState *p) {
    if (p->csi_param_count == 0) {
        // ESC[m = reset
        memset(&p->current_attrs, 0, sizeof(VTCell));
        return;
    }

    for (int i = 0; i < p->csi_param_count; i++) {
        int param = p->csi_params[i];

        if (param == 0) {
            memset(&p->current_attrs, 0, sizeof(VTCell));
        } else if (param == 1) {
            p->current_attrs.attrs |= 1; // bold
        } else if (param == 3) {
            p->current_attrs.attrs |= 4; // italic
        } else if (param == 4) {
            p->current_attrs.attrs |= 2; // underline
        } else if (param == 7) {
            p->current_attrs.attrs |= 8; // inverse
        } else if (param == 9) {
            p->current_attrs.attrs |= 16; // strikethrough
        } else if (param >= 30 && param <= 37) {
            p->current_attrs.fg_color = (uint8_t)(param - 30);
            p->current_attrs.fg_is_rgb = 0;
        } else if (param >= 40 && param <= 47) {
            p->current_attrs.bg_color = (uint8_t)(param - 40);
            p->current_attrs.bg_is_rgb = 0;
        } else if (param == 38 && i + 4 < p->csi_param_count && p->csi_params[i+1] == 2) {
            // 38;2;r;g;b - true color fg
            p->current_attrs.fg_r = (uint8_t)p->csi_params[i+2];
            p->current_attrs.fg_g = (uint8_t)p->csi_params[i+3];
            p->current_attrs.fg_b = (uint8_t)p->csi_params[i+4];
            p->current_attrs.fg_is_rgb = 1;
            i += 4;
        } else if (param == 48 && i + 4 < p->csi_param_count && p->csi_params[i+1] == 2) {
            // 48;2;r;g;b - true color bg
            p->current_attrs.bg_r = (uint8_t)p->csi_params[i+2];
            p->current_attrs.bg_g = (uint8_t)p->csi_params[i+3];
            p->current_attrs.bg_b = (uint8_t)p->csi_params[i+4];
            p->current_attrs.bg_is_rgb = 1;
            i += 4;
        } else if (param == 38 && i + 2 < p->csi_param_count && p->csi_params[i+1] == 5) {
            // 38;5;n - 256 color fg
            p->current_attrs.fg_color = (uint8_t)p->csi_params[i+2];
            p->current_attrs.fg_is_rgb = 0;
            i += 2;
        } else if (param == 48 && i + 2 < p->csi_param_count && p->csi_params[i+1] == 5) {
            // 48;5;n - 256 color bg
            p->current_attrs.bg_color = (uint8_t)p->csi_params[i+2];
            p->current_attrs.bg_is_rgb = 0;
            i += 2;
        }
    }
}

static void handle_csi(VTParserState *p, char cmd) {
    int n = (p->csi_param_count > 0) ? p->csi_params[0] : 0;
    int m = (p->csi_param_count > 1) ? p->csi_params[1] : 0;

    switch (cmd) {
    case 'A': // Cursor Up
        p->cursor_row -= (n > 0 ? n : 1);
        if (p->cursor_row < 0) p->cursor_row = 0;
        break;
    case 'B': // Cursor Down
        p->cursor_row += (n > 0 ? n : 1);
        if (p->cursor_row >= p->rows) p->cursor_row = p->rows - 1;
        break;
    case 'C': // Cursor Forward
        p->cursor_col += (n > 0 ? n : 1);
        if (p->cursor_col >= p->cols) p->cursor_col = p->cols - 1;
        break;
    case 'D': // Cursor Back
        p->cursor_col -= (n > 0 ? n : 1);
        if (p->cursor_col < 0) p->cursor_col = 0;
        break;
    case 'H': // Cursor Position
    case 'f':
        p->cursor_row = (n > 0 ? n - 1 : 0);
        p->cursor_col = (m > 0 ? m - 1 : 0);
        if (p->cursor_row >= p->rows) p->cursor_row = p->rows - 1;
        if (p->cursor_col >= p->cols) p->cursor_col = p->cols - 1;
        break;
    case 'J': // Erase in Display
        if (n == 0) {
            // Erase from cursor to end
            for (int c = p->cursor_col; c < p->cols; c++) {
                VTCell *cell = cell_at(p, p->cursor_row, c);
                if (cell) memset(cell, 0, sizeof(VTCell));
            }
            for (int r = p->cursor_row + 1; r < p->rows; r++) clear_row(p, r);
        } else if (n == 1) {
            // Erase from start to cursor
            for (int r = 0; r < p->cursor_row; r++) clear_row(p, r);
            for (int c = 0; c <= p->cursor_col; c++) {
                VTCell *cell = cell_at(p, p->cursor_row, c);
                if (cell) memset(cell, 0, sizeof(VTCell));
            }
        } else if (n == 2) {
            // Erase entire display
            for (int r = 0; r < p->rows; r++) clear_row(p, r);
        }
        break;
    case 'K': // Erase in Line
        if (n == 0) {
            for (int c = p->cursor_col; c < p->cols; c++) {
                VTCell *cell = cell_at(p, p->cursor_row, c);
                if (cell) memset(cell, 0, sizeof(VTCell));
            }
        } else if (n == 1) {
            for (int c = 0; c <= p->cursor_col; c++) {
                VTCell *cell = cell_at(p, p->cursor_row, c);
                if (cell) memset(cell, 0, sizeof(VTCell));
            }
        } else if (n == 2) {
            clear_row(p, p->cursor_row);
        }
        break;
    case 'm': // SGR
        handle_sgr(p);
        break;
    case 'r': // Set Scroll Region
        p->scroll_top = (n > 0 ? n - 1 : 0);
        p->scroll_bottom = (m > 0 ? m - 1 : p->rows - 1);
        break;
    }
}

void vt_parser_init(VTParserState *parser, int cols, int rows) {
    memset(parser, 0, sizeof(VTParserState));
    parser->cols = cols;
    parser->rows = rows;
    parser->scroll_bottom = rows - 1;
    parser->buffer = calloc((size_t)(rows * cols), sizeof(VTCell));
}

void vt_parser_destroy(VTParserState *parser) {
    if (parser->buffer) {
        free(parser->buffer);
        parser->buffer = NULL;
    }
}

void vt_parser_feed(VTParserState *parser, const char *data, int len) {
    for (int i = 0; i < len; i++) {
        unsigned char ch = (unsigned char)data[i];

        switch (parser->state) {
        case VT_STATE_GROUND:
            if (ch == 0x1b) {
                parser->state = VT_STATE_ESCAPE;
            } else if (ch == '\n') {
                parser->cursor_row++;
                if (parser->cursor_row > parser->scroll_bottom) {
                    parser->cursor_row = parser->scroll_bottom;
                    scroll_up(parser);
                }
            } else if (ch == '\r') {
                parser->cursor_col = 0;
            } else if (ch == '\t') {
                parser->cursor_col = (parser->cursor_col + 8) & ~7;
                if (parser->cursor_col >= parser->cols) parser->cursor_col = parser->cols - 1;
            } else if (ch == '\b') {
                if (parser->cursor_col > 0) parser->cursor_col--;
            } else if (ch >= 0x20) {
                // Handle UTF-8 multibyte
                if (ch >= 0x80) {
                    if (parser->utf8_expected == 0) {
                        if ((ch & 0xE0) == 0xC0) { parser->utf8_expected = 2; }
                        else if ((ch & 0xF0) == 0xE0) { parser->utf8_expected = 3; }
                        else if ((ch & 0xF8) == 0xF0) { parser->utf8_expected = 4; }
                        else { continue; }
                        parser->utf8_buf[0] = ch;
                        parser->utf8_len = 1;
                    } else {
                        parser->utf8_buf[parser->utf8_len++] = ch;
                    }
                    if (parser->utf8_len == parser->utf8_expected) {
                        uint32_t cp = 0;
                        if (parser->utf8_expected == 2) {
                            cp = ((parser->utf8_buf[0] & 0x1F) << 6) | (parser->utf8_buf[1] & 0x3F);
                        } else if (parser->utf8_expected == 3) {
                            cp = ((parser->utf8_buf[0] & 0x0F) << 12) |
                                 ((parser->utf8_buf[1] & 0x3F) << 6) |
                                  (parser->utf8_buf[2] & 0x3F);
                        } else if (parser->utf8_expected == 4) {
                            cp = ((parser->utf8_buf[0] & 0x07) << 18) |
                                 ((parser->utf8_buf[1] & 0x3F) << 12) |
                                 ((parser->utf8_buf[2] & 0x3F) << 6) |
                                  (parser->utf8_buf[3] & 0x3F);
                        }
                        put_char(parser, cp);
                        parser->utf8_expected = 0;
                        parser->utf8_len = 0;
                    }
                } else {
                    put_char(parser, ch);
                }
            }
            break;

        case VT_STATE_ESCAPE:
            if (ch == '[') {
                parser->state = VT_STATE_CSI_ENTRY;
                parser->csi_param_count = 0;
                parser->csi_private = 0;
                memset(parser->csi_params, 0, sizeof(parser->csi_params));
            } else if (ch == ']') {
                parser->state = VT_STATE_OSC;
            } else {
                parser->state = VT_STATE_GROUND;
            }
            break;

        case VT_STATE_CSI_ENTRY:
            if (ch == '?') {
                parser->csi_private = 1;
                parser->state = VT_STATE_CSI_PARAM;
            } else if (ch >= '0' && ch <= '9') {
                parser->csi_params[0] = ch - '0';
                parser->csi_param_count = 1;
                parser->state = VT_STATE_CSI_PARAM;
            } else if (ch == ';') {
                parser->csi_param_count = 2;
                parser->state = VT_STATE_CSI_PARAM;
            } else if (ch >= 0x40 && ch <= 0x7e) {
                handle_csi(parser, (char)ch);
                parser->state = VT_STATE_GROUND;
            } else {
                parser->state = VT_STATE_GROUND;
            }
            break;

        case VT_STATE_CSI_PARAM:
            if (ch >= '0' && ch <= '9') {
                int idx = parser->csi_param_count > 0 ? parser->csi_param_count - 1 : 0;
                if (idx < 16) {
                    parser->csi_params[idx] = parser->csi_params[idx] * 10 + (ch - '0');
                    if (parser->csi_param_count == 0) parser->csi_param_count = 1;
                }
            } else if (ch == ';') {
                if (parser->csi_param_count < 16) parser->csi_param_count++;
            } else if (ch >= 0x40 && ch <= 0x7e) {
                handle_csi(parser, (char)ch);
                parser->state = VT_STATE_GROUND;
            } else {
                parser->state = VT_STATE_GROUND;
            }
            break;

        case VT_STATE_OSC:
            // Skip OSC sequences (terminated by BEL or ST)
            if (ch == 0x07 || ch == 0x1b) {
                parser->state = VT_STATE_GROUND;
            }
            break;

        case VT_STATE_DCS:
            if (ch == 0x1b) parser->state = VT_STATE_GROUND;
            break;
        }
    }
}

void vt_parser_resize(VTParserState *parser, int cols, int rows) {
    VTCell *new_buf = calloc((size_t)(rows * cols), sizeof(VTCell));
    int copy_rows = (rows < parser->rows) ? rows : parser->rows;
    int copy_cols = (cols < parser->cols) ? cols : parser->cols;

    for (int r = 0; r < copy_rows; r++) {
        memcpy(&new_buf[r * cols], &parser->buffer[r * parser->cols],
               (size_t)copy_cols * sizeof(VTCell));
    }

    free(parser->buffer);
    parser->buffer = new_buf;
    parser->cols = cols;
    parser->rows = rows;
    parser->scroll_bottom = rows - 1;
    if (parser->cursor_row >= rows) parser->cursor_row = rows - 1;
    if (parser->cursor_col >= cols) parser->cursor_col = cols - 1;
}

int vt_parser_get_line(VTParserState *parser, int row, char *buf, int buf_size) {
    if (row < 0 || row >= parser->rows || !buf) return 0;
    int pos = 0;
    for (int c = 0; c < parser->cols && pos < buf_size - 1; c++) {
        VTCell *cell = cell_at(parser, row, c);
        uint32_t ch = cell ? cell->character : 0;
        if (ch == 0) ch = ' ';
        if (ch < 128) {
            buf[pos++] = (char)ch;
        }
    }
    buf[pos] = '\0';
    return pos;
}

void vt_parser_get_cell(VTParserState *parser, int row, int col, VTCell *out) {
    VTCell *cell = cell_at(parser, row, col);
    if (cell && out) {
        *out = *cell;
    } else if (out) {
        memset(out, 0, sizeof(VTCell));
    }
}
```

**Step 4: Run tests**

```bash
cd MuxiCore && swift test 2>&1 | grep -E "(Test Suite|Test Case|passed|failed)"
```

Expected: All VTParserTests pass.

**Step 5: Commit**

```bash
cd /path/to/Muxi
git add -A
git commit -m "feat: add VT escape sequence parser in C — cursor, color, SGR, UTF-8, scroll"
```

---

## Phase 4: SSH & tmux Integration (Swift Layer)

### Task 7: libssh2 SPM Integration

**Why now:** SSH is needed before any server connection works.

**Note:** libssh2 needs to be cross-compiled for iOS. The recommended approach is to use a pre-built xcframework or build from source using a build script. For MVP, we use the [NMSSH](https://github.com/NMSSH/NMSSH) Objective-C wrapper or build libssh2 ourselves.

**Pragmatic approach for MVP:** Use a pure-Swift SSH library or a pre-packaged libssh2 SPM wrapper. Several community packages exist:
- `Shout` (libssh2 wrapper, SPM compatible)
- `SwiftSH` (libssh2 for iOS)

For the implementation plan, we define the `SSHService` interface first with a protocol, allowing the actual SSH library to be swapped.

**Files:**
- Create: `Muxi/Services/SSHService.swift` (protocol + implementation)
- Test: `MuxiTests/Services/SSHServiceTests.swift` (protocol-based mock tests)

**Step 1: Define SSH protocol and write mock tests**

`MuxiTests/Services/SSHServiceTests.swift`:
```swift
import XCTest
@testable import Muxi

final class SSHServiceTests: XCTestCase {

    func testConnectionStateTransitions() {
        let service = MockSSHService()
        XCTAssertEqual(service.state, .disconnected)

        service.simulateConnect()
        XCTAssertEqual(service.state, .connected)

        service.simulateDisconnect()
        XCTAssertEqual(service.state, .disconnected)
    }

    func testExecCommand() async throws {
        let service = MockSSHService()
        service.simulateConnect()
        service.mockExecResult = "session1: 2 windows\nsession2: 1 windows\n"

        let result = try await service.exec("tmux list-sessions")
        XCTAssertTrue(result.contains("session1"))
    }

    func testExecWhenDisconnected() async {
        let service = MockSSHService()
        do {
            _ = try await service.exec("ls")
            XCTFail("Should throw when disconnected")
        } catch {
            // expected
        }
    }
}

// Mock for testing without real SSH server
class MockSSHService: SSHServiceProtocol {
    var state: SSHConnectionState = .disconnected
    var mockExecResult: String = ""

    func connect(host: String, port: UInt16, username: String, auth: SSHAuth) async throws {
        state = .connected
    }

    func disconnect() {
        state = .disconnected
    }

    func exec(_ command: String) async throws -> String {
        guard state == .connected else { throw SSHError.notConnected }
        return mockExecResult
    }

    func startShell(onData: @escaping (Data) -> Void) async throws -> SSHChannel {
        guard state == .connected else { throw SSHError.notConnected }
        return MockSSHChannel()
    }

    // Test helpers
    func simulateConnect() { state = .connected }
    func simulateDisconnect() { state = .disconnected }
}

class MockSSHChannel: SSHChannel {
    func write(_ data: Data) throws {}
    func close() {}
    func resize(cols: Int, rows: Int) throws {}
}
```

**Step 2: Run tests — fail**

**Step 3: Implement SSH protocol and types**

`Muxi/Services/SSHService.swift`:
```swift
import Foundation

enum SSHConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)
}

enum SSHAuth {
    case password(String)
    case key(privateKey: Data, passphrase: String?)
}

enum SSHError: Error {
    case notConnected
    case authenticationFailed
    case connectionFailed(String)
    case channelError(String)
    case timeout
}

protocol SSHChannel: AnyObject {
    func write(_ data: Data) throws
    func close()
    func resize(cols: Int, rows: Int) throws
}

protocol SSHServiceProtocol: AnyObject {
    var state: SSHConnectionState { get }
    func connect(host: String, port: UInt16, username: String, auth: SSHAuth) async throws
    func disconnect()
    func exec(_ command: String) async throws -> String
    func startShell(onData: @escaping (Data) -> Void) async throws -> SSHChannel
}

// Real implementation — to be filled when libssh2 is integrated
final class SSHService: SSHServiceProtocol {
    private(set) var state: SSHConnectionState = .disconnected

    func connect(host: String, port: UInt16, username: String, auth: SSHAuth) async throws {
        state = .connecting
        // TODO: libssh2 connection
        state = .connected
    }

    func disconnect() {
        // TODO: libssh2 disconnect
        state = .disconnected
    }

    func exec(_ command: String) async throws -> String {
        guard state == .connected else { throw SSHError.notConnected }
        // TODO: libssh2 exec channel
        return ""
    }

    func startShell(onData: @escaping (Data) -> Void) async throws -> SSHChannel {
        guard state == .connected else { throw SSHError.notConnected }
        // TODO: libssh2 shell channel
        fatalError("Not yet implemented")
    }
}
```

**Step 4: Run tests**

```bash
xcodegen generate
xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "(Test Suite|Executed|PASS|FAIL)"
```

Expected: All tests pass.

**Step 5: Commit**

```bash
git add -A
git commit -m "feat: add SSHService protocol with mock tests — real libssh2 integration pending"
```

---

### Task 8: TmuxControlService (Swift)

**Why now:** Bridges C protocol parser to Swift layer. Manages tmux session state.

**Files:**
- Create: `Muxi/Services/TmuxControlService.swift`
- Test: `MuxiTests/Services/TmuxControlServiceTests.swift`

**Step 1: Write tests**

`MuxiTests/Services/TmuxControlServiceTests.swift`:
```swift
import XCTest
@testable import Muxi

@MainActor
final class TmuxControlServiceTests: XCTestCase {

    func testParseSessionList() {
        let output = """
        main: 2 windows (created Fri Feb 28 10:00:00 2026)
        dev: 1 windows (created Fri Feb 28 11:00:00 2026)
        """
        let sessions = TmuxControlService.parseSessionList(output)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].name, "main")
        XCTAssertEqual(sessions[1].name, "dev")
    }

    func testParseSessionListFormatted() {
        let output = """
        $0:main:2:1740700800
        $1:dev:1:1740704400
        """
        let sessions = TmuxControlService.parseFormattedSessionList(output)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].id, "$0")
        XCTAssertEqual(sessions[0].name, "main")
        XCTAssertEqual(sessions[0].windows.count, 0) // windows loaded separately
    }

    func testHandleControlModeOutput() {
        let service = TmuxControlService()
        var receivedPaneId: String?
        var receivedData: String?

        service.onPaneOutput = { paneId, data in
            receivedPaneId = paneId
            receivedData = data
        }

        service.handleLine("%output %0 Hello\\n")

        XCTAssertEqual(receivedPaneId, "%0")
        XCTAssertNotNil(receivedData)
    }

    func testHandleLayoutChange() {
        let service = TmuxControlService()
        var receivedWindowId: String?

        service.onLayoutChange = { windowId, panes in
            receivedWindowId = windowId
        }

        service.handleLine("%layout-change @0 abcd,80x24,0,0{40x24,0,0,0,39x24,41,0,1}")

        XCTAssertEqual(receivedWindowId, "@0")
    }

    func testHandleSessionChanged() {
        let service = TmuxControlService()
        var receivedName: String?

        service.onSessionChanged = { id, name in
            receivedName = name
        }

        service.handleLine("%session-changed $0 work")

        XCTAssertEqual(receivedName, "work")
    }

    func testHandleExit() {
        let service = TmuxControlService()
        var exitCalled = false

        service.onExit = {
            exitCalled = true
        }

        service.handleLine("%exit")

        XCTAssertTrue(exitCalled)
    }
}
```

**Step 2: Run tests — fail**

**Step 3: Implement TmuxControlService**

`Muxi/Services/TmuxControlService.swift`:
```swift
import Foundation
import TmuxProtocol

final class TmuxControlService {
    // Callbacks for control mode events
    var onPaneOutput: ((_ paneId: String, _ data: String) -> Void)?
    var onLayoutChange: ((_ windowId: String, _ panes: [ParsedPane]) -> Void)?
    var onWindowAdd: ((_ windowId: String) -> Void)?
    var onWindowClose: ((_ windowId: String) -> Void)?
    var onSessionChanged: ((_ sessionId: String, _ name: String) -> Void)?
    var onExit: (() -> Void)?

    struct ParsedPane {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
        let paneId: Int
    }

    // Parse a single line from tmux control mode output
    func handleLine(_ line: String) {
        var msg = TmuxMessage()
        let type = tmux_parse_line(line, &msg)

        switch type {
        case TMUX_MSG_OUTPUT:
            let paneId = String(cString: withUnsafePointer(to: msg.pane_id) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(TMUX_ID_MAX)) { $0 }
            })
            let data: String
            if let ptr = msg.output_data {
                data = String(cString: ptr)
            } else {
                data = ""
            }
            onPaneOutput?(paneId, data)

        case TMUX_MSG_LAYOUT_CHANGE:
            let windowId = withUnsafePointer(to: msg.window_id) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(TMUX_ID_MAX)) {
                    String(cString: $0)
                }
            }
            let layoutStr = withUnsafePointer(to: msg.layout) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(TMUX_DATA_MAX)) {
                    String(cString: $0)
                }
            }
            let panes = parseLayout(layoutStr)
            onLayoutChange?(windowId, panes)

        case TMUX_MSG_WINDOW_ADD:
            let windowId = withUnsafePointer(to: msg.window_id) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(TMUX_ID_MAX)) {
                    String(cString: $0)
                }
            }
            onWindowAdd?(windowId)

        case TMUX_MSG_WINDOW_CLOSE:
            let windowId = withUnsafePointer(to: msg.window_id) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(TMUX_ID_MAX)) {
                    String(cString: $0)
                }
            }
            onWindowClose?(windowId)

        case TMUX_MSG_SESSION_CHANGED:
            let sessionId = withUnsafePointer(to: msg.session_id) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(TMUX_ID_MAX)) {
                    String(cString: $0)
                }
            }
            let name = withUnsafePointer(to: msg.session_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(TMUX_NAME_MAX)) {
                    String(cString: $0)
                }
            }
            onSessionChanged?(sessionId, name)

        case TMUX_MSG_EXIT:
            onExit?()

        default:
            break
        }
    }

    // Parse layout string into pane geometries
    private func parseLayout(_ layout: String) -> [ParsedPane] {
        var cPanes = [TmuxLayoutPane](repeating: TmuxLayoutPane(), count: 64)
        var count: Int32 = 0

        let result = tmux_parse_layout(layout, &cPanes, 64, &count)
        guard result == 0 else { return [] }

        return (0..<Int(count)).map { i in
            ParsedPane(
                x: Int(cPanes[i].x),
                y: Int(cPanes[i].y),
                width: Int(cPanes[i].width),
                height: Int(cPanes[i].height),
                paneId: Int(cPanes[i].pane_id)
            )
        }
    }

    // Parse `tmux list-sessions` output (unformatted)
    static func parseSessionList(_ output: String) -> [TmuxSession] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard let name = parts.first else { return nil }
            return TmuxSession(
                id: "$\(name)",
                name: String(name),
                windows: [],
                createdAt: Date(),
                lastActivity: Date()
            )
        }
    }

    // Parse `tmux list-sessions -F '#{session_id}:#{session_name}:#{session_windows}:#{session_activity}'`
    static func parseFormattedSessionList(_ output: String) -> [TmuxSession] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: ":", maxSplits: 3)
            guard parts.count >= 3 else { return nil }
            let id = String(parts[0])
            let name = String(parts[1])
            return TmuxSession(
                id: id,
                name: name,
                windows: [],
                createdAt: Date(),
                lastActivity: Date()
            )
        }
    }
}
```

**Step 4: Run tests**

```bash
xcodegen generate
xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "(Test Suite|Executed|PASS|FAIL)"
```

Expected: All tests pass.

**Step 5: Commit**

```bash
git add -A
git commit -m "feat: add TmuxControlService — bridges C protocol parser to Swift with callbacks"
```

---

### Task 9: ConnectionManager

**Files:**
- Create: `Muxi/Services/ConnectionManager.swift`
- Test: `MuxiTests/Services/ConnectionManagerTests.swift`

**Step 1: Write tests**

`MuxiTests/Services/ConnectionManagerTests.swift`:
```swift
import XCTest
@testable import Muxi

@MainActor
final class ConnectionManagerTests: XCTestCase {

    func testConnectFlow() async throws {
        let ssh = MockSSHService()
        ssh.mockExecResult = "$0:main:2:1740700800"
        let manager = ConnectionManager(sshService: ssh)

        let sessions = try await manager.connect(
            server: Server(name: "T", host: "h", username: "u", authMethod: .password),
            password: "p"
        )

        XCTAssertEqual(manager.state, .sessionList)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].name, "main")
    }

    func testDisconnect() async throws {
        let ssh = MockSSHService()
        ssh.mockExecResult = "$0:test:1:0"
        let manager = ConnectionManager(sshService: ssh)
        _ = try await manager.connect(
            server: Server(name: "T", host: "h", username: "u", authMethod: .password),
            password: "p"
        )

        manager.disconnect()
        XCTAssertEqual(manager.state, .disconnected)
    }
}
```

**Step 2: Implement**

`Muxi/Services/ConnectionManager.swift`:
```swift
import Foundation

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case sessionList
    case attached(sessionName: String)
    case reconnecting
}

@MainActor
@Observable
final class ConnectionManager {
    private let sshService: SSHServiceProtocol
    private let tmuxService = TmuxControlService()
    private let keychainService = KeychainService()

    private(set) var state: ConnectionState = .disconnected
    private(set) var currentServer: Server?
    private(set) var sessions: [TmuxSession] = []

    init(sshService: SSHServiceProtocol = SSHService()) {
        self.sshService = sshService
    }

    func connect(server: Server, password: String? = nil) async throws -> [TmuxSession] {
        state = .connecting
        currentServer = server

        let auth: SSHAuth
        switch server.authMethod {
        case .password:
            let pw = password ?? (try keychainService.retrievePassword(account: server.id.uuidString))
            auth = .password(pw)
        case .key(let keyId):
            let (_, keyData) = try keychainService.retrieveSSHKey(id: keyId)
            auth = .key(privateKey: keyData, passphrase: nil)
        }

        try await sshService.connect(
            host: server.host,
            port: server.port,
            username: server.username,
            auth: auth
        )

        // Query tmux sessions
        let output = try await sshService.exec(
            "tmux list-sessions -F '#{session_id}:#{session_name}:#{session_windows}:#{session_activity}'"
        )
        sessions = TmuxControlService.parseFormattedSessionList(output)
        state = .sessionList
        return sessions
    }

    func disconnect() {
        sshService.disconnect()
        state = .disconnected
        currentServer = nil
        sessions = []
    }

    func attachSession(_ session: TmuxSession) async throws {
        state = .attached(sessionName: session.name)
        // In real implementation: start shell with `tmux -CC attach -t <name>`
        // and pipe output through tmuxService.handleLine()
    }

    func detach() {
        state = .sessionList
    }
}
```

**Step 3: Run tests, commit**

```bash
xcodegen generate
xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "(Test Suite|Executed|PASS|FAIL)"
git add -A
git commit -m "feat: add ConnectionManager — SSH connect, session query, state management"
```

---

## Phase 5: Terminal Rendering

### Task 10: TerminalBuffer (Swift Wrapper over VT Parser)

**Files:**
- Create: `Muxi/Terminal/TerminalBuffer.swift`
- Test: `MuxiTests/Terminal/TerminalBufferTests.swift`

**Step 1: Write tests**

`MuxiTests/Terminal/TerminalBufferTests.swift`:
```swift
import XCTest
@testable import Muxi

final class TerminalBufferTests: XCTestCase {

    func testWriteAndRead() {
        let buffer = TerminalBuffer(cols: 80, rows: 24)
        buffer.feed("Hello, Muxi!")

        let cell = buffer.cellAt(row: 0, col: 0)
        XCTAssertEqual(cell.character, Character("H"))
    }

    func testLineContent() {
        let buffer = TerminalBuffer(cols: 80, rows: 24)
        buffer.feed("Test Line")

        let line = buffer.lineText(row: 0)
        XCTAssertTrue(line.hasPrefix("Test Line"))
    }

    func testResize() {
        let buffer = TerminalBuffer(cols: 80, rows: 24)
        buffer.feed("Data")
        buffer.resize(cols: 120, rows: 40)

        XCTAssertEqual(buffer.cols, 120)
        XCTAssertEqual(buffer.rows, 40)
    }

    func testCursorPosition() {
        let buffer = TerminalBuffer(cols: 80, rows: 24)
        buffer.feed("AB")
        XCTAssertEqual(buffer.cursorCol, 2)
        XCTAssertEqual(buffer.cursorRow, 0)
    }
}
```

**Step 2: Implement**

`Muxi/Terminal/TerminalBuffer.swift`:
```swift
import Foundation
import VTParser

struct TerminalCell {
    let character: Character
    let fgColor: TerminalColor
    let bgColor: TerminalColor
    let isBold: Bool
    let isItalic: Bool
    let isUnderline: Bool
    let isInverse: Bool

    static let empty = TerminalCell(
        character: " ", fgColor: .default, bgColor: .default,
        isBold: false, isItalic: false, isUnderline: false, isInverse: false
    )
}

enum TerminalColor: Equatable {
    case `default`
    case ansi(UInt8)
    case rgb(UInt8, UInt8, UInt8)
}

final class TerminalBuffer {
    private var parser: VTParserState

    var cols: Int { Int(parser.cols) }
    var rows: Int { Int(parser.rows) }
    var cursorRow: Int { Int(parser.cursor_row) }
    var cursorCol: Int { Int(parser.cursor_col) }

    init(cols: Int, rows: Int) {
        parser = VTParserState()
        vt_parser_init(&parser, Int32(cols), Int32(rows))
    }

    deinit {
        vt_parser_destroy(&parser)
    }

    func feed(_ text: String) {
        text.withCString { ptr in
            vt_parser_feed(&parser, ptr, Int32(strlen(ptr)))
        }
    }

    func feedData(_ data: Data) {
        data.withUnsafeBytes { rawBuf in
            guard let ptr = rawBuf.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            vt_parser_feed(&parser, ptr, Int32(data.count))
        }
    }

    func resize(cols: Int, rows: Int) {
        vt_parser_resize(&parser, Int32(cols), Int32(rows))
    }

    func cellAt(row: Int, col: Int) -> TerminalCell {
        var cell = VTCell()
        vt_parser_get_cell(&parser, Int32(row), Int32(col), &cell)

        let ch: Character = cell.character > 0 ? Character(UnicodeScalar(cell.character)!) : " "
        let fg: TerminalColor = cell.fg_is_rgb != 0
            ? .rgb(cell.fg_r, cell.fg_g, cell.fg_b)
            : (cell.fg_color > 0 ? .ansi(cell.fg_color) : .default)
        let bg: TerminalColor = cell.bg_is_rgb != 0
            ? .rgb(cell.bg_r, cell.bg_g, cell.bg_b)
            : (cell.bg_color > 0 ? .ansi(cell.bg_color) : .default)

        return TerminalCell(
            character: ch,
            fgColor: fg,
            bgColor: bg,
            isBold: cell.attrs & 1 != 0,
            isItalic: cell.attrs & 4 != 0,
            isUnderline: cell.attrs & 2 != 0,
            isInverse: cell.attrs & 8 != 0
        )
    }

    func lineText(row: Int) -> String {
        var buf = [CChar](repeating: 0, count: cols + 1)
        vt_parser_get_line(&parser, Int32(row), &buf, Int32(buf.count))
        return String(cString: buf)
    }
}
```

**Step 3: Run tests, commit**

```bash
xcodegen generate
xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "(Test Suite|Executed|PASS|FAIL)"
git add -A
git commit -m "feat: add TerminalBuffer — Swift wrapper over C VT parser"
```

---

### Task 11: Theme System

**Files:**
- Create: `Muxi/Models/Theme.swift`
- Create: `Muxi/Resources/Themes/catppuccin-mocha.json`
- Test: `MuxiTests/Models/ThemeTests.swift`

(Implement theme loading from JSON. Each theme defines 16 ANSI colors + foreground/background defaults. This enables the renderer to map VT colors to actual RGB values.)

**Implementation:** Define `Theme` struct with `Codable` conformance, load from bundled JSON files. Create at least `catppuccin-mocha.json` for default. Remaining 9 themes follow the same JSON structure and can be added incrementally.

**Commit:** `feat: add theme system with Catppuccin Mocha default`

---

### Task 12: Terminal Metal Renderer

**Files:**
- Create: `Muxi/Terminal/TerminalRenderer.swift`
- Create: `Muxi/Terminal/Shaders.metal`

(Metal renderer that takes a `TerminalBuffer` and renders it as a textured glyph grid. Uses a glyph atlas texture generated from the bundled font. Each cell is a quad with font glyph + foreground/background colors from the current theme.)

**This is the most complex single task.** Key implementation points:
1. Font atlas generation (render each glyph into a texture atlas using Core Text)
2. Per-cell vertex buffer (position, UV, fg color, bg color)
3. Metal render pipeline (vertex + fragment shader)
4. Refresh on buffer change

**Commit:** `feat: add Metal terminal renderer with glyph atlas`

---

### Task 13: TerminalView (SwiftUI + Metal)

**Files:**
- Create: `Muxi/Views/Terminal/TerminalView.swift`
- Modify: `Muxi/Views/Terminal/PaneContainerView.swift`

(SwiftUI view that wraps the Metal renderer using `UIViewRepresentable`. Handles touch input forwarding to the pane's SSH channel.)

**Commit:** `feat: add TerminalView — SwiftUI wrapper for Metal renderer`

---

## Phase 6: Input & Session UI

### Task 14: Extended Keyboard

**Files:**
- Create: `Muxi/Views/Terminal/ExtendedKeyboardView.swift`
- Create: `Muxi/Terminal/InputHandler.swift`

(Toolbar above the keyboard with Ctrl, Alt, Esc, Tab, arrow keys. `InputHandler` translates extended key presses into the correct escape sequences for SSH channel transmission.)

**Commit:** `feat: add extended keyboard bar — Ctrl, Alt, Esc, Tab, arrows`

---

### Task 15: tmux Session List UI

**Files:**
- Create: `Muxi/ViewModels/SessionListViewModel.swift`
- Create: `Muxi/Views/SessionList/SessionListView.swift`
- Create: `Muxi/Views/SessionList/SessionRowView.swift`

(List of tmux sessions queried via SSH exec. Swipe to delete/rename. Tap to attach via `tmux -CC attach`. "+" to create new session.)

**Commit:** `feat: add tmux session list UI — list, create, delete, attach`

---

### Task 16: tmux Quick Action Menu

**Files:**
- Create: `Muxi/Views/QuickAction/QuickActionView.swift`
- Create: `Muxi/Views/QuickAction/QuickActionButton.swift`

(Floating button that opens a categorized command palette for pane/window/session operations. Commands are sent through `TmuxControlService` to the control mode connection.)

**Commit:** `feat: add tmux quick action menu — pane, window, session commands`

---

### Task 17: Adaptive Pane Layout

**Files:**
- Modify: `Muxi/Views/Terminal/PaneContainerView.swift`

(iPhone: tabs per pane. iPad: split views matching tmux layout geometry from `%layout-change`. Uses `TmuxControlService.onLayoutChange` to dynamically update layout.)

**Commit:** `feat: add adaptive pane layout — tabs on iPhone, splits on iPad`

---

## Phase 7: Integration & Polish

### Task 18: SSH Auto-Reconnect

**Files:**
- Modify: `Muxi/Services/ConnectionManager.swift`

(Implement the 5-step reconnection flow: detect disconnect → notify user → auto-reconnect → auto-reattach → restore state. Uses `ConnectionState.reconnecting`.)

**Commit:** `feat: add SSH auto-reconnect with tmux session reattach`

---

### Task 19: Error Handling UI

**Files:**
- Create: `Muxi/Views/Common/ErrorBannerView.swift`
- Create: `Muxi/Views/Common/ReconnectingOverlay.swift`

(Handles all error scenarios from the design doc: tmux not installed, version too old, connection failure, etc.)

**Commit:** `feat: add error handling UI — banners, reconnect overlay, install guide`

---

### Task 20: End-to-End Integration

**Files:**
- Modify: `Muxi/App/ContentView.swift`

(Wire all screens together: ServerList → connect → SessionList → attach → Terminal with PaneContainer + QuickAction + ExtendedKeyboard. Verify full navigation flow.)

**Commit:** `feat: wire end-to-end navigation — server to terminal flow complete`

---

## Task Dependency Graph

```
Task 1 (Project Setup)
  ├── Task 2 (Data Models)
  │     ├── Task 3 (KeychainService)
  │     │     └── Task 4 (Server UI)
  │     ├── Task 5 (tmux Protocol Parser - C)
  │     │     └── Task 8 (TmuxControlService - Swift)
  │     │           ├── Task 9 (ConnectionManager)
  │     │           ├── Task 15 (Session List UI)
  │     │           └── Task 16 (Quick Action Menu)
  │     └── Task 6 (VT Parser - C)
  │           └── Task 10 (TerminalBuffer)
  │                 ├── Task 11 (Theme System)
  │                 │     └── Task 12 (Metal Renderer)
  │                 │           └── Task 13 (TerminalView)
  │                 └── Task 14 (Extended Keyboard)
  │
  Task 7 (SSH Protocol) ─── feeds into ─── Task 9 (ConnectionManager)
  │
  Tasks 13-17 ─── Task 17 (Adaptive Layout)
  │
  All ─── Task 18 (Auto-Reconnect)
  All ─── Task 19 (Error Handling)
  All ─── Task 20 (Integration)
```

## Implementation Notes

- **Tasks 1-10 have full code listings** — these are foundation tasks where precision matters.
- **Tasks 11-20 have descriptions and commit messages** — the exact code depends on decisions made during earlier tasks (e.g., Metal API details depend on how the glyph atlas works).
- **libssh2 integration (Task 7)** is defined as a protocol boundary. The real libssh2 binding can be plugged in later without changing any other code.
- **Run tests after every task.** If tests break, fix before moving on.
- **Commit after every task.** Small, atomic commits.
