# Clipboard Paste Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Long-press on the terminal view shows a native iOS edit menu with "Paste" that sends clipboard text to the active tmux pane.

**Architecture:** New `String.tmuxQuoted()` escaping function converts clipboard text into a tmux double-quoted string. `UIEditMenuInteraction` on the MTKView presents the paste menu. Paste sends `set-buffer` + `paste-buffer` tmux commands through the existing SSH write path.

**Tech Stack:** UIKit (UIEditMenuInteraction, UILongPressGestureRecognizer), UIPasteboard, tmux control mode

---

### Task 1: `tmuxQuoted()` — Failing Tests

**Files:**
- Create: `ios/MuxiTests/Extensions/TmuxEscapeTests.swift`

**Step 1: Write the failing tests**

```swift
import XCTest
@testable import Muxi

final class TmuxEscapeTests: XCTestCase {

    // MARK: - Basic Escaping

    func testPlainASCII() {
        XCTAssertEqual("hello".tmuxQuoted(), "\"hello\"")
    }

    func testBackslash() {
        XCTAssertEqual("a\\b".tmuxQuoted(), "\"a\\\\b\"")
    }

    func testDoubleQuote() {
        XCTAssertEqual("say \"hi\"".tmuxQuoted(), "\"say \\\"hi\\\"\"")
    }

    func testDollarSign() {
        XCTAssertEqual("$HOME".tmuxQuoted(), "\"\\$HOME\"")
    }

    func testNewline() {
        XCTAssertEqual("line1\nline2".tmuxQuoted(), "\"line1\\nline2\"")
    }

    func testCarriageReturn() {
        XCTAssertEqual("a\rb".tmuxQuoted(), "\"a\\rb\"")
    }

    func testTab() {
        XCTAssertEqual("a\tb".tmuxQuoted(), "\"a\\tb\"")
    }

    func testEscape() {
        XCTAssertEqual("a\u{1B}b".tmuxQuoted(), "\"a\\eb\"")
    }

    // MARK: - Control Characters

    func testNullByte() {
        XCTAssertEqual("a\u{00}b".tmuxQuoted(), "\"a\\u0000b\"")
    }

    func testBellCharacter() {
        XCTAssertEqual("a\u{07}b".tmuxQuoted(), "\"a\\u0007b\"")
    }

    func testDEL() {
        XCTAssertEqual("a\u{7F}b".tmuxQuoted(), "\"a\\u007Fb\"")
    }

    // MARK: - Passthrough

    func testUTF8Passthrough() {
        XCTAssertEqual("한글テスト".tmuxQuoted(), "\"한글テスト\"")
    }

    func testHashNotEscaped() {
        XCTAssertEqual("#{window}".tmuxQuoted(), "\"#{window}\"")
    }

    func testEmoji() {
        XCTAssertEqual("hello 🌍".tmuxQuoted(), "\"hello 🌍\"")
    }

    // MARK: - Combined

    func testMixedSpecialChars() {
        let input = "echo \"$PATH\"\nls -la"
        let expected = "\"echo \\\"\\$PATH\\\"\\nls -la\""
        XCTAssertEqual(input.tmuxQuoted(), expected)
    }

    func testEmptyString() {
        XCTAssertEqual("".tmuxQuoted(), "\"\"")
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,id=7CB9F63E-39E2-43DE-BB29-F21330EE099B' -only-testing:MuxiTests/TmuxEscapeTests 2>&1 | grep -E '(TEST|FAIL|error:)'`
Expected: FAIL — `tmuxQuoted()` does not exist yet.

**Step 3: Commit**

```bash
git add ios/MuxiTests/Extensions/TmuxEscapeTests.swift
git commit -m "test: add failing tests for tmuxQuoted() escaping"
```

---

### Task 2: `tmuxQuoted()` — Implementation

**Files:**
- Create: `ios/Muxi/Extensions/String+TmuxEscape.swift`

**Step 1: Write the implementation**

