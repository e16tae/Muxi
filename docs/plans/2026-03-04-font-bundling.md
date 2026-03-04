# Font Bundling Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Bundle Sarasa Term K Nerd Font so the terminal renders Korean/English/CJK/icons with consistent monospaced metrics.

**Architecture:** Download script fetches font ZIP from GitHub release, verifies SHA-256, extracts Regular weight .ttf into `ios/Muxi/Resources/Fonts/`. iOS registers the font via UIAppFonts. Swift code references the font by PostScript name with system monospace fallback.

**Tech Stack:** Bash (download script), XcodeGen (project.yml), SwiftUI/CoreText (font loading)

---

### Task 1: Discover font file details

This task resolves the unknowns: exact .ttf filename inside the ZIP, PostScript name, and SHA-256 hash.

**Step 1: Download the ZIP and compute its SHA-256**

```bash
mkdir -p /tmp/muxi-font-inspect
curl -fSL "https://github.com/jonz94/Sarasa-Gothic-Nerd-Fonts/releases/download/v1.0.35-0/sarasa-term-k-nerd-font.zip" \
  -o /tmp/muxi-font-inspect/sarasa-term-k-nerd-font.zip
shasum -a 256 /tmp/muxi-font-inspect/sarasa-term-k-nerd-font.zip
```

Record the SHA-256 hash for Task 2.

**Step 2: List ZIP contents to find the Regular weight filename**

```bash
unzip -l /tmp/muxi-font-inspect/sarasa-term-k-nerd-font.zip | grep -i regular
```

Record the exact filename (e.g. `SarasaTermKNerdFont-Regular.ttf` or similar).

**Step 3: Extract the Regular weight .ttf**

```bash
unzip -j /tmp/muxi-font-inspect/sarasa-term-k-nerd-font.zip "*Regular*" -d /tmp/muxi-font-inspect/
```

**Step 4: Extract PostScript name from the .ttf**

```bash
# Method 1: fc-query (if available)
fc-query /tmp/muxi-font-inspect/*Regular*.ttf | grep -E "postscriptname|family"

# Method 2: otfinfo (if available via lcdf-typetools)
otfinfo -p /tmp/muxi-font-inspect/*Regular*.ttf

# Method 3: Python fallback
python3 -c "
from fontTools.ttLib import TTFont
font = TTFont(list(__import__('pathlib').Path('/tmp/muxi-font-inspect').glob('*Regular*.ttf'))[0])
for record in font['name'].names:
    if record.nameID == 6:  # PostScript name
        print(f'PostScript: {record.toUnicode()}')
    elif record.nameID == 1:  # Family name
        print(f'Family: {record.toUnicode()}')
"
```

Record the PostScript name — this is what `UIFont(name:)` needs.

**Step 5: Note discovered values**

Write down these three values for subsequent tasks:
1. SHA-256 hash of the ZIP
2. Exact .ttf filename inside the ZIP
3. PostScript name for `UIFont(name:)`

Clean up:
```bash
rm -rf /tmp/muxi-font-inspect
```

---

### Task 2: Create `scripts/download-fonts.sh`

**Files:**
- Create: `scripts/download-fonts.sh`

**Step 1: Write the script**

Use the values discovered in Task 1. Replace `<SHA256>`, `<TTF_FILENAME>`, and other placeholders with actual values.

```bash
#!/usr/bin/env bash
# download-fonts.sh — Download Sarasa Term K Nerd Font for Muxi iOS
# Produces: ios/Muxi/Resources/Fonts/<TTF_FILENAME>
#
# Usage: ./scripts/download-fonts.sh
# Requirements: internet access (first run only)

set -euo pipefail

# ── Paths ───────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FONTS_DIR="$PROJECT_ROOT/ios/Muxi/Resources/Fonts"

# ── Configuration ───────────────────────────────────────────────────────
FONT_VERSION="v1.0.35-0"
FONT_ZIP_NAME="sarasa-term-k-nerd-font.zip"
FONT_URL="https://github.com/jonz94/Sarasa-Gothic-Nerd-Fonts/releases/download/${FONT_VERSION}/${FONT_ZIP_NAME}"
FONT_ZIP_SHA256="<SHA256>"
# The exact .ttf filename inside the ZIP for Regular weight
FONT_TTF_NAME="<TTF_FILENAME>"

# ── Helpers ─────────────────────────────────────────────────────────────
log() { echo "==> $*"; }
err() { echo "ERROR: $*" >&2; exit 1; }

# ── Skip if already downloaded ──────────────────────────────────────────
if [[ -f "$FONTS_DIR/$FONT_TTF_NAME" ]]; then
    log "Font already exists at $FONTS_DIR/$FONT_TTF_NAME"
    log "Delete it to force a re-download."
    exit 0
fi

# ── Download ────────────────────────────────────────────────────────────
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

FONT_ZIP="$TEMP_DIR/$FONT_ZIP_NAME"

log "Downloading Sarasa Term K Nerd Font ${FONT_VERSION}..."
curl -fSL "$FONT_URL" -o "$FONT_ZIP"

# ── Verify SHA-256 ──────────────────────────────────────────────────────
log "Verifying checksum..."
echo "$FONT_ZIP_SHA256  $FONT_ZIP" | shasum -a 256 --check || {
    err "Checksum verification failed for $FONT_ZIP"
}

# ── Extract Regular weight only ─────────────────────────────────────────
log "Extracting $FONT_TTF_NAME..."
mkdir -p "$FONTS_DIR"
unzip -j "$FONT_ZIP" "$FONT_TTF_NAME" -d "$FONTS_DIR"

log ""
log "Font installed: $FONTS_DIR/$FONT_TTF_NAME"
log "Size: $(du -h "$FONTS_DIR/$FONT_TTF_NAME" | cut -f1)"
```

