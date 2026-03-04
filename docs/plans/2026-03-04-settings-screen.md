# Settings Screen Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a Settings hub screen with font size control, replacing the direct gear → ThemeSettingsView link.

**Architecture:** Create `SettingsView` as a List-based settings hub. Extend `ThemeManager` with `fontSize` (UserDefaults-backed). Pass font size through TerminalView to the Metal renderer via the existing `updateFont()` method.

**Tech Stack:** SwiftUI, Metal (existing TerminalRenderer), UserDefaults, Swift Testing

**Design doc:** `docs/plans/2026-03-04-settings-screen-design.md`

---

### Task 1: ThemeManager fontSize Property + Tests

**Files:**
- Modify: `ios/Muxi/Services/ThemeManager.swift`
- Modify: `ios/MuxiTests/Services/ThemeManagerTests.swift`

**Step 1: Write the tests**

Add to `ios/MuxiTests/Services/ThemeManagerTests.swift`:

```swift
    @Test("Default font size is 14")
    @MainActor func defaultFontSize() {
        let manager = ThemeManager()
        #expect(manager.fontSize == 14)
    }

    @Test("Set font size updates value")
    @MainActor func setFontSize() {
        let manager = ThemeManager()
        manager.setFontSize(18)
        #expect(manager.fontSize == 18)
    }

    @Test("Font size clamps to valid range")
    @MainActor func fontSizeClamps() {
        let manager = ThemeManager()
        manager.setFontSize(6)
        #expect(manager.fontSize == 10)
        manager.setFontSize(30)
        #expect(manager.fontSize == 24)
    }

    @Test("Font size persists to UserDefaults")
    @MainActor func fontSizePersists() {
        defer {
            UserDefaults.standard.removeObject(forKey: "terminalFontSize")
        }
        let manager = ThemeManager()
        manager.setFontSize(20)
        let saved = UserDefaults.standard.double(forKey: "terminalFontSize")
        #expect(saved == 20)
    }
```

**Step 2: Run tests to verify they fail**

Run: `cd ios && xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.2' -only-testing:MuxiTests/ThemeManagerTests 2>&1 | tail -20`
Expected: FAIL — fontSize not defined

**Step 3: Add fontSize to ThemeManager**

In `ios/Muxi/Services/ThemeManager.swift`, add after line 20 (`private let selectedThemeKey`):

```swift
    private let fontSizeKey = "terminalFontSize"
    private static let defaultFontSize: CGFloat = 14
    private static let minFontSize: CGFloat = 10
    private static let maxFontSize: CGFloat = 24
    private static let fontSizeStep: CGFloat = 2

    /// Terminal font size in points. Persisted via UserDefaults.
    private(set) var fontSize: CGFloat = defaultFontSize
```

In `init()`, after the theme restoration block (after line 32), add:

```swift
        // Restore saved font size.
        let savedSize = UserDefaults.standard.double(forKey: fontSizeKey)
        if savedSize > 0 {
            fontSize = max(Self.minFontSize, min(savedSize, Self.maxFontSize))
        }
```

Add after `selectTheme(_:)`:

```swift
    /// Set the terminal font size and persist the choice.
    /// Clamps to the valid range (10–24pt).
    func setFontSize(_ size: CGFloat) {
        let clamped = max(Self.minFontSize, min(size, Self.maxFontSize))
        fontSize = clamped
        UserDefaults.standard.set(clamped, forKey: fontSizeKey)
        logger.info("Font size changed to: \(clamped)")
    }
```

**Step 4: Run tests to verify they pass**

Run: `cd ios && xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.2' -only-testing:MuxiTests/ThemeManagerTests 2>&1 | tail -20`
Expected: PASS — all tests pass (existing + new)

**Step 5: Commit**

```bash
git add ios/Muxi/Services/ThemeManager.swift ios/MuxiTests/Services/ThemeManagerTests.swift
git commit -m "feat: add fontSize property to ThemeManager with UserDefaults persistence"
```

---

### Task 2: SettingsView Hub