```swift
import Foundation

extension String {
    /// Wraps the string in double quotes with escaping for tmux's command
    /// parser.  This is NOT the same as shell escaping — tmux control mode
    /// commands go directly to tmux's parser, not through a shell.
    ///
    /// Escapes: `\` `"` `$` newline CR tab ESC, plus any other C0/DEL
    /// control characters via `\uXXXX`.  UTF-8 text passes through
    /// unchanged (tmux handles UTF-8 natively).
    func tmuxQuoted() -> String {
        var result = "\""
        for scalar in unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "$":  result += "\\$"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{1B}": result += "\\e"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    result += String(format: "\\u%04X", scalar.value)
                } else {
                    result += String(scalar)
                }
            }
        }
        result += "\""
        return result
    }
}
```

**Step 2: Run tests to verify they pass**

Run: `xcodebuild test -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,id=7CB9F63E-39E2-43DE-BB29-F21330EE099B' -only-testing:MuxiTests/TmuxEscapeTests 2>&1 | grep -E '(TEST|PASS|FAIL)'`
Expected: All 14 tests PASS.

**Step 3: Commit**

```bash
git add ios/Muxi/Extensions/String+TmuxEscape.swift
git commit -m "feat: add String.tmuxQuoted() for tmux command escaping"
```

---

### Task 3: Add `onPaste` callback to TerminalView

**Files:**
- Modify: `ios/Muxi/Views/Terminal/TerminalView.swift`

**Step 1: Add `onPaste` property and UIEditMenuInteraction to TerminalView**

Add `onPaste` closure property to `TerminalView` struct (after `channel`):

```swift
var onPaste: ((String) -> Void)?
```

Pass it to the Coordinator in `makeCoordinator()`:

```swift
func makeCoordinator() -> Coordinator {
    Coordinator(buffer: buffer, channel: channel, theme: theme, onPaste: onPaste)
}
```

In `makeUIView(context:)`, after `mtkView.setNeedsDisplay()` and before `return mtkView`, add the edit menu interaction:

```swift
let editMenuInteraction = UIEditMenuInteraction(delegate: context.coordinator)
mtkView.addInteraction(editMenuInteraction)
context.coordinator.editMenuInteraction = editMenuInteraction

let longPress = UILongPressGestureRecognizer(
    target: context.coordinator,
    action: #selector(Coordinator.handleLongPress(_:))
)
mtkView.addGestureRecognizer(longPress)
```

Update the Coordinator class:

```swift
class Coordinator: NSObject, UIEditMenuInteractionDelegate {
    let buffer: TerminalBuffer
    var channel: SSHChannel?
    var renderer: TerminalRenderer?
    weak var mtkView: MTKView?
    var currentTheme: Theme
    var onPaste: ((String) -> Void)?
    var editMenuInteraction: UIEditMenuInteraction?

    init(buffer: TerminalBuffer, channel: SSHChannel?, theme: Theme, onPaste: ((String) -> Void)?) {
        self.buffer = buffer
        self.channel = channel
        self.currentTheme = theme
        self.onPaste = onPaste
    }

    func sendInput(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        try? channel?.write(data)
    }

    func requestRedraw() {
        renderer?.needsRedraw = true
        mtkView?.setNeedsDisplay()
    }

    // MARK: - Paste

    @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began,
              let interaction = editMenuInteraction,
              let view = gesture.view else { return }
        let location = gesture.location(in: view)
        let config = UIEditMenuConfiguration(identifier: nil, sourcePoint: location)
        interaction.presentEditMenu(with: config)
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        guard UIPasteboard.general.hasStrings else { return nil }
        let paste = UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
            guard let text = UIPasteboard.general.string else { return }
            self?.onPaste?(text)
        }
        return UIMenu(children: [paste])
    }
}
```

Also update `updateUIView` to sync `onPaste`:

```swift
context.coordinator.onPaste = onPaste
```

