# Design System Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Introduce a semantic design token system (colors, spacing, radius, typography, motion) and migrate all hardcoded values across Muxi's SwiftUI views.

**Architecture:** A single `MuxiTokens` enum (no instances) provides all design tokens as static properties. Views replace hardcoded values with token references. Motion helpers respect `accessibilityReduceMotion`. Terminal rendering (Metal/Theme.swift) is untouched — tokens apply only to the non-terminal SwiftUI UI layer.

**Tech Stack:** SwiftUI, Swift Testing, iOS 17+

**Reference:** `docs/plans/2026-03-03-design-system.md` (approved design spec)

---

### Task 1: Create MuxiTokens — Color Tokens

**Files:**
- Create: `ios/Muxi/DesignSystem/MuxiTokens.swift`
- Test: `ios/Muxi/Tests/DesignTokenTests.swift`

**Step 1: Write the failing test**

```swift
import Testing
@testable import Muxi

@Suite("Design Tokens — Colors")
struct ColorTokenTests {
    @Test func surfaceLayersHaveIncreasingLightness() {
        // Surface layers should get progressively lighter
        let surfaces = [
            MuxiTokens.Colors.surfaceBase,
            MuxiTokens.Colors.surfaceDefault,
            MuxiTokens.Colors.surfaceRaised,
            MuxiTokens.Colors.surfaceElevated
        ]
        for i in 0..<surfaces.count - 1 {
            let (_, _, bCurrent) = surfaces[i].rgbComponents
            let (_, _, bNext) = surfaces[i + 1].rgbComponents
            #expect(bNext > bCurrent, "Surface layer \(i+1) should be lighter than \(i)")
        }
    }

    @Test func accentColorIsDefined() {
        let accent = MuxiTokens.Colors.accentDefault
        let (r, g, b) = accent.rgbComponents
        // Lavender: approximately #B5A8D5
        #expect(r > 0.6 && r < 0.8)
        #expect(g > 0.5 && g < 0.75)
        #expect(b > 0.75 && b < 0.95)
    }

    @Test func semanticColorsAreDefined() {
        // Semantic colors must exist and be distinct from accent
        _ = MuxiTokens.Colors.error
        _ = MuxiTokens.Colors.success
        _ = MuxiTokens.Colors.warning
        _ = MuxiTokens.Colors.info
    }
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.2' CODE_SIGNING_ALLOWED=NO -only-testing:MuxiTests/ColorTokenTests 2>&1 | tail -20`
Expected: FAIL — `MuxiTokens` not defined

**Step 3: Write minimal implementation**

Create `ios/Muxi/DesignSystem/MuxiTokens.swift`:

```swift
import SwiftUI

// MARK: - Design Tokens

/// Muxi semantic design token system.
/// All visual constants (colors, spacing, radii, typography, motion) live here.
/// Views reference tokens by role, never by raw value.
enum MuxiTokens {

    // MARK: - Colors

    enum Colors {
        // Surface (background layers) — purple undertone, ~6% lightness steps
        static let surfaceBase     = Color(red: 0.071, green: 0.055, blue: 0.094)  // #120E18
        static let surfaceDefault  = Color(red: 0.102, green: 0.082, blue: 0.125)  // #1A1520
        static let surfaceRaised   = Color(red: 0.141, green: 0.118, blue: 0.173)  // #241E2C
        static let surfaceElevated = Color(red: 0.180, green: 0.153, blue: 0.220)  // #2E2738

        // Accent (Lavender)
        static let accentDefault   = Color(red: 0.710, green: 0.659, blue: 0.835)  // #B5A8D5
        static let accentBright    = Color(red: 0.831, green: 0.784, blue: 0.941)  // #D4C8F0
        static let accentSubtle    = accentDefault.opacity(0.12)
        static let accentMuted     = accentDefault.opacity(0.06)

        // Text
        static let textPrimary     = Color(red: 0.918, green: 0.878, blue: 0.949)  // #EAE0F2
        static let textSecondary   = Color(red: 0.608, green: 0.565, blue: 0.659)  // #9B90A8
        static let textTertiary    = Color(red: 0.420, green: 0.380, blue: 0.471)  // #6B6178
        static let textInverse     = surfaceBase

        // Border / Divider
        static let borderDefault   = Color.white.opacity(0.08)
        static let borderStrong    = Color.white.opacity(0.15)
        static let borderAccent    = accentDefault.opacity(0.30)

        // Semantic (status)
        static let error           = Color(red: 1.000, green: 0.420, blue: 0.420)  // #FF6B6B
        static let success         = Color(red: 0.420, green: 0.796, blue: 0.467)  // #6BCB77
        static let warning         = Color(red: 1.000, green: 0.851, blue: 0.239)  // #FFD93D
        static let info            = Color(red: 0.455, green: 0.725, blue: 1.000)  // #74B9FF
    }
}

// MARK: - Color Helpers

extension Color {
    /// Extract approximate RGB components (for testing)
    var rgbComponents: (red: CGFloat, green: CGFloat, blue: CGFloat) {
        let uiColor = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b)
    }
}
```

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.2' CODE_SIGNING_ALLOWED=NO -only-testing:MuxiTests/ColorTokenTests 2>&1 | tail -20`
Expected: PASS

