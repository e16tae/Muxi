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

Terminal text uses the bundled monospace font (Sarasa Term K Nerd Font) — not MuxiTokens.Typography.

### Motion — `MuxiTokens.Motion`

| Token | Animation | Use |
|-------|-----------|-----|
| `appear` | spring 0.4s, bounce 0.15 | View enter |
| `tap` | spring 0.2s, bounce 0.2 | Button press |
| `transition` | spring 0.35s, bounce 0.1 | State change |
| `subtle` | easeInOut 0.2s | Minor updates |

Use `muxiAnimation(\.appear, value:)` view modifier — automatically respects `accessibilityReduceMotion`.

## Rules

- Never hardcode color/spacing/radius values in views — always use `MuxiTokens`
- Terminal area is exempt — uses theme-provided colors
- Dark-only mode — no light mode token variants exist
- Adding a new token: add to `MuxiTokens.swift`, update this guide
