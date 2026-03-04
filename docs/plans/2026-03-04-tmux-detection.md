# tmux Install Detection Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Detect tmux availability after SSH connect and show TmuxInstallGuideView when tmux is missing or too old.

**Architecture:** `ConnectionManager.connect()` runs `tmux -V` before `list-sessions`. A new `TmuxError` enum captures not-installed/version-too-old. ContentView catches `TmuxError` and presents the existing `TmuxInstallGuideView` as a sheet with a "Retry" button.

**Tech Stack:** Swift, ConnectionManager, TmuxInstallGuideView (existing), MockSSHService

---

### Task 1: TmuxError enum + version parsing — Tests

**Files:**
- Create: `ios/MuxiTests/Models/TmuxErrorTests.swift`

**Step 1: Write the tests**

Use Swift Testing (`@Suite`, `@Test`, `#expect`) per CLAUDE.md. These tests cover the `TmuxError` enum and a static `parseTmuxVersion()` method.

```swift
import Testing

@testable import Muxi

@Suite("TmuxError Tests")
struct TmuxErrorTests {

    // MARK: - Version Parsing

    @Test("Parses standard version: tmux 3.4")
    func standardVersion() {
        let result = TmuxError.parseTmuxVersion("tmux 3.4\n")
        #expect(result == "3.4")
    }

    @Test("Parses version with letter suffix: tmux 3.3a")
    func versionWithLetterSuffix() {
        let result = TmuxError.parseTmuxVersion("tmux 3.3a\n")
        #expect(result == "3.3a")
    }

    @Test("Parses version with 'next' suffix: tmux next-3.4")
    func nextVersion() {
        let result = TmuxError.parseTmuxVersion("tmux next-3.4\n")
        #expect(result == "next-3.4")
    }

    @Test("Returns nil for empty string")
    func emptyString() {
        let result = TmuxError.parseTmuxVersion("")
        #expect(result == nil)
    }

    @Test("Returns nil for command not found output")
    func commandNotFound() {
        let result = TmuxError.parseTmuxVersion("bash: tmux: command not found\n")
        #expect(result == nil)
    }

    @Test("Returns nil for garbage output")
    func garbageOutput() {
        let result = TmuxError.parseTmuxVersion("some random output")
        #expect(result == nil)
    }

    // MARK: - Version Comparison

    @Test("Version 3.4 meets minimum 1.8")
    func meetsMinimum() {
        #expect(TmuxError.versionMeetsMinimum("3.4"))
    }

    @Test("Version 1.8 meets minimum 1.8")
    func exactMinimum() {
        #expect(TmuxError.versionMeetsMinimum("1.8"))
    }

    @Test("Version 1.7 does not meet minimum 1.8")
    func belowMinimum() {
        #expect(!TmuxError.versionMeetsMinimum("1.7"))
    }

    @Test("Version 1.6 does not meet minimum 1.8")
    func wellBelowMinimum() {
        #expect(!TmuxError.versionMeetsMinimum("1.6"))
    }

    @Test("Version 3.3a meets minimum (strips letter suffix)")
    func letterSuffixMeetsMinimum() {
        #expect(TmuxError.versionMeetsMinimum("3.3a"))
    }

    @Test("Unparseable version returns false")
    func unparseableVersion() {
        #expect(!TmuxError.versionMeetsMinimum("next-3.4"))
    }

    // MARK: - Error Messages

    @Test("notInstalled has descriptive error message")
    func notInstalledMessage() {
        let error = TmuxError.notInstalled
        #expect(error.errorDescription?.contains("not installed") == true)
    }

    @Test("versionTooOld includes detected version in message")
    func versionTooOldMessage() {
        let error = TmuxError.versionTooOld(detected: "1.6")
        #expect(error.errorDescription?.contains("1.6") == true)
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,id=7CB9F63E-39E2-43DE-BB29-F21330EE099B' -only-testing:MuxiTests/TmuxErrorTests 2>&1 | grep -E '(error:|FAIL)'`
Expected: FAIL — `TmuxError` does not exist yet.

**Step 3: Commit**

```bash
git add ios/MuxiTests/Models/TmuxErrorTests.swift
git commit -m "test: add failing tests for TmuxError and version parsing"
```

---