**Step 5: Commit**

```bash
git add ios/Muxi/DesignSystem/MuxiTokens.swift ios/Muxi/Tests/DesignTokenTests.swift
git commit -m "feat: add MuxiTokens color definitions with tests"
```

---

### Task 2: Add Spacing, Radius, and Typography Tokens

**Files:**
- Modify: `ios/Muxi/DesignSystem/MuxiTokens.swift`
- Modify: `ios/Muxi/Tests/DesignTokenTests.swift`

**Step 1: Write the failing test**

Append to `DesignTokenTests.swift`:

```swift
@Suite("Design Tokens — Spacing")
struct SpacingTokenTests {
    @Test func allSpacingsAreMultiplesOf4() {
        let spacings: [CGFloat] = [
            MuxiTokens.Spacing.xs,
            MuxiTokens.Spacing.sm,
            MuxiTokens.Spacing.md,
            MuxiTokens.Spacing.lg,
            MuxiTokens.Spacing.xl,
            MuxiTokens.Spacing.xxl
        ]
        for spacing in spacings {
            #expect(spacing.truncatingRemainder(dividingBy: 4) == 0,
                    "\(spacing) is not a multiple of 4")
        }
    }

    @Test func spacingsAreStrictlyIncreasing() {
        let spacings: [CGFloat] = [
            MuxiTokens.Spacing.xs,
            MuxiTokens.Spacing.sm,
            MuxiTokens.Spacing.md,
            MuxiTokens.Spacing.lg,
            MuxiTokens.Spacing.xl,
            MuxiTokens.Spacing.xxl
        ]
        for i in 0..<spacings.count - 1 {
            #expect(spacings[i] < spacings[i + 1])
        }
    }
}

@Suite("Design Tokens — Radius")
struct RadiusTokenTests {
    @Test func radiiAreStrictlyIncreasing() {
        #expect(MuxiTokens.Radius.sm < MuxiTokens.Radius.md)
        #expect(MuxiTokens.Radius.md < MuxiTokens.Radius.lg)
        #expect(MuxiTokens.Radius.lg < MuxiTokens.Radius.full)
    }

    @Test func noZeroRadius() {
        // Warm/Friendly: no sharp corners
        #expect(MuxiTokens.Radius.sm >= 8)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.2' CODE_SIGNING_ALLOWED=NO -only-testing:MuxiTests/SpacingTokenTests -only-testing:MuxiTests/RadiusTokenTests 2>&1 | tail -20`
Expected: FAIL — `MuxiTokens.Spacing` not defined

**Step 3: Write minimal implementation**

Append to `MuxiTokens` enum in `MuxiTokens.swift`:

```swift
    // MARK: - Spacing (4pt grid)

    enum Spacing {
        static let xs:  CGFloat = 4
        static let sm:  CGFloat = 8
        static let md:  CGFloat = 12
        static let lg:  CGFloat = 16
        static let xl:  CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: - Radius

    enum Radius {
        static let sm:   CGFloat = 8
        static let md:   CGFloat = 12
        static let lg:   CGFloat = 16
        static let full: CGFloat = 9999
    }

    // MARK: - Typography

    enum Typography {
        static let largeTitle = Font.system(.title2, weight: .semibold)
        static let title      = Font.system(.headline, weight: .semibold)
        static let body       = Font.system(.body)
        static let caption    = Font.system(.caption)
        static let label      = Font.system(.footnote, weight: .medium)
    }
```

**Step 4: Run test to verify it passes**

Run: same as Step 2
Expected: PASS

**Step 5: Commit**

