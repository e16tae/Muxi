# ADR-0006: Semantic token design system (MuxiTokens)

## Status

Accepted

## Date

2026-03-03

## Context

Muxi has two distinct visual contexts: the terminal view (90%+ of usage time, themed by terminal color schemes like Catppuccin) and the management UI (server list, settings, toolbar — overlaid on the terminal). Colors, typography, and spacing must be consistent across the management UI while not conflicting with arbitrary terminal themes.

## Decision

Adopt a semantic token system (`MuxiTokens`) with layered surface colors, accent, text, and semantic status tokens. Dark-only mode with warm purple undertone.

Key design choices:
- **60-30-10 color ratio**: Surface (60%), Text/icons (30%), Accent (10%)
- **Surface layers**: 4 levels (base → default → raised → elevated) with ~6-8% OKLCH lightness steps and purple undertone (Hue ~280°)
- **Accent**: Lavender (`#B5A8D5`) with bright/subtle/muted opacity variants
- **Terminal independence**: Terminal area uses per-theme colors (e.g., Catppuccin `#1E1E2E`), management UI uses MuxiTokens — no coupling

Tokens are Swift constants, not runtime-configurable. Token values are defined in code (`MuxiTokens` enum), not in JSON or asset catalogs.

## Alternatives Considered

### Raw hardcoded colors

Use hex color literals directly in SwiftUI views.

Rejected because:
- Inconsistency across views (slightly different grays, spacing)
- Changing the accent color requires finding every occurrence
- No semantic meaning — `Color(hex: "#B5A8D5")` doesn't communicate "this is the accent"

### Dynamic theming (light + dark)

Support both light and dark modes with semantic tokens mapping to different values.

Rejected because:
- Terminal apps are universally dark — light mode adds complexity with no user demand
- Terminal color themes (Catppuccin, Dracula, etc.) are dark-only
- Doubles the design surface for no practical benefit

## Consequences

- (+) Consistent visual language across all management UI
- (+) Accent/theme changes require updating token definitions only
- (+) Clear boundary: terminal colors are theme-driven, UI colors are token-driven
- (-) Adding light mode later requires extending all token definitions
- (-) Swift constants mean token changes require recompilation (acceptable for app, not a design tool)