### Task 2: TmuxError enum + version parsing — Implementation

**Files:**
- Create: `ios/Muxi/Models/TmuxError.swift`

**Step 1: Write the implementation**

```swift
import Foundation

/// Errors thrown when tmux is not available or does not meet
/// the minimum version requirement on the connected server.
enum TmuxError: Error, LocalizedError {
    /// tmux is not installed on the server (command not found).
    case notInstalled
    /// tmux is installed but the version is below the minimum (1.8).
    case versionTooOld(detected: String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "tmux is not installed on this server."
        case .versionTooOld(let detected):
            return "tmux \(detected) is too old. Muxi requires tmux \(TmuxInstallGuideView.minimumVersion) or later."
        }
    }

    /// Parse the output of `tmux -V` and return the version string.
    ///
    /// Expected format: `"tmux 3.4\n"` or `"tmux 3.3a\n"`.
    /// Returns `nil` if the output doesn't start with `"tmux "`.
    static func parseTmuxVersion(_ output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("tmux ") else { return nil }
        let version = String(trimmed.dropFirst("tmux ".count))
        guard !version.isEmpty else { return nil }
        return version
    }

    /// Check whether a parsed version string meets the minimum (1.8).
    ///
    /// Extracts the numeric major.minor from strings like `"3.4"` or
    /// `"3.3a"`, stripping any trailing letter suffix. Returns `false`
    /// if the version cannot be parsed as a number.
    static func versionMeetsMinimum(_ version: String) -> Bool {
        // Strip trailing non-numeric characters (e.g., "3.3a" → "3.3").
        let numeric = String(version.prefix(while: { $0.isNumber || $0 == "." }))
        guard let detected = Double(numeric) else { return false }
        guard let minimum = Double(TmuxInstallGuideView.minimumVersion) else { return false }
        return detected >= minimum
    }
}
```

**Step 2: Run tests to verify they pass**

Run: `xcodebuild test -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,id=7CB9F63E-39E2-43DE-BB29-F21330EE099B' -only-testing:MuxiTests/TmuxErrorTests 2>&1 | grep -E '(Executed|PASS|FAIL)'`
Expected: All 14 tests PASS.

**Step 3: Commit**

```bash
git add ios/Muxi/Models/TmuxError.swift
git commit -m "feat: add TmuxError enum with version parsing and comparison"
```

---

### Task 3: Update MockSSHService to support per-command results

**Files:**
- Modify: `ios/MuxiTests/Services/SSHServiceTests.swift`

**Context:** The current `MockSSHService` returns the same `mockExecResult` for all `execCommand()` calls. With tmux detection, `connect()` calls `execCommand` twice: first `tmux -V`, then `tmux list-sessions`. The mock needs to return different results per command.

**Step 1: Add `mockExecResults` dictionary**

In `MockSSHService` (around line 99 of SSHServiceTests.swift), add a new property and update `execCommand`:

After `var mockExecResult: String = ""` (line 101), add:

```swift
/// Per-command overrides. If a command matches a key, that value is returned.
/// Falls back to `mockExecResult` if no match.
var mockExecResults: [String: String] = [:]

/// If set, `execCommand` throws this error instead of returning a result.
var mockExecError: Error?
```

Replace the `execCommand` method (line 111-114) with:

```swift
func execCommand(_ command: String) async throws -> String {
    guard state == .connected else { throw SSHError.notConnected }
    if let error = mockExecError { throw error }
    // Check for per-command override by prefix match.
    for (key, value) in mockExecResults {
        if command.hasPrefix(key) { return value }
    }
    return mockExecResult
}
```

**Step 2: Also update `ReconnectMockSSHService` in `ConnectionManagerReconnectTests.swift`**

Apply the same changes to `ReconnectMockSSHService` (around line 10):

After `var mockExecResult: String = ""` (line 20), add:

```swift
var mockExecResults: [String: String] = [:]
var mockExecError: Error?
```

Replace the `execCommand` method (line 34-37) with:

```swift
func execCommand(_ command: String) async throws -> String {
    guard state == .connected else { throw SSHError.notConnected }
    if let error = mockExecError { throw error }
    for (key, value) in mockExecResults {
        if command.hasPrefix(key) { return value }
    }
    return mockExecResult
}
```

