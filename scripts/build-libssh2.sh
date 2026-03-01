#!/usr/bin/env bash
# build-libssh2.sh — Cross-compile libssh2 1.11.x for iOS (device + simulator)
# Produces: vendor/libssh2.xcframework/
#
# Requires: OpenSSL already built via build-openssl.sh
# Usage: ./scripts/build-libssh2.sh

set -euo pipefail

# ── Paths ───────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/build/libssh2"
OPENSSL_BUILD_DIR="$PROJECT_ROOT/build/openssl"
VENDOR_DIR="$PROJECT_ROOT/vendor"
XCFRAMEWORK_OUT="$VENDOR_DIR/libssh2.xcframework"

# ── Configuration ───────────────────────────────────────────────────────────
LIBSSH2_VERSION="1.11.1"
LIBSSH2_URL="https://github.com/libssh2/libssh2/releases/download/libssh2-${LIBSSH2_VERSION}/libssh2-${LIBSSH2_VERSION}.tar.gz"
# TODO: Verify this hash against https://libssh2.org/download/ or compute from
# a trusted download. The official release does not publish a SHA-256 sidecar.
LIBSSH2_SHA256="d2f1b3540b4e138aa4abaa6e4a6b2e0b0e1c37b4f837d0ea2c5e5f13a6e0d5b6"
IOS_MIN_VERSION="17.0"

# Architectures
DEVICE_ARCHS=("arm64")
SIM_ARCHS=("arm64" "x86_64")

# ── Helpers ─────────────────────────────────────────────────────────────────
log() { echo "==> $*"; }
err() { echo "ERROR: $*" >&2; exit 1; }

cleanup_on_error() {
    log "Build failed. Partial artifacts may remain in build/."
    log "Run 'rm -rf build/ vendor/' to clean up before retrying."
}
trap cleanup_on_error ERR

# ── Verify OpenSSL was built ────────────────────────────────────────────────
# Check that per-arch OpenSSL installs exist (produced by build-openssl.sh)
OPENSSL_CHECK_DEVICE="$OPENSSL_BUILD_DIR/install-iphoneos-arm64/lib/libssl.a"
OPENSSL_CHECK_SIM="$OPENSSL_BUILD_DIR/install-iphonesimulator-arm64/lib/libssl.a"

if [[ ! -f "$OPENSSL_CHECK_DEVICE" || ! -f "$OPENSSL_CHECK_SIM" ]]; then
    err "OpenSSL installs not found. Run build-openssl.sh first."
fi

# ── Skip if already built ──────────────────────────────────────────────────
if [[ -d "$XCFRAMEWORK_OUT" ]]; then
    log "libssh2.xcframework already exists at $XCFRAMEWORK_OUT"
    log "Delete it to force a rebuild."
    exit 0
fi

# ── Download source ─────────────────────────────────────────────────────────
SOURCE_TAR="$BUILD_DIR/libssh2-${LIBSSH2_VERSION}.tar.gz"
SOURCE_DIR="$BUILD_DIR/libssh2-${LIBSSH2_VERSION}"

mkdir -p "$BUILD_DIR"

if [[ ! -f "$SOURCE_TAR" ]]; then
    log "Downloading libssh2 ${LIBSSH2_VERSION}..."
    curl -fSL "$LIBSSH2_URL" -o "$SOURCE_TAR"
else
    log "Using cached source tarball: $SOURCE_TAR"
fi

# Verify SHA-256 checksum before extraction
log "Verifying checksum for libssh2 ${LIBSSH2_VERSION}..."
echo "$LIBSSH2_SHA256  $SOURCE_TAR" | shasum -a 256 --check || {
    rm -f "$SOURCE_TAR"
    err "Checksum verification failed for $SOURCE_TAR"
}

if [[ ! -d "$SOURCE_DIR" ]]; then
    log "Extracting source..."
    tar xzf "$SOURCE_TAR" -C "$BUILD_DIR"
fi

# ── SDK paths ───────────────────────────────────────────────────────────────
IPHONEOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
IPHONESIM_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"

# ── Build function ──────────────────────────────────────────────────────────
# build_libssh2 <arch> <sdk_name> <sdk_path> <openssl_prefix> <install_prefix>
build_libssh2() {
    local arch="$1"
    local sdk_name="$2"
    local sdk_path="$3"
    local openssl_prefix="$4"
    local prefix="$5"

    if [[ -f "$prefix/lib/libssh2.a" ]]; then
        log "  Skipping $sdk_name/$arch (already built)"
        return
    fi

    log "Building libssh2 for $sdk_name/$arch..."

    local cmake_build_dir="$BUILD_DIR/cmake-build-${sdk_name}-${arch}"
    rm -rf "$cmake_build_dir"
    mkdir -p "$cmake_build_dir"

    # Determine system processor for cmake
    local cmake_processor
    case "$arch" in
        arm64) cmake_processor="aarch64" ;;
        x86_64) cmake_processor="x86_64" ;;
        *) err "Unknown arch: $arch" ;;
    esac

    # Determine -target triple (replaces deprecated -miphoneos-version-min /
    # -mios-simulator-version-min flags)
    local target_triple
    case "$sdk_name-$arch" in
        iphoneos-arm64)          target_triple="arm64-apple-ios${IOS_MIN_VERSION}" ;;
        iphonesimulator-arm64)   target_triple="arm64-apple-ios${IOS_MIN_VERSION}-simulator" ;;
        iphonesimulator-x86_64)  target_triple="x86_64-apple-ios${IOS_MIN_VERSION}-simulator" ;;
        *) err "Unknown sdk-arch combo: $sdk_name-$arch" ;;
    esac

    # Write a cmake toolchain file for this build
    local toolchain_file="$cmake_build_dir/ios-toolchain.cmake"
    cat > "$toolchain_file" <<TOOLCHAIN