```bash
git add ios/Muxi/DesignSystem/MuxiTokens.swift ios/Muxi/Tests/DesignTokenTests.swift
git commit -m "feat: add spacing, radius, and typography tokens"
```

---

### Task 3: Add Motion Tokens with Reduce Motion Support

**Files:**
- Modify: `ios/Muxi/DesignSystem/MuxiTokens.swift`
- Modify: `ios/Muxi/Tests/DesignTokenTests.swift`

**Step 1: Write the failing test**

Append to `DesignTokenTests.swift`:

```swift
@Suite("Design Tokens — Motion")
struct MotionTokenTests {
    @Test func motionTokensExist() {
        // Verify all motion tokens are accessible
        _ = MuxiTokens.Motion.appear
        _ = MuxiTokens.Motion.tap
        _ = MuxiTokens.Motion.transition
        _ = MuxiTokens.Motion.subtle
    }

    @Test func reducedMotionReturnsSubtleAnimations() {
        let reduced = MuxiTokens.Motion.resolved(reduceMotion: true)
        // When reduce motion is on, all animations should use the same subtle curve
        // We can't easily test Animation equality, but we verify the API exists
        _ = reduced.appear
        _ = reduced.tap
        _ = reduced.transition
    }
}
```

**Step 2: Run test to verify it fails**

Expected: FAIL — `MuxiTokens.Motion` not defined

**Step 3: Write minimal implementation**

Append to `MuxiTokens` enum:

```swift
    // MARK: - Motion

    enum Motion {
        static let appear     = Animation.spring(duration: 0.4, bounce: 0.15)
        static let tap        = Animation.spring(duration: 0.2, bounce: 0.2)
        static let transition = Animation.spring(duration: 0.35, bounce: 0.1)
        static let subtle     = Animation.easeInOut(duration: 0.2)

        /// Resolved motion set respecting accessibility preferences
        static func resolved(reduceMotion: Bool) -> ResolvedMotion {
            ResolvedMotion(reduceMotion: reduceMotion)
        }
    }

    struct ResolvedMotion {
        let reduceMotion: Bool

        var appear: Animation     { reduceMotion ? .easeInOut(duration: 0.2) : Motion.appear }
        var tap: Animation        { reduceMotion ? .easeInOut(duration: 0.15) : Motion.tap }
        var transition: Animation { reduceMotion ? .easeInOut(duration: 0.2) : Motion.transition }
        var subtle: Animation     { Motion.subtle }  // already subtle
    }
```

**Step 4: Run test to verify it passes**

Expected: PASS

**Step 5: Commit**

```bash
git add ios/Muxi/DesignSystem/MuxiTokens.swift ios/Muxi/Tests/DesignTokenTests.swift
git commit -m "feat: add motion tokens with reduce motion support"
```

---

### Task 4: Migrate ErrorBannerView to Design Tokens

**Files:**
- Modify: `ios/Muxi/Views/Common/ErrorBannerView.swift`

**Step 1: Identify all hardcoded values to replace**

Current hardcoded values in `ErrorBannerView.swift`:
- `.red`, `.orange`, `.blue` → `MuxiTokens.Colors.error/warning/info`
- Padding `12` → `MuxiTokens.Spacing.md`
- Corner radius `10` → `MuxiTokens.Radius.sm` (closest: 8, but we round up to md=12 for cards)
- Opacity `0.12` → `MuxiTokens.Colors.accentSubtle` pattern (keep 0.12 as semantic-color specific)
- Opacity `0.3` → border opacity pattern
- Padding `.horizontal 16` → `MuxiTokens.Spacing.lg`
- Animation `.easeInOut(duration: 0.25)` → `MuxiTokens.Motion.subtle`

**Step 2: Apply replacements**

Replace in `ErrorBannerView.swift`:

```swift
// BannerStyle.color computed property — replace:
case .error:   return MuxiTokens.Colors.error    // was .red
case .warning: return MuxiTokens.Colors.warning  // was .orange
case .info:    return MuxiTokens.Colors.info      // was .blue

// Layout — replace all hardcoded values:
.padding(MuxiTokens.Spacing.md)                   // was 12
.clipShape(RoundedRectangle(cornerRadius: MuxiTokens.Radius.md))  // was 10
.padding(.horizontal, MuxiTokens.Spacing.lg)       // was 16
.padding(.top, MuxiTokens.Spacing.sm)              // was 8
.animation(MuxiTokens.Motion.subtle, value: ...)   // was .easeInOut(duration: 0.25)
```

