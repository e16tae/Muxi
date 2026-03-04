#!/usr/bin/env bash
# download-fonts.sh — Download Sarasa Term K Nerd Font for Muxi iOS
# Produces: ios/Muxi/Resources/Fonts/sarasa-term-k-regular-nerd-font.ttf
#
# Usage: ./scripts/download-fonts.sh
# Requirements: internet access (first run only)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FONTS_DIR="$PROJECT_ROOT/ios/Muxi/Resources/Fonts"

FONT_VERSION="v1.0.35-0"
FONT_ZIP_NAME="sarasa-term-k-nerd-font.zip"
FONT_URL="https://github.com/jonz94/Sarasa-Gothic-Nerd-Fonts/releases/download/${FONT_VERSION}/${FONT_ZIP_NAME}"
FONT_ZIP_SHA256="a62a01ec64e09ed523784183f6f5e52fdba768f1971afa3a871c0c80675886bf"
FONT_TTF_NAME="sarasa-term-k-regular-nerd-font.ttf"

log() { echo "==> $*"; }
err() { echo "ERROR: $*" >&2; exit 1; }

# Skip if already downloaded
if [[ -f "$FONTS_DIR/$FONT_TTF_NAME" ]]; then
    log "Font already exists at $FONTS_DIR/$FONT_TTF_NAME"
    log "Delete it to force a re-download."
    exit 0
fi

# Download to temp dir (cleaned up on exit)
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

FONT_ZIP="$TEMP_DIR/$FONT_ZIP_NAME"

log "Downloading Sarasa Term K Nerd Font ${FONT_VERSION}..."
curl -fSL "$FONT_URL" -o "$FONT_ZIP"

# Verify SHA-256
log "Verifying checksum..."
echo "$FONT_ZIP_SHA256  $FONT_ZIP" | shasum -a 256 --check || {
    err "Checksum verification failed for $FONT_ZIP"
}

# Extract Regular weight only
log "Extracting $FONT_TTF_NAME..."
mkdir -p "$FONTS_DIR"
unzip -j "$FONT_ZIP" "$FONT_TTF_NAME" -d "$FONTS_DIR"

log ""
log "Font installed: $FONTS_DIR/$FONT_TTF_NAME"
log "Size: $(du -h "$FONTS_DIR/$FONT_TTF_NAME" | cut -f1)"