Add this line inside `updateUIView(_:context:)` right after `context.coordinator.channel = channel`.

**Step 2: Build to verify compilation**

Run: `xcodebuild build -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,id=7CB9F63E-39E2-43DE-BB29-F21330EE099B' 2>&1 | grep -E '(BUILD|error:)'`
Expected: BUILD SUCCEEDED.

**Step 3: Commit**

```bash
git add ios/Muxi/Views/Terminal/TerminalView.swift
git commit -m "feat: add UIEditMenuInteraction for paste to TerminalView"
```

---

### Task 4: Wire `onPaste` through PaneContainerView

**Files:**
- Modify: `ios/Muxi/Views/Terminal/PaneContainerView.swift`

**Step 1: Add `onPaste` property to PaneContainerView**

After the `onPaneTapped` property (line 64), add:

```swift
var onPaste: ((String) -> Void)?
```

In `compactLayout`, update the TerminalView init (line 117):

```swift
TerminalView(buffer: pane.buffer, theme: theme, channel: pane.channel, onPaste: onPaste)
```

In `regularLayout`, update the TerminalView init (line 179):

```swift
TerminalView(buffer: pane.buffer, theme: theme, channel: pane.channel, onPaste: onPaste)
```

**Step 2: Build to verify compilation**

Run: `xcodebuild build -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,id=7CB9F63E-39E2-43DE-BB29-F21330EE099B' 2>&1 | grep -E '(BUILD|error:)'`
Expected: BUILD SUCCEEDED.

**Step 3: Commit**

```bash
git add ios/Muxi/Views/Terminal/PaneContainerView.swift
git commit -m "feat: pass onPaste callback through PaneContainerView"
```

---

### Task 5: Add `pasteToActivePane()` in TerminalSessionView

**Files:**
- Modify: `ios/Muxi/Views/Terminal/TerminalSessionView.swift`

**Step 1: Add the paste handler and wire it**

In the `PaneContainerView(...)` initializer call (around line 45-52), add the `onPaste` parameter:

```swift
PaneContainerView(
    panes: panes,
    theme: themeManager.currentTheme,
    activePaneId: $activePaneId,
    onPaneTapped: { _ in
        isKeyboardActive = true
    },
    onPaste: { text in
        pasteToActivePane(text)
    }
)
```

Add the `pasteToActivePane` method after `sendTmuxCommand` (after line 183):

```swift
/// Paste clipboard text to the active pane via tmux set-buffer + paste-buffer.
/// Uses a named buffer ("ios_paste") to avoid clobbering the user's global
/// paste buffer. tmux automatically wraps with bracketed paste sequences
/// if the pane's application has enabled bracketed paste mode.
private func pasteToActivePane(_ text: String) {
    guard let paneId = activePaneId else { return }
    let escaped = text.tmuxQuoted()
    let command = "set-buffer -b ios_paste -- \(escaped)\npaste-buffer -b ios_paste -t \(paneId.shellEscaped()) -d\n"
    Task {
        do {
            try await connectionManager.sshServiceForWrites.writeToChannel(Data(command.utf8))
        } catch {
            logger.error("Failed to paste to pane \(paneId): \(error.localizedDescription)")
        }
    }
}
```

**Step 2: Build to verify compilation**

Run: `xcodebuild build -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,id=7CB9F63E-39E2-43DE-BB29-F21330EE099B' 2>&1 | grep -E '(BUILD|error:)'`
Expected: BUILD SUCCEEDED.

**Step 3: Run all tests to verify no regressions**

Run: `xcodebuild test -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,id=7CB9F63E-39E2-43DE-BB29-F21330EE099B' 2>&1 | grep -E '(Test Suite|Executed|FAIL)'`
Expected: All tests pass, including TmuxEscapeTests.

**Step 4: Commit**

```bash
git add ios/Muxi/Views/Terminal/TerminalSessionView.swift
git commit -m "feat: add clipboard paste via tmux set-buffer + paste-buffer"
```
