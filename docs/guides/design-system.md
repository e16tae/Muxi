# Design System Guide

Muxi uses `MuxiTokens` — a semantic token system defined in `ios/Muxi/DesignSystem/MuxiTokens.swift`. All UI views reference tokens by role, never by raw hex values.

## Two Visual Contexts

| Context | Color source | Usage time |
|---------|-------------|------------|
| **Terminal** | Theme JSON (e.g., Catppuccin `#1E1E2E`) | ~90% |
| **Management UI** | `MuxiTokens.Colors` | ~10% |

These are independent. Terminal colors come from the user's selected theme. Management UI (toolbar, settings, server list) uses MuxiTokens exclusively.

## Token Categories

### Colors — `MuxiTokens.Colors`

**Surface layers** (background, 4 levels with ~6-8% OKLCH lightness steps, purple Hue ~280°):

| Token | Hex | Use |
|-------|-----|-----|
| `surfaceBase` | `#120E18` | App root background |
| `surfaceDefault` | `#1A1520` | Default background |
| `surfaceRaised` | `#241E2C` | Cards, overlays, sheets |
| `surfaceElevated` | `#2E2738` | Modals, popovers |

**Accent** (Lavender):

| Token | Value | Use |
|-------|-------|-----|
| `accentDefault` | `#B5A8D5` | Buttons, toggles, active state |
| `accentBright` | `#D4C8F0` | Hover/focus highlight |
| `accentSubtle` | 12% opacity | Background tint, selected state |
| `accentMuted` | 6% opacity | Very subtle hint |

**Text**:

| Token | Hex | Contrast | Use |
|-------|-----|----------|-----|
| `textPrimary` | `#EAE0F2` | ~12:1 | Primary text |
| `textSecondary` | `#9B90A8` | — | Captions, secondary |
| `textTertiary` | `#6B6178` | — | Placeholders, inactive |
| `textInverse` | `#120E18` | — | Text on accent backgrounds |

**Border/Divider**: `borderDefault` (8%), `borderStrong` (15%), `borderAccent` (30% of accent).