set(CMAKE_SYSTEM_NAME iOS)
set(CMAKE_SYSTEM_PROCESSOR ${cmake_processor})
set(CMAKE_OSX_ARCHITECTURES ${arch})
set(CMAKE_OSX_SYSROOT ${sdk_path})
set(CMAKE_OSX_DEPLOYMENT_TARGET ${IOS_MIN_VERSION})

# Compiler flags — use -target triple instead of deprecated -m*-version-min
set(CMAKE_C_FLAGS_INIT "-target ${target_triple} -arch ${arch}")
set(CMAKE_CXX_FLAGS_INIT "-target ${target_triple} -arch ${arch}")

# Force static builds
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)

# Find programs on host, libraries on target
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
TOOLCHAIN

    # Build in a subshell to isolate cd
    (
        cd "$cmake_build_dir"

        cmake "$SOURCE_DIR" \
            -DCMAKE_TOOLCHAIN_FILE="$toolchain_file" \
            -DCMAKE_INSTALL_PREFIX="$prefix" \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_PREFIX_PATH="$openssl_prefix" \
            -DOPENSSL_ROOT_DIR="$openssl_prefix" \
            -DOPENSSL_INCLUDE_DIR="$openssl_prefix/include" \
            -DOPENSSL_SSL_LIBRARY="$openssl_prefix/lib/libssl.a" \
            -DOPENSSL_CRYPTO_LIBRARY="$openssl_prefix/lib/libcrypto.a" \
            -DCRYPTO_BACKEND=OpenSSL \
            -DBUILD_SHARED_LIBS=OFF \
            -DBUILD_EXAMPLES=OFF \
            -DBUILD_TESTING=OFF \
            -DENABLE_ZLIB_COMPRESSION=OFF

        cmake --build . --config Release -j"$(sysctl -n hw.ncpu)"
        cmake --install . --config Release
    )

    log "  Installed to $prefix"
}

# ── Build all architectures ─────────────────────────────────────────────────

# Device (arm64)
for arch in "${DEVICE_ARCHS[@]}"; do
    # Device uses the per-arch OpenSSL install
    openssl_prefix="$OPENSSL_BUILD_DIR/install-iphoneos-${arch}"
    build_libssh2 "$arch" "iphoneos" "$IPHONEOS_SDK" "$openssl_prefix" \
        "$BUILD_DIR/install-iphoneos-${arch}"
done

# Simulator (arm64, x86_64)
for arch in "${SIM_ARCHS[@]}"; do
    # Simulator uses the per-arch OpenSSL install for compilation
    # (the fat library would confuse the linker at build time)
    openssl_prefix="$OPENSSL_BUILD_DIR/install-iphonesimulator-${arch}"
    build_libssh2 "$arch" "iphonesimulator" "$IPHONESIM_SDK" "$openssl_prefix" \
        "$BUILD_DIR/install-iphonesimulator-${arch}"
done

# ── Create fat simulator library via lipo ───────────────────────────────────
log "Creating fat simulator library..."
SIM_FAT_DIR="$BUILD_DIR/install-iphonesimulator-fat"
mkdir -p "$SIM_FAT_DIR/lib"

# Use headers from arm64 simulator build
if [[ -d "$SIM_FAT_DIR/include" ]]; then
    rm -rf "$SIM_FAT_DIR/include"
fi
cp -R "$BUILD_DIR/install-iphonesimulator-arm64/include" "$SIM_FAT_DIR/include"

lipo_inputs=()
for arch in "${SIM_ARCHS[@]}"; do
    lipo_inputs+=("$BUILD_DIR/install-iphonesimulator-${arch}/lib/libssh2.a")
done
lipo -create "${lipo_inputs[@]}" -output "$SIM_FAT_DIR/lib/libssh2.a"
log "  Created fat libssh2.a ($(lipo -info "$SIM_FAT_DIR/lib/libssh2.a"))"

# ── Package into xcframework ────────────────────────────────────────────────
log "Creating libssh2.xcframework..."
mkdir -p "$VENDOR_DIR"

DEVICE_DIR="$BUILD_DIR/install-iphoneos-arm64"

rm -rf "$XCFRAMEWORK_OUT"

xcodebuild -create-xcframework \
    -library "$DEVICE_DIR/lib/libssh2.a" \
    -headers "$DEVICE_DIR/include" \
    -library "$SIM_FAT_DIR/lib/libssh2.a" \
    -headers "$SIM_FAT_DIR/include" \
    -output "$XCFRAMEWORK_OUT"

# ── Add module map for Swift import ────────────────────────────────────────
log "Adding module.modulemap for Swift import..."
find "$XCFRAMEWORK_OUT" -name Headers -type d | while read -r headers_dir; do
    cat > "$headers_dir/module.modulemap" <<'MODULEMAP'
module CLibSSH2 [system] {
    header "libssh2.h"
    link "ssh2"
    export *
}
MODULEMAP
done

log ""
log "libssh2 ${LIBSSH2_VERSION} build complete!"
log "  xcframework: $XCFRAMEWORK_OUT"