**Step 3: Build to verify no compile errors**

Run: `xcodebuild build -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.2' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add ios/Muxi/Views/Common/ErrorBannerView.swift
git commit -m "refactor: migrate ErrorBannerView to design tokens"
```

---

### Task 5: Migrate ReconnectingOverlay to Design Tokens

**Files:**
- Modify: `ios/Muxi/Views/Common/ReconnectingOverlay.swift`

**Step 1: Identify all hardcoded values to replace**

Current hardcoded values:
- `Color.black.opacity(0.5)` → `MuxiTokens.Colors.surfaceBase.opacity(0.7)` (warm dark backdrop)
- `.white` text → `MuxiTokens.Colors.textPrimary`
- `.white.opacity(0.7)` text → `MuxiTokens.Colors.textSecondary`
- `.white` button text → `MuxiTokens.Colors.textPrimary`
- `.white.opacity(0.15)` button bg → `MuxiTokens.Colors.accentSubtle`
- `.white.opacity(0.3)` button stroke → `MuxiTokens.Colors.borderAccent`
- Padding `.horizontal 24` → `MuxiTokens.Spacing.xl`
- Padding `.vertical 8` → `MuxiTokens.Spacing.sm`
- Padding `32` → `MuxiTokens.Spacing.xxl`
- Corner radius `16` → `MuxiTokens.Radius.lg`
- Spacing `20` → `MuxiTokens.Spacing.xl` (closest: 24, acceptable rounding)
- Remove `.environment(\.colorScheme, .dark)` — app is dark-only now

**Step 2: Apply replacements**

Replace all values per mapping above. Remove the `.environment(\.colorScheme, .dark)` modifier since the entire app will be dark-only. Use `.regularMaterial` → replace with `MuxiTokens.Colors.surfaceElevated` solid background for consistency.

**Step 3: Build to verify**

Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add ios/Muxi/Views/Common/ReconnectingOverlay.swift
git commit -m "refactor: migrate ReconnectingOverlay to design tokens"
```

---

### Task 6: Migrate ExtendedKeyboardView to Design Tokens

**Files:**
- Modify: `ios/Muxi/Views/Terminal/ExtendedKeyboardView.swift`

**Step 1: Identify all hardcoded values to replace**

Current values (theme-aware but with hardcoded sizing):
- `theme.foreground.color.opacity(0.3)` divider → `MuxiTokens.Colors.borderDefault`
- `theme.foreground.color` button text → `MuxiTokens.Colors.textPrimary`
- `theme.foreground.color.opacity(0.1)` button bg → `MuxiTokens.Colors.accentMuted`
- `theme.background.color` container bg → keep as-is (terminal theme background)
- Active modifier bg: `theme.foreground.color` → `MuxiTokens.Colors.accentDefault`
- Inactive modifier bg: `theme.foreground.color.opacity(0.1)` → `MuxiTokens.Colors.accentMuted`
- Corner radius `6` → `MuxiTokens.Radius.sm` (8)
- `minWidth: 36, minHeight: 32` → keep (touch target, not a design token)
- Font `size: 14, weight: .medium` → `MuxiTokens.Typography.label`
- Padding `.horizontal 8, .vertical 4` → `MuxiTokens.Spacing.sm`, `MuxiTokens.Spacing.xs`
- Frame height `44` → keep (standard iOS touch target)

**Note:** The keyboard background should remain `theme.background.color` since it sits directly above the terminal and must match the terminal theme. Only the buttons/dividers use design tokens.

**Step 2: Apply replacements**

**Step 3: Build to verify**

Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add ios/Muxi/Views/Terminal/ExtendedKeyboardView.swift
git commit -m "refactor: migrate ExtendedKeyboardView to design tokens"
```

---

### Task 7: Migrate PaneContainerView to Design Tokens

**Files:**
- Modify: `ios/Muxi/Views/Terminal/PaneContainerView.swift`

**Step 1: Identify all hardcoded values to replace**

