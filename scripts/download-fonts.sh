#!/usr/bin/env bash
# download-fonts.sh — Download Sarasa Gothic Mono Nerd Font for bundling
#
# Output:
#   ios/Muxi/Resources/Fonts/SarasaMonoSC-NF-Regular.ttf
#
# Usage: ./scripts/download-fonts.sh
# Requirements: curl, unzip, internet access (first run)
#
# This script is idempotent — re-running it will skip if the font is present.
# To force a re-download, delete the Fonts directory first.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FONTS_DIR="$PROJECT_ROOT/ios/Muxi/Resources/Fonts"

# Skip if already present
if [[ -f "$FONTS_DIR/SarasaMonoSC-NF-Regular.ttf" ]]; then
    echo "==> Font already present, skipping download."
    exit 0
fi

# Sarasa Gothic Nerd Fonts release from jonz94/Sarasa-Gothic-Nerd-Fonts
RELEASE_TAG="v1.1.0"
ZIP_NAME="sarasa-mono-sc-nerd-font.zip"
DOWNLOAD_URL="https://github.com/jonz94/Sarasa-Gothic-Nerd-Fonts/releases/download/${RELEASE_TAG}/${ZIP_NAME}"

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

echo "==> Downloading Sarasa Mono SC Nerd Font (${RELEASE_TAG})..."
curl -fSL "$DOWNLOAD_URL" -o "$TEMP_DIR/$ZIP_NAME"

echo "==> Extracting Regular weight..."
mkdir -p "$FONTS_DIR"

# Extract only the Regular weight TTF from the zip
unzip -jo "$TEMP_DIR/$ZIP_NAME" "*Regular.ttf" -d "$TEMP_DIR/extracted" 2>/dev/null || {
    # Try alternate naming pattern
    unzip -jo "$TEMP_DIR/$ZIP_NAME" "*regular.ttf" -d "$TEMP_DIR/extracted" 2>/dev/null || {
        echo "ERROR: Could not find Regular weight TTF in archive" >&2
        exit 1
    }
}

# Find the extracted TTF and copy with a consistent name
FOUND=$(find "$TEMP_DIR/extracted" -name "*[Rr]egular*.ttf" | head -1)
if [[ -z "$FOUND" ]]; then
    echo "ERROR: No Regular weight TTF found after extraction" >&2
    exit 1
fi

cp "$FOUND" "$FONTS_DIR/SarasaMonoSC-NF-Regular.ttf"

echo "==> Font installed to $FONTS_DIR/"
ls -la "$FONTS_DIR/SarasaMonoSC-NF-Regular.ttf"
echo ""
echo "Done. The font will be bundled into the app on next build."