**Files:**
- Create: `ios/Muxi/Views/Settings/SettingsView.swift`
- Modify: `ios/Muxi/App/ContentView.swift`

**Step 1: Create SettingsView**

Create `ios/Muxi/Views/Settings/SettingsView.swift`:

```swift
import SwiftUI

/// Root settings screen with sections for appearance and app info.
struct SettingsView: View {
    let themeManager: ThemeManager

    var body: some View {
        List {
            appearanceSection
            aboutSection
        }
        .navigationTitle("Settings")
    }

    // MARK: - Appearance

    @ViewBuilder
    private var appearanceSection: some View {
        Section("Appearance") {
            NavigationLink {
                ThemeSettingsView(themeManager: themeManager)
            } label: {
                HStack {
                    Label("Theme", systemImage: "paintpalette")
                        .foregroundStyle(MuxiTokens.Colors.textPrimary)
                    Spacer()
                    Text(themeManager.currentTheme.name)
                        .foregroundStyle(MuxiTokens.Colors.textSecondary)
                }
            }

            HStack {
                Label("Font Size", systemImage: "textformat.size")
                    .foregroundStyle(MuxiTokens.Colors.textPrimary)
                Spacer()
                Text("\(Int(themeManager.fontSize))pt")
                    .foregroundStyle(MuxiTokens.Colors.textSecondary)
                    .monospacedDigit()
                Stepper("", value: fontSizeBinding, in: 10...24, step: 2)
                    .labelsHidden()
            }
        }
    }

    private var fontSizeBinding: Binding<CGFloat> {
        Binding(
            get: { themeManager.fontSize },
            set: { themeManager.setFontSize($0) }
        )
    }

    // MARK: - About

    @ViewBuilder
    private var aboutSection: some View {
        Section("About") {
            HStack {
                Label("Version", systemImage: "info.circle")
                    .foregroundStyle(MuxiTokens.Colors.textPrimary)
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                    .foregroundStyle(MuxiTokens.Colors.textSecondary)
            }
        }
    }
}
```

**Step 2: Update ContentView to use SettingsView**

In `ios/Muxi/App/ContentView.swift`, replace the toolbar NavigationLink (line 135-139):

```swift
                    NavigationLink {
                        SettingsView(themeManager: themeManager)
                    } label: {
                        Image(systemName: "gearshape")
                    }
```

**Step 3: Run all tests to verify no regression**

Run: `cd ios && xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.2' 2>&1 | tail -30`
Expected: PASS

**Step 4: Commit**

```bash
git add ios/Muxi/Views/Settings/SettingsView.swift ios/Muxi/App/ContentView.swift
git commit -m "feat: add SettingsView hub with font size stepper

Replaces direct gear → ThemeSettingsView with a settings hub.
Theme selection accessible as sub-screen, font size adjustable
via stepper (10–24pt, 2pt steps)."
```

---

### Task 3: Wire Font Size to Terminal Rendering

**Files:**
- Modify: `ios/Muxi/Views/Terminal/TerminalView.swift`
- Modify: `ios/Muxi/Views/Terminal/TerminalSessionView.swift`

The font size needs to flow from `themeManager.fontSize` to both:
1. `TerminalView.makeUIView` — creates the initial font for TerminalRenderer
2. `TerminalView.updateUIView` — detects font size changes and calls `renderer.updateFont()`
3. `TerminalSessionView.terminalCellSize()` — calculates cols/rows for terminal sizing

**Step 1: Add fontSize to TerminalView**

In `ios/Muxi/Views/Terminal/TerminalView.swift`, add after line 13 (`var onPaste`):

```swift
    var fontSize: CGFloat = 14
```

**Step 2: Update makeUIView to use dynamic font size**

Replace the hardcoded font creation (lines 49-50):

```swift
        let font = UIFont(name: "Sarasa Term K Nerd Font", size: fontSize)
            ?? UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
```

Store the font size in the coordinator for change detection. Add to the Coordinator class properties:

```swift
        var currentFontSize: CGFloat = 14
```

In `makeUIView`, after `context.coordinator.cellHeight = renderer.cellHeight`:

