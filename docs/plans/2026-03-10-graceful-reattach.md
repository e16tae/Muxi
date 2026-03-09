# Graceful Re-attach Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** When a tmux session exits (`%exit`), re-attach to another session using the existing SSH connection instead of doing a full reconnect.

**Architecture:** Add a `reattach()` method to `ConnectionManager` that cleans up control-mode state (channel, buffers, pending commands) without touching SSH, queries remaining sessions via `refreshSessions()`, and either attaches to the best available session or disconnects. The `onExit` handler switches from `reconnect()` to `reattach()`.

**Tech Stack:** Swift, XCTest

---

### Task 1: Write failing tests for `reattach()`

**Files:**
- Modify: `ios/MuxiTests/Services/ConnectionManagerTests.swift`

**Step 1: Write the failing tests**

Add a new `// MARK: - Reattach` section at the end of `ConnectionManagerTests`:

```swift
// MARK: - Reattach

func testReattachSwitchesToNextSession() async throws {
    let ssh = MockSSHService()
    ssh.mockExecResults["tmux -V"] = "tmux 3.4\n"
    ssh.mockExecResults["tmux list-sessions"] = "$0:alpha:1:0\n$1:beta:1:0"
    let manager = ConnectionManager(sshService: ssh)
    try await manager.connect(server: makeServer(), password: "p")
    XCTAssertEqual(manager.state, .attached(sessionName: "alpha"))

    // Simulate: alpha was destroyed, only beta remains
    ssh.mockExecResults["tmux list-sessions"] = "$1:beta:1:0"

    await manager.reattach()

    XCTAssertEqual(manager.state, .attached(sessionName: "beta"))
    XCTAssertNotNil(manager.activeChannel)
}

func testReattachDisconnectsWhenNoSessionsRemain() async throws {
    let ssh = MockSSHService()
    ssh.mockExecResults["tmux -V"] = "tmux 3.4\n"
    ssh.mockExecResults["tmux list-sessions"] = "$0:only:1:0"
    let manager = ConnectionManager(sshService: ssh)
    try await manager.connect(server: makeServer(), password: "p")
    XCTAssertEqual(manager.state, .attached(sessionName: "only"))

    // Simulate: no sessions left
    ssh.mockExecResults["tmux list-sessions"] = ""

    await manager.reattach()

    XCTAssertEqual(manager.state, .disconnected)
    XCTAssertNil(manager.activeChannel)
}

func testReattachFallsBackToReconnectOnSSHFailure() async throws {
    let ssh = MockSSHService()
    ssh.mockExecResults["tmux -V"] = "tmux 3.4\n"
    ssh.mockExecResults["tmux list-sessions"] = "$0:work:1:0"
    let manager = ConnectionManager(sshService: ssh, maxReconnectAttempts: 1)
    try await manager.connect(server: makeServer(), password: "p")
    XCTAssertEqual(manager.state, .attached(sessionName: "work"))

    // Simulate: SSH died — execCommand will throw
    ssh.simulateDisconnect()

    await manager.reattach()

    // reconnect() also fails (SSH is down, 1 attempt max) → disconnected
    XCTAssertEqual(manager.state, .disconnected)
}

func testReattachDoesNothingWhenNotAttached() async {
    let manager = ConnectionManager(sshService: MockSSHService())
    XCTAssertEqual(manager.state, .disconnected)

    await manager.reattach()

    XCTAssertEqual(manager.state, .disconnected)
}
```

**Step 2: Run tests to verify they fail**

Run: `cd /Users/lmuffin/Documents/Workspace/Muxi/ios && xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.2' -only-testing:MuxiTests/ConnectionManagerTests 2>&1 | tail -30`

Expected: Compile error — `reattach()` method does not exist.

**Step 3: Commit**

```
git add ios/MuxiTests/Services/ConnectionManagerTests.swift
git commit -m "test: add failing tests for reattach() method"
```

---

### Task 2: Implement `reattach()` method

**Files:**
- Modify: `ios/Muxi/Services/ConnectionManager.swift:660-744` (add `reattach()` before `reconnect()`)

**Step 1: Add the `reattach()` method**

Insert the following method just before `reconnect()` (before line 660), inside the `// MARK: - Reconnect` section:

```swift
/// Attempt to re-attach to another tmux session using the existing SSH
/// connection. Called when the current session exits (`%exit`) but the
/// SSH link is still alive.
///
/// Cleans up control-mode state (channel, buffers, pending commands)
/// without tearing down SSH, queries remaining sessions, and attaches
/// to the best available one. If no sessions remain, disconnects.
/// If SSH has died, falls back to ``reconnect()``.
func reattach() async {
    guard case .attached = state else { return }

    logger.info("Reattach: current session exited, looking for alternatives")

    // Cancel any pending scrollback fetch.
    if let continuation = scrollbackContinuation {
        scrollbackContinuation = nil
        continuation.resume(throwing: ScrollbackError.notAttached)
    }

    // Clean up control-mode state but keep SSH alive.
    sshMonitorTask?.cancel()
    sshMonitorTask = nil
    activeChannel = nil
    tmuxService.resetLineBuffer()
    paneBuffers = [:]
    currentPanes = []
    pendingCommands = []
    activePaneId = nil
    scrolledBackPanes = []
    paneHasNewOutput = []
    lastSentSize = (0, 0)
    pendingInitialResize = false

    do {
        try await refreshSessions()

        let serverID = currentServer?.id.uuidString
        let targetSession: String?

        if let sid = serverID,
           let lastUsed = lastSessionStore.lastSessionName(forServerID: sid),
           sessions.contains(where: { $0.name == lastUsed }) {
            targetSession = lastUsed
        } else {
            targetSession = sessions.first?.name
        }

        if let target = targetSession {
            try await performAttach(sessionName: target)
            if let sid = serverID {
                lastSessionStore.save(sessionName: target, forServerID: sid)
            }
            logger.info("Reattach: attached to '\(target)'")
        } else {
            logger.info("Reattach: no sessions remaining, disconnecting")
            disconnect()
        }
    } catch {
        logger.error("Reattach failed (\(error)), falling back to reconnect")
        await reconnect()
    }
}
```

**Step 2: Update `onExit` handler to call `reattach()`**

In `wireCallbacks()` (~line 969), change:

```swift
tmuxService.onExit = { [weak self] in
    guard let self else { return }
    // Only reconnect if we were attached (not manually detaching).
    guard case .attached = self.state else { return }
    Task { await self.reconnect() }
}
```

to:

```swift
tmuxService.onExit = { [weak self] in
    guard let self else { return }
    // Only reattach if we were attached (not manually detaching).
    guard case .attached = self.state else { return }
    Task { await self.reattach() }
}
```

**Step 3: Run tests to verify they pass**

Run: `cd /Users/lmuffin/Documents/Workspace/Muxi/ios && xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.2' -only-testing:MuxiTests/ConnectionManagerTests 2>&1 | tail -30`

Expected: All tests PASS including the 4 new reattach tests.

**Step 4: Run full test suite**

Run: `cd /Users/lmuffin/Documents/Workspace/Muxi/ios && xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.2' 2>&1 | tail -30`

Expected: All existing tests still pass (no regressions).

**Step 5: Commit**

```
git add ios/Muxi/Services/ConnectionManager.swift
git commit -m "feat: add reattach() for graceful session switch on tmux exit

When a tmux session exits (%exit), reuse the existing SSH connection to
query remaining sessions and attach to the next one. Falls back to full
reconnect() if SSH has died. Disconnects if no sessions remain."
```