Current values:
- `theme.foreground.color.opacity(0.2)` separator → `MuxiTokens.Colors.borderDefault`
- `Color(UIColor.systemBackground)` tab bar bg → `MuxiTokens.Colors.surfaceRaised`
- `.accentColor.opacity(0.3)` active tab → `MuxiTokens.Colors.accentSubtle`
- `.clear` inactive tab → `.clear` (keep)
- `.accentColor.opacity(0.5 or 0)` pane border → `MuxiTokens.Colors.borderAccent` or `.clear`
- Padding `.horizontal 12, .vertical 6` → `MuxiTokens.Spacing.md`, `MuxiTokens.Spacing.xs` (use 4+2 padding combo)
- Corner radius `8` → `MuxiTokens.Radius.sm`
- Frame height `36` → keep (tab bar height)
- Spacing `12` → `MuxiTokens.Spacing.md`
- Line width `2` → keep (border width, not a spacing token)

**Step 2: Apply replacements**

**Step 3: Build to verify**

Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add ios/Muxi/Views/Terminal/PaneContainerView.swift
git commit -m "refactor: migrate PaneContainerView to design tokens"
```

---

### Task 8: Migrate ThemeSettingsView and QuickActionButton

**Files:**
- Modify: `ios/Muxi/Views/Settings/ThemeSettingsView.swift`
- Modify: `ios/Muxi/Views/QuickAction/QuickActionView.swift` (QuickActionButton section)

**Step 1: ThemeSettingsView replacements**

- `.foregroundStyle(.blue)` checkmark → `.foregroundStyle(MuxiTokens.Colors.accentDefault)`
- Corner radius `2` → `MuxiTokens.Radius.sm` (theme preview swatch, but 8 is too big for 20x12 swatch — keep 2 for micro elements, or use 4)
- Spacing `2` → keep (micro element spacing)
- Spacing `4` → `MuxiTokens.Spacing.xs`

**Step 2: QuickActionButton replacements**

- Font `size: 20, weight: .semibold` → keep (icon sizing, not typography)
- Frame `52x52` → keep (touch target)
- `.foregroundStyle(.white)` → `MuxiTokens.Colors.textPrimary`
- `.fill(.tint)` → `.fill(MuxiTokens.Colors.accentDefault)`
- Shadow `.black.opacity(0.25), radius: 4` → remove shadow (design spec: no shadows on cards/buttons; depth via surface layers)

**Step 3: Build to verify**

Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add ios/Muxi/Views/Settings/ThemeSettingsView.swift ios/Muxi/Views/QuickAction/QuickActionView.swift
git commit -m "refactor: migrate ThemeSettingsView and QuickActionButton to design tokens"
```

---

### Task 9: Set App-Wide Dark Mode and Accent Color

**Files:**
- Modify: `ios/Muxi/MuxiApp.swift` (or root app entry point)

**Step 1: Identify app entry point**

Read `ios/Muxi/MuxiApp.swift` to find the `@main` App struct.

**Step 2: Apply dark-only and accent color**

Add to the root view:
```swift
.preferredColorScheme(.dark)
.tint(MuxiTokens.Colors.accentDefault)
```

This ensures:
- Entire app is always dark (Dark Only decision)
- All system controls (toggles, navigation links, etc.) use Lavender accent
- No need to set `.environment(\.colorScheme, .dark)` on individual views

**Step 3: Build to verify**

Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add ios/Muxi/MuxiApp.swift
git commit -m "feat: set app-wide dark mode and Lavender accent"
```

---

### Task 10: Final Integration Test and Cleanup

**Files:**
- All modified files
- Modify: `ios/Muxi/Tests/DesignTokenTests.swift`

**Step 1: Run full test suite**

Run: `xcodebuild test -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.2' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30`
Expected: ALL TESTS PASS

**Step 2: Grep for remaining hardcoded colors**

Run: `grep -rn '\.red\b\|\.orange\b\|\.blue\b\|Color\.white\|Color\.black\|UIColor\.system' ios/Muxi/Views/`

Any remaining hits should be:
- In files we intentionally didn't migrate (e.g., views not yet created)
- Or justified (like `.listStyle` modifiers that use system colors internally)

If unjustified hardcoded values remain, migrate them.

**Step 3: Grep for remaining hardcoded spacing**

Run: `grep -rn 'padding([0-9]\|cornerRadius([0-9]\|spacing: [0-9]' ios/Muxi/Views/`

Replace any remaining raw numbers with tokens.

**Step 4: Commit cleanup if needed**

```bash
git add -A
git commit -m "refactor: clean up remaining hardcoded values"
```

**Step 5: Run full build one more time**

Run: `xcodebuild build -project ios/Muxi.xcodeproj -scheme Muxi -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.2' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10`
Expected: BUILD SUCCEEDED
