#!/usr/bin/env bash
# build-all.sh — Build all vendor dependencies for Muxi iOS
# Builds OpenSSL 3.x and libssh2 1.11.x as xcframeworks.
#
# Output:
#   vendor/openssl.xcframework/
#   vendor/libssh2.xcframework/
#
# Usage: ./scripts/build-all.sh
# Requirements: Xcode command line tools, internet access (first run)
#
# This script is idempotent — re-running it will skip already-built targets.
# To force a full rebuild, delete the vendor/ and build/ directories first.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

log() { echo ""; echo "======================================"; echo "  $*"; echo "======================================"; echo ""; }

# ── Preflight checks ───────────────────────────────────────────────────────
if ! command -v xcrun &>/dev/null; then
    echo "ERROR: xcrun not found. Install Xcode command line tools:" >&2
    echo "  xcode-select --install" >&2
    exit 1
fi

if ! command -v xcodebuild &>/dev/null; then
    echo "ERROR: xcodebuild not found. Install Xcode." >&2
    exit 1
fi

if ! command -v cmake &>/dev/null; then
    echo "ERROR: cmake not found. Install via: brew install cmake" >&2
    exit 1
fi

# ── Step 0: Download fonts ────────────────────────────────────────────────
log "Step 0/3: Downloading fonts"
"$SCRIPT_DIR/download-fonts.sh"

# ── Step 1: Build OpenSSL ───────────────────────────────────────────────────
log "Step 1/3: Building OpenSSL"
"$SCRIPT_DIR/build-openssl.sh"

# ── Step 2: Build libssh2 ──────────────────────────────────────────────────
log "Step 2/3: Building libssh2"
"$SCRIPT_DIR/build-libssh2.sh"

# ── Done ────────────────────────────────────────────────────────────────────
log "All vendor dependencies built successfully!"

echo "Output:"
echo "  $PROJECT_ROOT/vendor/openssl.xcframework/"
echo "  $PROJECT_ROOT/vendor/libssh2.xcframework/"
echo ""
echo "To use in SPM, add binary targets in Package.swift pointing to these xcframeworks."
echo "To rebuild from scratch: rm -rf build/ vendor/ && ./scripts/build-all.sh"
