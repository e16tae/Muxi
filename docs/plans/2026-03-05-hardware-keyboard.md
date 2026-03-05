# Hardware Keyboard Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add hardware keyboard support for arrows, escape, tab, Ctrl+letter, and Alt+letter via UIKeyCommand on the existing TerminalInputAccessor.

**Architecture:** `TerminalInputAccessor` gains a cached `keyCommands` override (~58 entries) that routes to a single `handleKeyCommand` selector. Special keys reuse the existing `SpecialKey` enum + callback. Ctrl/Alt combos use a new static `InputHandler.terminalData(for:ctrl:alt:)` pure function and a new `onRawData` callback to bypass the toggle-based modifier state.

**Tech Stack:** SwiftUI, UIKit (UIKeyCommand), XCTest

**Design doc:** `docs/plans/2026-03-05-hardware-keyboard-design.md`

---

### Task 1: InputHandler.terminalData Static Method + Tests

**Files:**
- Modify: `ios/Muxi/Terminal/InputHandler.swift`
- Modify: `ios/MuxiTests/Terminal/InputHandlerTests.swift`

**Step 1: Write the tests**

Add to `ios/MuxiTests/Terminal/InputHandlerTests.swift`:

```swift
    // MARK: - Hardware Keyboard (terminalData)

    func testTerminalDataCtrlA() {
        let data = InputHandler.terminalData(for: "a", ctrl: true)
        XCTAssertEqual(data, Data([0x01]))
    }

    func testTerminalDataCtrlC() {
        let data = InputHandler.terminalData(for: "c", ctrl: true)
        XCTAssertEqual(data, Data([0x03]))
    }

    func testTerminalDataCtrlZ() {
        let data = InputHandler.terminalData(for: "z", ctrl: true)
        XCTAssertEqual(data, Data([0x1A]))
    }

    func testTerminalDataCtrlUppercaseLetter() {
        // Ctrl+C with uppercase input should produce same control code.
        let data = InputHandler.terminalData(for: "C", ctrl: true)
        XCTAssertEqual(data, Data([0x03]))
    }

    func testTerminalDataAltA() {
        let data = InputHandler.terminalData(for: "a", alt: true)
        XCTAssertEqual(data, Data([0x1B, 0x61]))
    }

    func testTerminalDataAltZ() {
        let data = InputHandler.terminalData(for: "z", alt: true)
        XCTAssertEqual(data, Data([0x1B, 0x7A]))
    }

    func testTerminalDataPlainCharacter() {
        let data = InputHandler.terminalData(for: "x")
        XCTAssertEqual(data, "x".data(using: .utf8))
    }

    func testTerminalDataDoesNotAffectToggleState() {
        // Static method should not touch instance toggle state.
        XCTAssertFalse(handler.ctrlActive)
        XCTAssertFalse(handler.altActive)
        _ = InputHandler.terminalData(for: "a", ctrl: true)
        XCTAssertFalse(handler.ctrlActive)
        XCTAssertFalse(handler.altActive)
    }
```

**Step 2: Run tests to verify they fail**

Run: `cd ios && xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' -only-testing:MuxiTests/InputHandlerTests 2>&1 | tail -20`
Expected: FAIL — `terminalData(for:ctrl:alt:)` not defined

**Step 3: Implement terminalData**

In `ios/Muxi/Terminal/InputHandler.swift`, add after the `toggleAlt()` method (after line 120):

```swift
    // MARK: - Hardware Keyboard Support

    /// Translate a character with explicit modifier flags into terminal bytes.
    ///
    /// This is a **static pure function** — it does not read or modify the
    /// instance-level `ctrlActive`/`altActive` toggle state.  Use this for
    /// hardware keyboard events where modifier flags come from `UIKeyCommand`.
    ///
    /// - Parameters:
    ///   - character: The key's `charactersIgnoringModifiers` value.
    ///   - ctrl: Whether the Control modifier is held.
    ///   - alt: Whether the Option/Alt modifier is held.
    /// - Returns: Terminal byte sequence as `Data`.
    static func terminalData(
        for character: String,
        ctrl: Bool = false,
        alt: Bool = false
    ) -> Data {
        guard let first = character.first else { return Data() }

        if ctrl {
            if let upper = first.uppercased().first,
               let ascii = upper.asciiValue, ascii >= 0x40, ascii <= 0x5F {
                return Data([ascii - 0x40])
            }
        }

        let charData = character.data(using: .utf8) ?? Data()

        if alt {
            return Data([0x1B]) + charData
        }

        return charData
    }
```