**Step 2: Make executable and test**

```bash
chmod +x scripts/download-fonts.sh
./scripts/download-fonts.sh
ls -lh ios/Muxi/Resources/Fonts/*.ttf
```

Expected: Font file exists in `ios/Muxi/Resources/Fonts/`.

**Step 3: Test idempotency**

```bash
./scripts/download-fonts.sh
```

Expected: `==> Font already exists at ...` (no re-download).

**Step 4: Commit**

```bash
git add scripts/download-fonts.sh
git commit -m "feat: add download-fonts.sh for Sarasa Term K Nerd Font"
```

---

### Task 3: Integrate into build pipeline

**Files:**
- Modify: `scripts/build-all.sh`
- Modify: `ios/project.yml`
- Modify: `ios/Muxi/Resources/Fonts/LICENSE`

**Step 1: Add font download step to build-all.sh**

Insert before the OpenSSL step (line 39), after the preflight checks:

```bash
# ── Step 0: Download fonts ────────────────────────────────────────────
log "Step 0/3: Downloading fonts"
"$SCRIPT_DIR/download-fonts.sh"
```

Update existing step labels:
- `Step 1/2: Building OpenSSL` → `Step 1/3: Building OpenSSL`
- `Step 2/2: Building libssh2` → `Step 2/3: Building libssh2`

**Step 2: Re-add UIAppFonts to project.yml**

Add under the `info: properties:` section for the Muxi target (after line 51):

```yaml
    info:
      path: Muxi/Info.plist
      properties:
        UIAppFonts:
          - Fonts/<TTF_FILENAME>
```

Replace `<TTF_FILENAME>` with the actual filename from Task 1.

**Step 3: Update LICENSE file**

Replace `ios/Muxi/Resources/Fonts/LICENSE` contents:

```
This directory contains Sarasa Term K Nerd Font.

Sarasa Gothic is licensed under the SIL Open Font License 1.1.
See: https://github.com/be5invis/Sarasa-Gothic/blob/master/LICENSE

Nerd Font patches by jonz94/Sarasa-Gothic-Nerd-Fonts.
Nerd Fonts is licensed under MIT.
See: https://github.com/ryanoasis/nerd-fonts/blob/master/LICENSE
```

**Step 4: Regenerate Xcode project**

```bash
cd ios && xcodegen generate
```

Expected: `Generating project...` succeeded.

**Step 5: Commit**

```bash
git add scripts/build-all.sh ios/project.yml ios/Muxi/Resources/Fonts/LICENSE
git commit -m "feat: integrate font download into build pipeline and project config"
```

---

### Task 4: Update font name in Swift code

**Files:**
- Modify: `ios/Muxi/Views/Terminal/TerminalView.swift:39`
- Modify: `ios/Muxi/Views/Terminal/TerminalSessionView.swift:131`

**Step 1: Update TerminalView.swift**

Replace (line 39):
```swift
let font = UIFont(name: "Sarasa Mono SC Nerd Font", size: 14)
```

With (using PostScript name from Task 1):
```swift
let font = UIFont(name: "<POSTSCRIPT_NAME>", size: 14)
```

Also update the comment on line 35-38 to reference the correct font name.

**Step 2: Update TerminalSessionView.swift**

Replace (line 131):
```swift
let font = UIFont(name: "Sarasa Mono SC Nerd Font", size: 14)
```

With:
```swift
let font = UIFont(name: "<POSTSCRIPT_NAME>", size: 14)
```

**Step 3: Build and verify**

```bash
cd ios && xcodebuild build -project Muxi.xcodeproj -scheme Muxi \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E 'BUILD|error:'
```

Expected: `** BUILD SUCCEEDED **`

**Step 4: Commit**

```bash
git add ios/Muxi/Views/Terminal/TerminalView.swift ios/Muxi/Views/Terminal/TerminalSessionView.swift
git commit -m "feat: update terminal font to Sarasa Term K Nerd Font"
```

---

### Task 5: Update memory

After all tasks pass, update MEMORY.md:
- Remove "Font bundling" from Remaining Work
- Add font details to project notes (font name, PostScript name, download script)

---
