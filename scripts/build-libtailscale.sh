#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$ROOT_DIR/build/libtailscale"
OUTPUT_DIR="$ROOT_DIR/vendor"

echo "=== Building libtailscale (tsnet C library) ==="

# Check prerequisites
if ! command -v go &>/dev/null; then
    echo "ERROR: Go >= 1.23 is required. Install from https://go.dev/dl/"
    exit 1
fi

GO_VERSION=$(go version | awk '{print $3}')
echo "Using Go: ${GO_VERSION}"

# Ensure GOPATH/bin is in PATH
export GOPATH="${GOPATH:-$(go env GOPATH)}"
export PATH="$PATH:$GOPATH/bin"

# Create build workspace
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Create Go module with C-exported wrapper around tsnet
cat > go.mod <<'EOF'
module muxitailscale

go 1.23
EOF

cat > main.go <<'GOEOF'
package main

import "C"
import (
	"context"
	"fmt"
	"log"
	"net"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"tailscale.com/tsnet"
)

// Debug logger — writes to a file in the state directory.
var debugLog *log.Logger

func initDebugLog(dir string) {
	f, err := os.OpenFile(filepath.Join(dir, "muxits.log"),
		os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0644)
	if err != nil {
		debugLog = log.New(os.Stderr, "muxits: ", log.LstdFlags|log.Lmicroseconds)
		return
	}
	debugLog = log.New(f, "", log.LstdFlags|log.Lmicroseconds)
}

// Global state — single Tailscale server instance.
var (
	mu       sync.Mutex
	server   *tsnet.Server
	conns   = make(map[int32]net.Conn)
	connFDs = make(map[int32]int32)
	nextConn int32 = 1
)

//export muxits_start
func muxits_start(controlURL *C.char, authKey *C.char, hostname *C.char, stateDir *C.char, errBuf *C.char, errBufLen C.int) C.int {
	mu.Lock()
	defer mu.Unlock()

	if server != nil {
		writeErr(errBuf, errBufLen, "already started")
		return -1
	}

	stateDirectory := C.GoString(stateDir)
	initDebugLog(stateDirectory)
	debugLog.Printf("start: controlURL=%s hostname=%s dir=%s", C.GoString(controlURL), C.GoString(hostname), stateDirectory)

	ts := &tsnet.Server{
		Hostname:   C.GoString(hostname),
		AuthKey:    C.GoString(authKey),
		ControlURL: C.GoString(controlURL),
		Dir:        C.GoString(stateDir),
		Ephemeral:  true,
	}
	// Enable logging for debugging
	ts.Logf = func(format string, args ...any) {
		fmt.Fprintf(os.Stderr, "tsnet: "+format+"\n", args...)
	}

	// 30-second timeout for initial connection
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	if _, err := ts.Up(ctx); err != nil {
		ts.Close()
		writeErr(errBuf, errBufLen, fmt.Sprintf("tailscale up: %v", err))
		return -1
	}

	server = ts
	return 0
}

//export muxits_stop
func muxits_stop() {
	mu.Lock()
	defer mu.Unlock()

	for id, fd := range connFDs {
		syscall.Close(int(fd))
		delete(connFDs, id)
	}
	for id, conn := range conns {
		conn.Close()
		delete(conns, id)
	}

	if server != nil {
		server.Close()
		server = nil
	}
}

