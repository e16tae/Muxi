#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$ROOT_DIR/build/libtailscale"
OUTPUT_DIR="$ROOT_DIR/vendor"

# libtailscale version
LIBTAILSCALE_VERSION="v1.80.3"

echo "=== Building libtailscale ${LIBTAILSCALE_VERSION} ==="

# Check prerequisites
if ! command -v go &>/dev/null; then
    echo "ERROR: Go is required. Install from https://go.dev/dl/"
    exit 1
fi

GO_VERSION=$(go version | awk '{print $3}')
echo "Using Go: ${GO_VERSION}"

# Install gomobile if needed
if ! command -v gomobile &>/dev/null; then
    echo "Installing gomobile..."
    go install golang.org/x/mobile/cmd/gomobile@latest
    go install golang.org/x/mobile/cmd/gobind@latest
fi

echo "Initializing gomobile..."
gomobile init

# Create build workspace
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Create Go module for building libtailscale
cat > go.mod <<EOF
module libtailscale-build

go 1.23

require tailscale.com ${LIBTAILSCALE_VERSION}
EOF

cat > main.go <<'GOEOF'
package main

import _ "tailscale.com/libtailscale"

func main() {}
GOEOF

go mod tidy

echo "Building xcframework via gomobile bind..."
gomobile bind \
    -target ios \
    -o "$OUTPUT_DIR/libtailscale.xcframework" \
    tailscale.com/libtailscale

echo "=== libtailscale build complete ==="
echo "Output: $OUTPUT_DIR/libtailscale.xcframework/"