**Step 3: Build to verify existing tests still pass**

Run: `xcodebuild test -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,id=7CB9F63E-39E2-43DE-BB29-F21330EE099B' 2>&1 | grep -E '(Executed|FAIL)'`
Expected: All existing tests pass. The new properties have default values, so no existing test is affected.

**Step 4: Commit**

```bash
git add ios/MuxiTests/Services/SSHServiceTests.swift ios/MuxiTests/Services/ConnectionManagerReconnectTests.swift
git commit -m "refactor: add per-command mock results to MockSSHService"
```

---

### Task 4: Add tmux version check to ConnectionManager.connect()

**Files:**
- Modify: `ios/Muxi/Services/ConnectionManager.swift`
- Modify: `ios/MuxiTests/Services/ConnectionManagerTests.swift`

**Step 1: Add `validateTmuxVersion()` and call it in `connect()`**

In `ConnectionManager.swift`, after `logger.info("SSH connected, querying tmux sessions...")` (line 134) and before the `tmux list-sessions` call (line 137), add:

```swift
// Check tmux availability before querying sessions.
try await checkTmuxAvailability()
```

Add a new private method after `resolveAuth()` (after line 448):

```swift
// MARK: - tmux Version Check

/// Verify that tmux is installed and meets the minimum version.
/// Throws ``TmuxError`` if tmux is missing or too old.
private func checkTmuxAvailability() async throws {
    let output: String
    do {
        output = try await sshService.execCommand("tmux -V")
    } catch {
        // execCommand failure (e.g. command not found exit code) → not installed.
        throw TmuxError.notInstalled
    }

    guard let version = TmuxError.parseTmuxVersion(output) else {
        throw TmuxError.notInstalled
    }

    if !TmuxError.versionMeetsMinimum(version) {
        throw TmuxError.versionTooOld(detected: version)
    }

    logger.info("tmux version \(version) detected")
}
```

**Step 2: Update existing ConnectionManager tests**

Existing tests call `connect()` and set `mockExecResult` to session list output. Now `connect()` calls `execCommand` twice (tmux -V then list-sessions), so update the mock setup.

In `ConnectionManagerTests.swift`, for **every** test that calls `connect()`, change the mock setup to use `mockExecResults`:

Replace patterns like:
```swift
ssh.mockExecResult = "$0:main:2:1740700800"
```

With:
```swift
ssh.mockExecResults["tmux -V"] = "tmux 3.4\n"
ssh.mockExecResults["tmux list-sessions"] = "$0:main:2:1740700800"
```

Do this for ALL tests that call `manager.connect(...)`. Search for `mockExecResult` in the file and update each occurrence.

**Step 3: Add new tests for tmux detection**

Append to `ConnectionManagerTests.swift`:

```swift
// MARK: - tmux Detection

func testConnectThrowsWhenTmuxNotInstalled() async {
    let ssh = MockSSHService()
    ssh.mockExecResults["tmux -V"] = "bash: tmux: command not found\n"
    let manager = ConnectionManager(sshService: ssh)

    do {
        _ = try await manager.connect(server: makeServer(), password: "p")
        XCTFail("Expected TmuxError.notInstalled")
    } catch let error as TmuxError {
        XCTAssertEqual(error, .notInstalled)
    } catch {
        XCTFail("Wrong error type: \(error)")
    }
    XCTAssertEqual(manager.state, .disconnected)
}

func testConnectThrowsWhenTmuxVersionTooOld() async {
    let ssh = MockSSHService()
    ssh.mockExecResults["tmux -V"] = "tmux 1.6\n"
    let manager = ConnectionManager(sshService: ssh)

    do {
        _ = try await manager.connect(server: makeServer(), password: "p")
        XCTFail("Expected TmuxError.versionTooOld")
    } catch let error as TmuxError {
        if case .versionTooOld(let detected) = error {
            XCTAssertEqual(detected, "1.6")
        } else {
            XCTFail("Wrong TmuxError case: \(error)")
        }
    } catch {
        XCTFail("Wrong error type: \(error)")
    }
    XCTAssertEqual(manager.state, .disconnected)
}

func testConnectSucceedsWithValidTmuxVersion() async throws {
    let ssh = MockSSHService()
    ssh.mockExecResults["tmux -V"] = "tmux 3.4\n"
    ssh.mockExecResults["tmux list-sessions"] = "$0:main:2:1740700800"
    let manager = ConnectionManager(sshService: ssh)

    let sessions = try await manager.connect(server: makeServer(), password: "p")
    XCTAssertEqual(manager.state, .sessionList)
    XCTAssertEqual(sessions.count, 1)
}

func testConnectThrowsWhenExecCommandFails() async {
    let ssh = MockSSHService()
    ssh.mockExecError = SSHError.channelError("exec failed")
    let manager = ConnectionManager(sshService: ssh)

    do {
        _ = try await manager.connect(server: makeServer(), password: "p")
        XCTFail("Expected error")
    } catch let error as TmuxError {
        XCTAssertEqual(error, .notInstalled)
    } catch {
        // Other SSH errors may also be thrown — acceptable
    }
}
```