//export muxits_dial
func muxits_dial(host *C.char, port C.int, errBuf *C.char, errBufLen C.int) C.int {
	mu.Lock()
	ts := server
	mu.Unlock()

	if ts == nil {
		writeErr(errBuf, errBufLen, "not started")
		return -1
	}

	addr := fmt.Sprintf("%s:%d", C.GoString(host), int(port))
	debugLog.Printf("dial: connecting to %s via tsnet", addr)

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	conn, err := ts.Dial(ctx, "tcp", addr)
	if err != nil {
		writeErr(errBuf, errBufLen, fmt.Sprintf("dial: %v", err))
		return -1
	}

	// Start a local TCP proxy: Swift/libssh2 connects to 127.0.0.1:localPort
	// using a normal TCP socket, avoiding all socketpair/fd issues.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		conn.Close()
		writeErr(errBuf, errBufLen, fmt.Sprintf("listen: %v", err))
		return -1
	}

	localPort := ln.Addr().(*net.TCPAddr).Port

	// Accept one connection and proxy it to the tsnet conn
	go func() {
		defer ln.Close()

		debugLog.Printf("proxy: waiting for local connection on port %d", localPort)
		localConn, err := ln.Accept()
		if err != nil {
			debugLog.Printf("proxy: accept error: %v", err)
			conn.Close()
			return
		}
		debugLog.Printf("proxy: accepted local connection")
		if tc, ok := localConn.(*net.TCPConn); ok {
			tc.SetNoDelay(true)
		}

		done := make(chan struct{}, 2)
		// tsnet → local
		go func() {
			buf := make([]byte, 32768)
			var total int64
			for {
				n, err := conn.Read(buf)
				if n > 0 {
					total += int64(n)
					if _, werr := localConn.Write(buf[:n]); werr != nil {
						debugLog.Printf("proxy: tsnet→local write error after %d bytes: %v", total, werr)
						break
					}
				}
				if err != nil {
					debugLog.Printf("proxy: tsnet→local read ended after %d bytes: %v", total, err)
					break
				}
			}
			done <- struct{}{}
		}()
		// local → tsnet
		go func() {
			buf := make([]byte, 32768)
			var total int64
			for {
				n, err := localConn.Read(buf)
				if n > 0 {
					total += int64(n)
					if _, werr := conn.Write(buf[:n]); werr != nil {
						debugLog.Printf("proxy: local→tsnet write error after %d bytes: %v", total, werr)
						break
					}
				}
				if err != nil {
					debugLog.Printf("proxy: local→tsnet read ended after %d bytes: %v", total, err)
					break
				}
			}
			done <- struct{}{}
		}()
		// Wait for BOTH to finish before cleanup
		<-done
		<-done
		debugLog.Printf("proxy: both directions done, cleaning up")
		localConn.Close()
		conn.Close()
	}()

	mu.Lock()
	id := nextConn
	nextConn++
	conns[id] = conn
	connFDs[id] = int32(localPort)
	mu.Unlock()

	return C.int(localPort)
}

//export muxits_close_conn
func muxits_close_conn(fd C.int) {
	mu.Lock()
	defer mu.Unlock()

	for id, storedFD := range connFDs {
		if C.int(storedFD) == fd {
			syscall.Close(int(storedFD))
			delete(connFDs, id)
			if conn, ok := conns[id]; ok {
				conn.Close()
				delete(conns, id)
			}
			return
		}
	}
}

func writeErr(buf *C.char, bufLen C.int, msg string) {
	if buf == nil || bufLen <= 0 {
		return
	}
	b := unsafe.Slice((*byte)(unsafe.Pointer(buf)), int(bufLen))
	n := copy(b, msg)
	if n < int(bufLen) {
		b[n] = 0
	}
}

func main() {}
GOEOF

echo "Resolving dependencies..."
go mod tidy

# Build for iOS device (arm64)
echo "Building for iphoneos-arm64..."
CGO_ENABLED=1 \
GOOS=ios \
GOARCH=arm64 \
CC="$(xcrun -sdk iphoneos -find clang)" \
CGO_CFLAGS="-isysroot $(xcrun -sdk iphoneos --show-sdk-path) -arch arm64 -mios-version-min=17.0" \
CGO_LDFLAGS="-isysroot $(xcrun -sdk iphoneos --show-sdk-path) -arch arm64 -mios-version-min=17.0" \
go build -buildmode=c-archive -o "$BUILD_DIR/iphoneos-arm64/libmuxits.a" .

# Build for iOS simulator (arm64)
echo "Building for iphonesimulator-arm64..."
CGO_ENABLED=1 \
GOOS=ios \
GOARCH=arm64 \
CC="$(xcrun -sdk iphonesimulator -find clang)" \
CGO_CFLAGS="-isysroot $(xcrun -sdk iphonesimulator --show-sdk-path) -arch arm64 -mios-version-min=17.0 -target arm64-apple-ios17.0-simulator" \
CGO_LDFLAGS="-isysroot $(xcrun -sdk iphonesimulator --show-sdk-path) -arch arm64 -mios-version-min=17.0 -target arm64-apple-ios17.0-simulator" \
go build -buildmode=c-archive -o "$BUILD_DIR/iphonesimulator-arm64/libmuxits.a" .

# Create xcframework
echo "Creating xcframework..."
rm -rf "$OUTPUT_DIR/libmuxits.xcframework"
xcodebuild -create-xcframework \
    -library "$BUILD_DIR/iphoneos-arm64/libmuxits.a" \
    -headers "$BUILD_DIR/iphoneos-arm64/" \
    -library "$BUILD_DIR/iphonesimulator-arm64/libmuxits.a" \
    -headers "$BUILD_DIR/iphonesimulator-arm64/" \
    -output "$OUTPUT_DIR/libmuxits.xcframework"

echo "=== libtailscale build complete ==="
echo "Output: $OUTPUT_DIR/libmuxits.xcframework/"
