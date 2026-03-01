#!/usr/bin/env bash
# build-openssl.sh — Cross-compile OpenSSL 3.x for iOS (device + simulator)
# Produces: vendor/openssl.xcframework/  (combined libssl + libcrypto)
#
# Usage: ./scripts/build-openssl.sh
# Requirements: Xcode command line tools, internet access (first run)

set -euo pipefail

# ── Paths ───────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/build/openssl"
VENDOR_DIR="$PROJECT_ROOT/vendor"
XCFRAMEWORK_OUT="$VENDOR_DIR/openssl.xcframework"

# ── Configuration ───────────────────────────────────────────────────────────
OPENSSL_VERSION="3.4.1"
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"
IOS_MIN_VERSION="17.0"

# Architectures
DEVICE_ARCHS=("arm64")
SIM_ARCHS=("arm64" "x86_64")

# ── Helpers ─────────────────────────────────────────────────────────────────
log() { echo "==> $*"; }
err() { echo "ERROR: $*" >&2; exit 1; }

# ── Skip if already built ──────────────────────────────────────────────────
if [[ -d "$XCFRAMEWORK_OUT" ]]; then
    log "openssl.xcframework already exists at $XCFRAMEWORK_OUT"
    log "Delete it to force a rebuild."
    exit 0
fi

# ── Download source ─────────────────────────────────────────────────────────
SOURCE_TAR="$BUILD_DIR/openssl-${OPENSSL_VERSION}.tar.gz"
SOURCE_DIR="$BUILD_DIR/openssl-${OPENSSL_VERSION}"

mkdir -p "$BUILD_DIR"

if [[ ! -f "$SOURCE_TAR" ]]; then
    log "Downloading OpenSSL ${OPENSSL_VERSION}..."
    curl -fSL "$OPENSSL_URL" -o "$SOURCE_TAR"
else
    log "Using cached source tarball: $SOURCE_TAR"
fi

if [[ ! -d "$SOURCE_DIR" ]]; then
    log "Extracting source..."
    tar xzf "$SOURCE_TAR" -C "$BUILD_DIR"
fi

# ── SDK paths ───────────────────────────────────────────────────────────────
IPHONEOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
IPHONESIM_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"

# ── Build function ──────────────────────────────────────────────────────────
# build_openssl <arch> <sdk_name> <sdk_path> <install_prefix>
build_openssl() {
    local arch="$1"
    local sdk_name="$2"
    local sdk_path="$3"
    local prefix="$4"

    if [[ -f "$prefix/lib/libssl.a" && -f "$prefix/lib/libcrypto.a" ]]; then
        log "  Skipping $sdk_name/$arch (already built)"
        return
    fi

    log "Building OpenSSL for $sdk_name/$arch..."

    # Determine the OpenSSL target
    local target
    case "$sdk_name-$arch" in
        iphoneos-arm64)          target="ios64-xcrun" ;;
        iphonesimulator-arm64)   target="iossimulator-xcrun" ;;
        iphonesimulator-x86_64)  target="iossimulator-xcrun" ;;
        *) err "Unknown sdk-arch combo: $sdk_name-$arch" ;;
    esac

    # Clean build directory — OpenSSL Configure requires building in-tree
    local work_dir="$BUILD_DIR/build-${sdk_name}-${arch}"
    rm -rf "$work_dir"
    cp -R "$SOURCE_DIR" "$work_dir"
    cd "$work_dir"

    # Configure
    ./Configure "$target" \
        --prefix="$prefix" \
        --openssldir="$prefix/ssl" \
        -isysroot "$sdk_path" \
        -arch "$arch" \
        -mios-version-min="$IOS_MIN_VERSION" \
        no-shared \
        no-dso \
        no-hw \
        no-engine \
        no-tests \
        no-ui-console \
        no-async \
        no-stdio

    # Build and install (no apps, no docs)
    make -j"$(sysctl -n hw.ncpu)" build_libs
    make install_dev DESTDIR=""

    log "  Installed to $prefix"
    cd "$PROJECT_ROOT"
}

# ── Build all architectures ─────────────────────────────────────────────────