**Step 4: Add Equatable conformance to TmuxError**

The tests use `XCTAssertEqual` on `TmuxError`, so it needs `Equatable`. Update `TmuxError.swift`:

```swift
enum TmuxError: Error, LocalizedError, Equatable {
```

**Step 5: Run all tests**

Run: `xcodebuild test -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,id=7CB9F63E-39E2-43DE-BB29-F21330EE099B' 2>&1 | grep -E '(Executed|FAIL)'`
Expected: All tests pass (existing + new).

**Step 6: Commit**

```bash
git add ios/Muxi/Services/ConnectionManager.swift ios/Muxi/Models/TmuxError.swift ios/MuxiTests/Services/ConnectionManagerTests.swift
git commit -m "feat: check tmux availability in connect() before listing sessions"
```

---

### Task 5: Show TmuxInstallGuideView in ContentView

**Files:**
- Modify: `ios/Muxi/App/ContentView.swift`

**Step 1: Add state properties for the tmux guide sheet**

After `@State private var sessionListViewModel: SessionListViewModel?` (line 21), add:

```swift
@State private var tmuxGuideReason: TmuxInstallGuideView.Reason?
```

**Step 2: Update `connectToServer` to catch TmuxError**

Replace the catch block in `connectToServer()` (lines 251-255):

```swift
} catch let error as TmuxError {
    switch error {
    case .notInstalled:
        tmuxGuideReason = .notInstalled
    case .versionTooOld(let detected):
        tmuxGuideReason = .versionTooOld(detected: detected)
    }
} catch {
    withAnimation {
        errorMessage = "Connection failed: \(error.localizedDescription)"
        showErrorBanner = true
    }
}
```

**Step 3: Add the sheet modifier**

After `.animation(.easeInOut(duration: 0.25), value: showErrorBanner)` (line 94), add the sheet:

```swift
.sheet(item: $tmuxGuideReason) { reason in
    TmuxInstallGuideView(
        reason: reason,
        serverName: selectedServer?.name ?? selectedServer?.host ?? "server",
        onDismiss: {
            tmuxGuideReason = nil
        }
    )
}
```

**Step 4: Make `TmuxInstallGuideView.Reason` conform to `Identifiable`**

For `.sheet(item:)` to work, `Reason` needs `Identifiable`. Add this in `ReconnectingOverlay.swift`, after the `Reason` enum definition (after line 107):

```swift
extension TmuxInstallGuideView.Reason: Identifiable {
    var id: String {
        switch self {
        case .notInstalled: return "notInstalled"
        case .versionTooOld(let v): return "versionTooOld-\(v)"
        }
    }
}
```

**Step 5: Build to verify**

Run: `xcodebuild build -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,id=7CB9F63E-39E2-43DE-BB29-F21330EE099B' 2>&1 | grep -E '(BUILD|error:)'`
Expected: BUILD SUCCEEDED.

**Step 6: Run all tests to verify no regressions**

Run: `xcodebuild test -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,id=7CB9F63E-39E2-43DE-BB29-F21330EE099B' 2>&1 | grep -E '(Executed|FAIL)'`
Expected: All tests pass.

**Step 7: Commit**

```bash
git add ios/Muxi/App/ContentView.swift ios/Muxi/Views/Common/ReconnectingOverlay.swift
git commit -m "feat: show TmuxInstallGuideView sheet when tmux is unavailable"
```