**Semantic status**: `error` (#FF6B6B), `success` (#6BCB77), `warning` (#FFD93D), `info` (#74B9FF).

### Spacing — `MuxiTokens.Spacing` (4pt grid)

| Token | Value |
|-------|-------|
| `xs` | 4pt |
| `sm` | 8pt |
| `md` | 12pt |
| `lg` | 16pt |
| `xl` | 24pt |
| `xxl` | 32pt |

### Radius — `MuxiTokens.Radius`

| Token | Value | Use |
|-------|-------|-----|
| `sm` | 8pt | Small elements |
| `md` | 12pt | Cards, buttons |
| `lg` | 16pt | Sheets, modals |
| `full` | 9999pt | Pills, circles |

### Typography — `MuxiTokens.Typography`

| Token | Style | Use |
|-------|-------|-----|
| `largeTitle` | title2, semibold | Screen titles |
| `title` | headline, semibold | Section headers |
| `body` | body | Content text |
| `caption` | caption | Secondary info |
| `label` | footnote, medium | Labels, badges |
| `monoCaption` | caption, monospaced | Command display, code snippets |

Terminal text uses the bundled monospace font (Sarasa Term K Nerd Font) — not MuxiTokens.Typography.

### Motion — `MuxiTokens.Motion`

**Semantic tokens** (primary API):

| Token | Animation | Use |
|-------|-----------|-----|
| `appear` | spring 0.4s, bounce 0.15 | View enter |
| `tap` | spring 0.2s, bounce 0.2 | Button press |
| `transition` | spring 0.35s, bounce 0.1 | State change |
| `subtle` | easeInOut 0.2s | Minor updates |

**Directional tokens** (asymmetric enter/exit):

| Token | Animation | Use |
|-------|-----------|-----|
| `entrance` | spring 0.4s, bounce 0.1 | View appearing (sheets, overlays) |
| `exit` | spring 0.2s, no bounce | View disappearing |

**Weight tokens** (element mass):

| Token | Animation | Use |
|-------|-----------|-----|
| `heavy` | spring 0.5s, bounce 0.15 | Bottom sheets, modals |
| `light` | spring 0.25s, no bounce | Tooltips, small popovers |

**Stagger timing** for orchestrated reveals:

```swift
// Stagger child elements at 40ms intervals
ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
    ItemView(item: item)
        .animation(MuxiTokens.Motion.staggerDelay(index: index), value: isVisible)
}
```

### Accessibility — `MuxiTokens.Accessibility`

| Token | Value | Use |
|-------|-------|-----|
| `minimumHitTarget` | 44pt | Minimum touch target (Apple HIG) |

## Dot-Syntax Colors (ShapeStyle Extension)

Preferred API for new code. Uses `extension ShapeStyle where Self == Color` to enable SwiftUI-native dot-syntax:

```swift
// Preferred — dot-syntax (matches .primary, .secondary)
Text("Hello")
    .foregroundStyle(.textPrimary)
    .background(.surfaceRaised)

// Also valid — explicit enum path
Text("Hello")
    .foregroundStyle(MuxiTokens.Colors.textPrimary)
    .background(MuxiTokens.Colors.surfaceRaised)
```

Available dot-syntax tokens:

| Category | Tokens |
|----------|--------|
| Surface | `.surfaceBase`, `.surfaceDefault`, `.surfaceRaised`, `.surfaceElevated` |
| Accent | `.accentDefault`, `.accentBright`, `.accentSubtle`, `.accentMuted` |
| Text | `.textPrimary`, `.textSecondary`, `.textTertiary`, `.textInverse` |
| Border | `.borderDefault`, `.borderStrong`, `.borderAccent` |
| Status | `.statusError`, `.statusSuccess`, `.statusWarning`, `.statusInfo` |

## EdgeInsets Constants

Composite padding tokens for consistent component spacing:

```swift
// Single call with clear intent
VStack { ... }
    .padding(.card)      // 12pt vertical, 16pt horizontal

ScrollView { ... }
    .padding(.screenContent)  // 12pt top, 16pt sides, 16pt bottom
```

| Token | Top | Leading | Bottom | Trailing | Use |
|-------|-----|---------|--------|----------|-----|
| `.toolbar` | 4pt | 8pt | 4pt | 8pt | Toolbar content |
| `.card` | 12pt | 16pt | 12pt | 16pt | Card containers |
| `.screenContent` | 12pt | 16pt | 16pt | 16pt | Screen-level content |
| `.listRow` | 8pt | 16pt | 8pt | 16pt | List rows |

## Motion Patterns

### View Modifier (recommended for `.animation`)

```swift
// Automatically respects accessibilityReduceMotion
SomeView()
    .muxiAnimation(\.appear, value: isVisible)
```

### withAnimation (for imperative state changes)

```swift
@Environment(\.accessibilityReduceMotion) private var reduceMotion

// Use ResolvedMotion to respect reduce motion
withAnimation(MuxiTokens.Motion.resolved(reduceMotion: reduceMotion).subtle) {
    showPanel.toggle()
}
```

### Reduce Motion Behavior

When `accessibilityReduceMotion` is enabled, `ResolvedMotion` substitutes safe crossfade alternatives:

| Normal | Reduce Motion |
|--------|--------------|
| spring with bounce | easeInOut (no movement) |
| entrance (0.4s) | easeInOut (0.2s) |
| heavy (0.5s) | easeInOut (0.25s) |
| subtle | unchanged (already safe) |

## Rules

- Never hardcode color/spacing/radius values in views — always use `MuxiTokens`
- Prefer dot-syntax (`.textPrimary`) for new code — cleaner and matches SwiftUI conventions
- Use `MuxiTokens.Motion` tokens for all animations — never scatter bare `.easeInOut` or `.spring` literals
- Use `muxiAnimation` or `ResolvedMotion` to respect `accessibilityReduceMotion`
- All interactive elements must meet `Accessibility.minimumHitTarget` (44pt)
- Terminal area is exempt — uses theme-provided colors
- Dark-only mode — no light mode token variants exist
- Adding a new token: add to `MuxiTokens.swift`, update this guide
