# Muxi Design System Specification

**Date**: 2026-03-03
**Status**: Approved

## Design Direction

| Decision | Choice |
|----------|--------|
| Personality | Warm/Friendly |
| Accent Color | Lavender/Purple |
| Mode | Dark Only |
| Background Tone | Warm Dark (purple undertone) |
| Navigation | Full Immersive (terminal fullscreen, management UI as overlay) |
| Controls | Soft Cards (rounded corners, subtle bg difference, no shadows) |
| Motion | Playful (spring bounce, accessibilityReduceMotion respected) |
| Design Approach | Semantic Token System |

---

## 1. Color System

### 60-30-10 Ratio

**Terminal Screen (90% of usage time):**

| Ratio | Role | Color |
|-------|------|-------|
| 95% | Terminal theme background | Per-theme (default Catppuccin #1E1E2E) |
| 4% | Extended keyboard / status | Surface Raised |
| 1% | Accent (cursor, active tab) | Lavender |

**Management UI (server list, settings — overlay):**

| Ratio | Role | Color |
|-------|------|-------|
| 60% | Background / surface | Surface / Surface Raised |
| 30% | Text / icons | Text Primary / Secondary |
| 10% | Accent / status | Lavender + Semantic |

### Color Tokens

```
── Surface (background layers) ─────────────
surface.base       #120E18   Deepest background (app root)
surface.default    #1A1520   Default background
surface.raised     #241E2C   Cards, overlays, sheets
surface.elevated   #2E2738   Modals, popovers (topmost)

── Accent (Lavender) ───────────────────────
accent.default     #B5A8D5   Buttons, toggles, active state
accent.bright      #D4C8F0   Hover/focus highlight
accent.subtle      #B5A8D5 @ 12%  Background tint, selected state
accent.muted       #B5A8D5 @ 6%   Very subtle hint

── Text ────────────────────────────────────
text.primary       #EAE2F2   Primary text (contrast 12:1)
text.secondary     #9B90A8   Secondary text, captions
text.tertiary      #6B6178   Inactive, placeholders
text.inverse       #120E18   Text on accent backgrounds

── Border / Divider ────────────────────────
border.default     #FFFFFF @ 8%   Subtle separators
border.strong      #FFFFFF @ 15%  Card borders
border.accent      #B5A8D5 @ 30%  Focus rings, selection borders

── Semantic (status) ───────────────────────
semantic.error     #FF6B6B   Error, delete
semantic.success   #6BCB77   Connected, complete
semantic.warning   #FFD93D   Warning, caution
semantic.info      #74B9FF   Info, links
```

### Design Rationale

- Surface layers have ~6-8% lightness difference (OKLCH L) between each step
- All surfaces carry purple undertone (Hue ~280°) for warmth
- Semantic colors match Lavender in lightness but differ in hue and saturation

---

## 2. Typography Scale

```
── Non-terminal UI (SF Pro / System) ───────
font.largeTitle    .title2      semibold    Overlay titles
font.title         .headline    semibold    Section titles, server names
font.body          .body        regular     General text
font.caption       .caption     regular     Secondary info, timestamps
font.label         .footnote    medium      Button labels, badges

── Terminal ────────────────────────────────
font.terminal      Sarasa Mono SC NF  14pt  Terminal content
```

Non-terminal UI uses SF Pro with Dynamic Type for accessibility.

---

## 3. Spacing System (4pt grid)

```
spacing.xs         4pt     Inline element gaps
spacing.sm         8pt     Icon-text, tight grouping
spacing.md         12pt    Card internal padding
spacing.lg         16pt    Section gaps, card external margin
spacing.xl         24pt    Major section separation
spacing.xxl        32pt    Overlay top/bottom padding
```

---

## 4. Corner Radius

```
radius.sm          8pt     Buttons, small badges, inputs
radius.md          12pt    Cards, list rows
radius.lg          16pt    Sheets, overlays
radius.full        9999pt  Circles (avatars, FAB)
```

Principle: No sharp corners (0pt). Minimum 8pt. Rounder = friendlier.

---

## 5. Motion System

```
── Animation Curves ────────────────────────
motion.appear      .spring(duration: 0.4, bounce: 0.15)
                   Card/overlay entrance. Slight bounce.

motion.tap         .spring(duration: 0.2, bounce: 0.2)
                   Button tap feedback. Fast and elastic.

motion.transition  .spring(duration: 0.35, bounce: 0.1)
                   Screen transitions. Smooth and natural.

motion.subtle      .easeInOut(duration: 0.2)
                   Color changes, opacity transitions.

── Reduce Motion ───────────────────────────
@Environment(\.accessibilityReduceMotion)
→ When true: replace all spring with .easeInOut(0.2),
  remove bounce, reduce duration
```

Bounce range 0.15-0.2: friendly but trustworthy.

---

## 6. Component Patterns

### Server Card (inside overlay)

```
╭─────────────────────────────────╮  surface.raised
│  ● production-01        SSH  ↗  │  radius.md (12pt)
│  192.168.1.1     2시간 전       │  padding: spacing.md (12pt)
╰─────────────────────────────────╯
  ● = semantic.success
  Server name = text.primary, font.title
  IP/time = text.secondary, font.caption
  SSH badge = accent.subtle bg + accent.default text
```

### Extended Keyboard (terminal bottom)

```
┌─────────────────────────────────┐  surface.raised
│ [Ctrl] [Alt] [Esc] │ [↑][↓][←][→]│  height: 44pt
└─────────────────────────────────┘  key button: radius.sm (8pt)
  Active modifier = accent.default background
  Inactive = accent.subtle background
  Divider = border.default
```

### Overlay Sheet (management UI)

```
╭─────────────────────────────────╮  surface.elevated
│         ─── (handle)            │  radius.lg (16pt)
│                                 │  motion.appear entrance
│  Servers                [+]     │  padding: spacing.xxl top
│                                 │  padding: spacing.lg horizontal
│  ╭ Server Card ─────────────╮   │
│  ╰──────────────────────────╯   │
│  ╭ Server Card ─────────────╮   │
│  ╰──────────────────────────╯   │
╰─────────────────────────────────╯
  handle = border.strong, radius.full
  [+] button = accent.default
```

### Rules

- Never use semantic + accent colors on the same component for different purposes
- Status dot = semantic color, badge = accent color (role separation)
- Cards never have drop shadows — depth expressed through surface lightness only
