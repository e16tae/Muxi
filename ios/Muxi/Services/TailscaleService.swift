import Foundation
import os

// MARK: - TailscaleError

enum TailscaleError: Error, Equatable, LocalizedError {
    case notConnected
    case dialFailed(String)
    case startFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            "Tailscale에 먼저 연결하세요"
        case .dialFailed(let msg):
            "Tailscale 연결 실패: \(msg)"
        case .startFailed(let msg):
            "Tailscale 시작 실패: \(msg)"
        }
    }
}

// MARK: - TailscaleState

enum TailscaleState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case error(String)
}

// MARK: - TailscaleService

/// Manages an embedded Tailscale node via the muxits C API (tsnet wrapper).
///
/// Uses tsnet userspace networking — does NOT consume the system VPN slot.
/// The `dial()` method returns a file descriptor that can be passed directly
/// to `libssh2_session_handshake()`.
///
/// **fd ownership:** TailscaleService owns all fds returned by `dial()`.
/// Callers must NOT call `close()` on them.
actor TailscaleService {
    private let logger = Logger(subsystem: "com.muxi.app", category: "TailscaleService")

    private(set) var state: TailscaleState = .disconnected

    /// File descriptors created by dial(), tracked for cleanup.
    private var activeFDs: Set<Int32> = []

    /// Persistent state directory for WireGuard keys and node identity.
    private var stateDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("tailscale", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDir = dir
        try? mutableDir.setResourceValues(values)
        return dir
    }

    // MARK: - Error buffer helper

    private static let errBufSize = 1024

    private func callWithError(_ body: (UnsafeMutablePointer<CChar>, Int32) -> Int32) throws -> Int32 {
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: Self.errBufSize)
        defer { buf.deallocate() }
        buf[0] = 0

        let rc = body(buf, Int32(Self.errBufSize))
        if rc < 0 {
            let msg = String(cString: buf)
            throw TailscaleError.startFailed(msg.isEmpty ? "unknown error" : msg)
        }
        return rc
    }

    // MARK: - Lifecycle

    /// Start the Tailscale node and connect to the Headscale control server.
    func start(controlURL: String, authKey: String, hostname: String) async throws {
        guard state == .disconnected || isErrorState else {
            logger.warning("start() called in state \(String(describing: self.state))")
            return
        }

        state = .connecting
        logger.info("Starting Tailscale node, control=\(controlURL) hostname=\(hostname)")

        let dir = stateDir.path
        let urlCopy = controlURL
        let keyCopy = authKey
        let hostCopy = hostname

        // Run blocking C call off the actor's executor
        let startResult: Result<Void, Error> = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let buf = UnsafeMutablePointer<CChar>.allocate(capacity: Self.errBufSize)
                defer { buf.deallocate() }
                buf[0] = 0

                let rc = urlCopy.withCString { urlPtr in
                    keyCopy.withCString { keyPtr in
                        hostCopy.withCString { hostPtr in
                            dir.withCString { dirPtr in
                                muxits_start(
                                    UnsafeMutablePointer(mutating: urlPtr),
                                    UnsafeMutablePointer(mutating: keyPtr),
                                    UnsafeMutablePointer(mutating: hostPtr),
                                    UnsafeMutablePointer(mutating: dirPtr),
                                    buf,
                                    Int32(Self.errBufSize)
                                )
                            }
                        }
                    }
                }

                if rc < 0 {
                    let msg = String(cString: buf)
                    continuation.resume(returning: .failure(TailscaleError.startFailed(msg.isEmpty ? "unknown error" : msg)))
                } else {
                    continuation.resume(returning: .success(()))
                }
            }
        }

        do {
            try startResult.get()
            state = .connected
            logger.info("Tailscale connected")
        } catch {
            state = .error(error.localizedDescription)
            throw error
        }
    }

    /// Stop the Tailscale node and clean up resources.
    func stop() {
        logger.info("Stopping Tailscale node")

        for fd in activeFDs {
            muxits_close_conn(fd)
        }
        activeFDs.removeAll()

        muxits_stop()
        state = .disconnected
    }

    // MARK: - Dial

    /// Connect to a Tailscale peer via a local TCP proxy.
    ///
    /// Returns a local TCP port on 127.0.0.1. The caller should connect to
    /// `127.0.0.1:localPort` using a normal TCP socket — the proxy forwards
    /// all traffic through the Tailscale tunnel.
    func dial(host: String, port: UInt16) async throws -> UInt16 {
        guard state == .connected else {
            throw TailscaleError.notConnected
        }

        logger.info("Dialing \(host):\(port) via Tailscale (local proxy)")

        // Run blocking C call off the actor's executor
        let hostCopy = host
        let portCopy = Int32(port)
        let result: Result<UInt16, TailscaleError> = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let buf = UnsafeMutablePointer<CChar>.allocate(capacity: Self.errBufSize)
                defer { buf.deallocate() }
                buf[0] = 0

                let localPort = hostCopy.withCString { hostPtr in
                    muxits_dial(
                        UnsafeMutablePointer(mutating: hostPtr),
                        portCopy,
                        buf,
                        Int32(Self.errBufSize)
                    )
                }

                if localPort < 0 {
                    let msg = String(cString: buf)
                    continuation.resume(returning: .failure(.dialFailed(msg.isEmpty ? "unknown error" : msg)))
                } else {
                    continuation.resume(returning: .success(UInt16(localPort)))
                }
            }
        }

        let localPort = try result.get()
        logger.info("Tailscale local proxy on port \(localPort)")
        return localPort
    }

    // MARK: - Helpers

    private var isErrorState: Bool {
        if case .error = state { return true }
        return false
    }
}