**Step 4: Run tests to verify they pass**

Run: `cd ios && xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' -only-testing:MuxiTests/InputHandlerTests 2>&1 | tail -20`
Expected: PASS

**Step 5: Commit**

```bash
git add ios/Muxi/Terminal/InputHandler.swift ios/MuxiTests/Terminal/InputHandlerTests.swift
git commit -m "feat: add InputHandler.terminalData static method for hardware keyboard

Pure function that translates character + modifier flags to terminal
bytes without touching toggle state. Used by UIKeyCommand handlers.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 2: UIKeyCommand on TerminalInputAccessor + onRawData Callback

**Files:**
- Modify: `ios/Muxi/Views/Terminal/TerminalInputView.swift`
- Modify: `ios/Muxi/Views/Terminal/TerminalSessionView.swift`

**Step 1: Add onSpecialKey and onRawData callbacks to TerminalInputAccessor**

In `ios/Muxi/Views/Terminal/TerminalInputView.swift`, add after the `onDelete` property (after line 16):

```swift
    /// Called for special keys (arrows, escape, tab) from hardware keyboard.
    var onSpecialKey: ((SpecialKey) -> Void)?

    /// Called for raw terminal bytes (Ctrl/Alt combos) from hardware keyboard.
    var onRawData: ((Data) -> Void)?
```

**Step 2: Add cached keyCommands and handleKeyCommand**

In `TerminalInputAccessor`, add after the `deactivate()` method (after line 57):

```swift
    // MARK: - Hardware Keyboard

    /// Cached key commands for hardware keyboard support.
    /// Arrows, Escape, Tab, Ctrl+a...z, Alt+a...z (~58 entries).
    private static let _keyCommands: [UIKeyCommand] = {
        var commands: [UIKeyCommand] = []
        let sel = #selector(handleKeyCommand(_:))

        // Arrow keys.
        commands.append(UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: sel))
        commands.append(UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: sel))
        commands.append(UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: sel))
        commands.append(UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: sel))

        // Escape.
        commands.append(UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: sel))

        // Tab — override iOS focus navigation.
        let tab = UIKeyCommand(input: "\t", modifierFlags: [], action: sel)
        tab.wantsPriorityOverSystemBehavior = true
        commands.append(tab)

        // Ctrl+letter (a-z).
        for scalar in UnicodeScalar("a").value...UnicodeScalar("z").value {
            let char = String(UnicodeScalar(scalar)!)
            commands.append(UIKeyCommand(input: char, modifierFlags: .control, action: sel))
        }

        // Alt+letter (a-z).
        for scalar in UnicodeScalar("a").value...UnicodeScalar("z").value {
            let char = String(UnicodeScalar(scalar)!)
            commands.append(UIKeyCommand(input: char, modifierFlags: .alternate, action: sel))
        }

        return commands
    }()

    override var keyCommands: [UIKeyCommand]? {
        Self._keyCommands
    }

    @objc private func handleKeyCommand(_ command: UIKeyCommand) {
        guard let input = command.input else { return }

        // Special keys (no modifier).
        if command.modifierFlags.isEmpty || command.modifierFlags == .numericPad {
            let specialKey: SpecialKey?
            switch input {
            case UIKeyCommand.inputUpArrow:    specialKey = .arrowUp
            case UIKeyCommand.inputDownArrow:  specialKey = .arrowDown
            case UIKeyCommand.inputLeftArrow:  specialKey = .arrowLeft
            case UIKeyCommand.inputRightArrow: specialKey = .arrowRight
            case UIKeyCommand.inputEscape:     specialKey = .escape
            case "\t":                         specialKey = .tab
            default:                           specialKey = nil
            }
            if let key = specialKey {
                onSpecialKey?(key)
                return
            }
        }

        // Ctrl+letter.
        if command.modifierFlags.contains(.control) {
            let data = InputHandler.terminalData(for: input, ctrl: true)
            onRawData?(data)
            return
        }

        // Alt+letter.
        if command.modifierFlags.contains(.alternate) {
            let data = InputHandler.terminalData(for: input, alt: true)
            onRawData?(data)
            return
        }
    }