# Device (arm64)
for arch in "${DEVICE_ARCHS[@]}"; do
    build_openssl "$arch" "iphoneos" "$IPHONEOS_SDK" \
        "$BUILD_DIR/install-iphoneos-${arch}"
done

# Simulator (arm64, x86_64)
for arch in "${SIM_ARCHS[@]}"; do
    build_openssl "$arch" "iphonesimulator" "$IPHONESIM_SDK" \
        "$BUILD_DIR/install-iphonesimulator-${arch}"
done

# ── Merge libssl + libcrypto into single libopenssl.a per slice ─────────────
log "Merging libssl.a + libcrypto.a into libopenssl.a for each slice..."

merge_openssl_libs() {
    local prefix="$1"
    local label="$2"
    if [[ -f "$prefix/lib/libopenssl.a" ]]; then
        log "  $label already merged"
        return
    fi
    libtool -static -o "$prefix/lib/libopenssl.a" \
        "$prefix/lib/libssl.a" \
        "$prefix/lib/libcrypto.a"
    log "  Merged $label -> libopenssl.a"
}

for arch in "${DEVICE_ARCHS[@]}"; do
    merge_openssl_libs "$BUILD_DIR/install-iphoneos-${arch}" "iphoneos/$arch"
done

for arch in "${SIM_ARCHS[@]}"; do
    merge_openssl_libs "$BUILD_DIR/install-iphonesimulator-${arch}" "iphonesimulator/$arch"
done

# ── Create fat simulator library via lipo ───────────────────────────────────
log "Creating fat simulator library..."
SIM_FAT_DIR="$BUILD_DIR/install-iphonesimulator-fat"
mkdir -p "$SIM_FAT_DIR/lib"

# Use headers from the arm64 simulator build
if [[ -d "$SIM_FAT_DIR/include" ]]; then
    rm -rf "$SIM_FAT_DIR/include"
fi
cp -R "$BUILD_DIR/install-iphonesimulator-arm64/include" "$SIM_FAT_DIR/include"

# Fat combined library for xcframework
sim_inputs=()
for arch in "${SIM_ARCHS[@]}"; do
    sim_inputs+=("$BUILD_DIR/install-iphonesimulator-${arch}/lib/libopenssl.a")
done
lipo -create "${sim_inputs[@]}" -output "$SIM_FAT_DIR/lib/libopenssl.a"
log "  Created fat libopenssl.a ($(lipo -info "$SIM_FAT_DIR/lib/libopenssl.a"))"

# Also create fat per-library files (libssh2 build needs them separately)
for lib in libssl.a libcrypto.a; do
    lib_inputs=()
    for arch in "${SIM_ARCHS[@]}"; do
        lib_inputs+=("$BUILD_DIR/install-iphonesimulator-${arch}/lib/${lib}")
    done
    lipo -create "${lib_inputs[@]}" -output "$SIM_FAT_DIR/lib/${lib}"
done

# ── Package into xcframework ────────────────────────────────────────────────
log "Creating openssl.xcframework..."
mkdir -p "$VENDOR_DIR"

DEVICE_DIR="$BUILD_DIR/install-iphoneos-arm64"

rm -rf "$XCFRAMEWORK_OUT"

xcodebuild -create-xcframework \
    -library "$DEVICE_DIR/lib/libopenssl.a" \
    -headers "$DEVICE_DIR/include" \
    -library "$SIM_FAT_DIR/lib/libopenssl.a" \
    -headers "$SIM_FAT_DIR/include" \
    -output "$XCFRAMEWORK_OUT"

log ""
log "OpenSSL ${OPENSSL_VERSION} build complete!"
log "  xcframework: $XCFRAMEWORK_OUT"
log ""
log "Per-arch installs preserved for libssh2 linking:"
for arch in "${DEVICE_ARCHS[@]}"; do
    log "  iphoneos/$arch:        $BUILD_DIR/install-iphoneos-${arch}"
done
for arch in "${SIM_ARCHS[@]}"; do
    log "  iphonesimulator/$arch: $BUILD_DIR/install-iphonesimulator-${arch}"
done
log "  iphonesimulator/fat:   $SIM_FAT_DIR"
