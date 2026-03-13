# ADR-0005: Bundle Sarasa Term K Nerd Font

## Status

Accepted

## Date

2026-03-04

## Context

Muxi needs a monospaced font that renders Korean, English, CJK characters, and Nerd Font icons (powerline, devicons) with consistent terminal metrics. The font must be bundled with the app because system monospace fonts lack Nerd Font glyphs and optimal CJK terminal metrics.

## Decision

Bundle **Sarasa Term K Nerd Font** (Regular weight only).

- **Term** subfamily (not Mono/Fixed): half-width em dashes, ambiguous-width chars as single cell — designed for terminal emulators.
- **K** orthography: Korean-preferred glyph forms for shared CJK codepoints.
- **Nerd Font** patched: powerline symbols, devicons, terminal status icons.
- **Regular weight only**: Bold deferred; CoreText synthetic bold as interim.

Downloaded at build time by `scripts/download-fonts.sh` (same pattern as OpenSSL/libssh2), SHA-256 verified, `.ttf` gitignored.

## Alternatives Considered

### Sarasa Mono K

Mono subfamily instead of Term.

Rejected because:
- Mono renders em dashes and ambiguous-width characters as double-width — misaligns terminal column grid
- Term subfamily is explicitly designed for terminal emulators

### System monospace font (SF Mono)

Use `UIFont.monospacedSystemFont` with no bundled font.

Rejected because:
- No Nerd Font glyphs (powerline, devicons)
- No CJK characters — falls back to system CJK font with inconsistent metrics
- No Korean-optimized glyph forms

### Bundle multiple weights

Include Regular + Bold + Italic.

Rejected because:
- Each weight adds ~15-20MB to app size
- Bold rendering via CoreText synthetic bold is acceptable for terminal use
- Can add weights later without architectural change

## Consequences

- (+) Consistent monospaced rendering for Korean, English, CJK, and Nerd Font icons
- (+) Term subfamily metrics align with terminal column grid
- (-) +15-20MB app size for the Regular weight .ttf
- (-) ~140MB build-time download (one-time, ZIP deleted after extraction)
- (-) Dependency on third-party GitHub repo for font distribution