```

**Step 3: Wire callbacks in TerminalInputView**

In `TerminalInputView`, add new properties (after `onDelete` at line 69):

```swift
    var onSpecialKey: ((SpecialKey) -> Void)?
    var onRawData: ((Data) -> Void)?
```

In `makeUIView`, after `view.onDelete = onDelete` (line 80), add:

```swift
        view.onSpecialKey = onSpecialKey
        view.onRawData = onRawData
```

In `updateUIView`, after `uiView.onDelete = onDelete` (line 95), add:

```swift
        uiView.onSpecialKey = onSpecialKey
        uiView.onRawData = onRawData
```

**Step 4: Wire callbacks in TerminalSessionView**

In `ios/Muxi/Views/Terminal/TerminalSessionView.swift`, in the `TerminalInputView(...)` call (around line 85-96), add the two new callbacks after `onDelete`:

```swift
                TerminalInputView(
                    onText: { text in
                        for char in text {
                            let data = inputHandler.data(for: char)
                            sendToActivePane(data)
                        }
                    },
                    onDelete: {
                        sendToActivePane(Data([0x7F]))
                    },
                    onSpecialKey: { key in
                        let data = inputHandler.data(for: key)
                        sendToActivePane(data)
                    },
                    onRawData: { data in
                        sendToActivePane(data)
                    },
                    isActive: $isKeyboardActive
                )
```

**Step 5: Run all tests**

Run: `cd ios && xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' 2>&1 | tail -30`
Expected: PASS

**Step 6: Commit**

```bash
git add ios/Muxi/Views/Terminal/TerminalInputView.swift ios/Muxi/Views/Terminal/TerminalSessionView.swift
git commit -m "feat: add hardware keyboard support via UIKeyCommand

Arrows, Escape, Tab, Ctrl+a-z, Alt+a-z handled via cached
UIKeyCommand entries on TerminalInputAccessor. Key repeat
works automatically. Software keyboard unchanged.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Notes for Implementer

### Key files to read first
- `docs/plans/2026-03-05-hardware-keyboard-design.md` — design rationale
- `ios/Muxi/Views/Terminal/TerminalInputView.swift` — TerminalInputAccessor (UIKeyInput view)
- `ios/Muxi/Terminal/InputHandler.swift` — existing key translation logic
- `ios/Muxi/Views/Terminal/TerminalSessionView.swift:85-96` — where callbacks are wired

### Input flow
```
Hardware key press
  → UIKeyCommand matched on TerminalInputAccessor
  → handleKeyCommand(_:)
  ├── Special key → onSpecialKey → InputHandler.data(for: SpecialKey) → sendToActivePane
  └── Ctrl/Alt+letter → InputHandler.terminalData(for:ctrl:alt:) → onRawData → sendToActivePane
```

### Why static method?
`InputHandler.terminalData(for:ctrl:alt:)` is static because:
1. Hardware modifier flags are per-event (held down), not toggled
2. Must not interfere with `ctrlActive`/`altActive` state used by ExtendedKeyboardView
3. Pure function = easy to test, no side effects

### Arrow keys and numericPad flag
UIKit sometimes sets `.numericPad` modifier flag on arrow key commands. The handler checks `modifierFlags.isEmpty || modifierFlags == .numericPad` to catch both cases.

### Testing strategy
- Task 1: Unit tests for `terminalData` static method (pure logic, no UI)
- Task 2: Visual verification on simulator with hardware keyboard (Settings → General → Keyboard → Hardware Keyboard)
- Full test suite run after each task to catch regressions