```swift
            context.coordinator.currentFontSize = fontSize
```

**Step 3: Handle font size changes in updateUIView**

In `updateUIView`, add after the theme change block (after `if bufferChanged { ... }`):

```swift
        // Update font if size changed.
        if context.coordinator.currentFontSize != fontSize {
            context.coordinator.currentFontSize = fontSize
            let newFont = UIFont(name: "Sarasa Term K Nerd Font", size: fontSize)
                ?? UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            context.coordinator.renderer?.updateFont(newFont)
            context.coordinator.cellHeight = context.coordinator.renderer?.cellHeight ?? 0
            context.coordinator.requestRedraw()
        }
```

**Step 4: Update TerminalSessionView to pass fontSize**

In `ios/Muxi/Views/Terminal/TerminalSessionView.swift`, update the `panes` computed property is unchanged — we pass fontSize separately through PaneContainerView.

First, update `terminalCellSize()` to accept a fontSize parameter:

```swift
    static func terminalCellSize(fontSize: CGFloat = 14) -> (width: CGFloat, height: CGFloat) {
        let font = UIFont(name: "Sarasa Term K Nerd Font", size: fontSize)
            ?? UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
```

Then update `updateTerminalSize` to use the themeManager's fontSize:

```swift
    private func updateTerminalSize(_ size: CGSize) {
        let (cellW, cellH) = Self.terminalCellSize(fontSize: themeManager.fontSize)
```

**Step 5: Pass fontSize through PaneContainerView to TerminalView**

Add `fontSize: CGFloat = 14` to PaneContainerView struct properties (in `ios/Muxi/Views/Terminal/PaneContainerView.swift`):

```swift
    var fontSize: CGFloat = 14
```

Pass it to TerminalView in both compact and regular layouts. In each TerminalView creation, add:

```swift
                    fontSize: fontSize,
```

In TerminalSessionView where PaneContainerView is created, add:

```swift
                            fontSize: themeManager.fontSize,
```

**Step 6: Run all tests**

Run: `cd ios && xcodebuild test -project Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.2' 2>&1 | tail -30`
Expected: PASS

**Step 7: Commit**

```bash
git add ios/Muxi/Views/Terminal/TerminalView.swift ios/Muxi/Views/Terminal/TerminalSessionView.swift ios/Muxi/Views/Terminal/PaneContainerView.swift
git commit -m "feat: wire font size from settings to terminal rendering

Dynamic font size flows: ThemeManager → TerminalSessionView →
PaneContainerView → TerminalView → TerminalRenderer.updateFont().
Terminal cols/rows recalculated on font size change."
```

---

## Notes for Implementer

### Key files to read first
- `docs/plans/2026-03-04-settings-screen-design.md` — design rationale
- `ios/Muxi/Services/ThemeManager.swift` — existing pattern for UserDefaults persistence
- `ios/Muxi/Views/Settings/ThemeSettingsView.swift` — reused in SettingsView hub
- `ios/Muxi/Terminal/TerminalRenderer.swift:112-118` — existing `updateFont()` method

### Testing strategy
- Task 1: Pure model tests for ThemeManager.fontSize (Swift Testing)
- Task 2-3: Integration verified by full test suite + manual testing on simulator

### Font change flow
```
User adjusts Stepper in SettingsView
  → ThemeManager.setFontSize() → UserDefaults + @Observable update
  → SwiftUI re-renders TerminalSessionView (themeManager.fontSize changed)
  → PaneContainerView passes new fontSize to TerminalView
  → TerminalView.updateUIView detects change → renderer.updateFont()
  → Renderer rebuilds glyph atlas at new size → redraw
  → updateTerminalSize() recalculates cols/rows → tmux resize
```

### TerminalRenderer.updateFont() already exists
The renderer has a complete `updateFont(_:)` method (line 112) that:
1. Updates the stored font
2. Re-measures cell size
3. Clears and rebuilds the glyph atlas
4. Sets `needsRedraw = true`

No renderer modifications needed — just call this existing method.
