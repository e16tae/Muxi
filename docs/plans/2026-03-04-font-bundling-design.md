# Font Bundling Design

## Goal

Bundle Sarasa Term K Nerd Font (Regular weight) so the terminal renders Korean, English, CJK, and Nerd Font icons with consistent monospaced metrics. Fallback to system monospace when font is unavailable.

## Font Selection

**Sarasa Term K Nerd Font** — Regular weight only.

| Criterion | Choice | Reason |
|-----------|--------|--------|
| Subfamily | Term (not Mono/Fixed) | Half-width em dashes, ambiguous-width chars as single cell — designed for terminal emulators |
| Orthography | K (Korean) | Korean-preferred glyph forms for shared CJK codepoints |
| Nerd Font | Patched | powerline, devicons, terminal status bar icons |
| Weight | Regular only | Bold deferred to future; CoreText synthetic bold as interim |

**Source:** [jonz94/Sarasa-Gothic-Nerd-Fonts](https://github.com/jonz94/Sarasa-Gothic-Nerd-Fonts) v1.0.35-0
- Asset: `sarasa-term-k-nerd-font.zip` (~140MB, contains all weights)
- Font Family Name: `Sarasa Term K Nerd Font`
- License: SIL OFL 1.1 (bundling permitted)

## Architecture

### Download Script (`scripts/download-fonts.sh`)

Follows the existing OpenSSL/libssh2 pattern:

1. Skip if font .ttf already exists in `ios/Muxi/Resources/Fonts/`
2. Download ZIP from GitHub release (pinned version + SHA-256 verification)
3. Extract Regular weight .ttf only via `unzip -j`
4. Delete ZIP to save disk space
5. Idempotent — safe to re-run

Called standalone or via `build-all.sh` (added as Step 0, before OpenSSL).

### Project Configuration

- `project.yml`: Re-add `UIAppFonts` with path `Fonts/<filename>.ttf`
- `Resources/Fonts` folder reference already configured (`type: folder`, `buildPhase: resources`)
- `.gitignore`: Add `ios/Muxi/Resources/Fonts/*.ttf` (keep LICENSE tracked)

### Code Changes

Two files reference the font name:
- `ios/Muxi/Views/Terminal/TerminalView.swift:39`
- `ios/Muxi/Views/Terminal/TerminalSessionView.swift:131`

Update from `"Sarasa Mono SC Nerd Font"` to actual PostScript name (extracted from .ttf during implementation). Fallback to `UIFont.monospacedSystemFont` is already in place.

### LICENSE Update

Update `ios/Muxi/Resources/Fonts/LICENSE` from "Sarasa Gothic Mono" to "Sarasa Term K".

## Known Unknowns (resolve during implementation)

| Item | Resolution |
|------|------------|
| Exact .ttf filename inside ZIP | Inspect ZIP after first download |
| PostScript name for `UIFont(name:)` | Extract from .ttf via `fc-query` or `otfinfo` |
| SHA-256 hash of ZIP | Compute after first download, hardcode in script |
| Individual .ttf file size | Measure after extraction |

## Tradeoffs

- **App size +15-20MB**: Unavoidable for CJK monospace font. Justified by Korean/CJK rendering quality.
- **~140MB build download**: One-time, cached. ZIP deleted after extraction.
- **No Bold weight**: Synthetic bold via CoreText for now. Can add Bold .ttf later.
- **Third-party repo dependency**: jonz94 repo could go away. Same risk as any GitHub-hosted dependency. Font file is cached locally after first download.

## Out of Scope

- Multiple weights (Bold, Italic)
- User-selectable fonts
- On-demand font download at runtime
- MuxiTokens.Typography changes (UI text uses system font, unrelated)
