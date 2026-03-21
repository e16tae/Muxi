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

/// Manages an embedded Tailscale node via the libtailscale C API.
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

    /// Opaque handle to the libtailscale server instance.
    private var tsHandle: Int32 = -1

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

    // MARK: - Lifecycle

    /// Start the Tailscale node and connect to the Headscale control server.
    func start(controlURL: String, authKey: String, hostname: String) async throws {
        guard state == .disconnected || isErrorState else {
            logger.warning("start() called in state \(String(describing: self.state))")
            return
        }

        state = .connecting
        logger.info("Starting Tailscale node, control=\(controlURL) hostname=\(hostname)")

        // TODO: Replace with actual libtailscale C API calls when framework is built:
        //   tsHandle = tailscale_new()
        //   tailscale_set_dir(tsHandle, stateDir.path)
        //   tailscale_set_hostname(tsHandle, hostname)
        //   tailscale_set_authkey(tsHandle, authKey)
        //   tailscale_set_control_url(tsHandle, controlURL)
        //   let rc = tailscale_up(tsHandle)
        //   if rc != 0 { throw TailscaleError.startFailed(errMsg) }

        state = .error("libtailscale framework not yet linked")
        throw TailscaleError.startFailed("libtailscale framework not yet linked")
    }

    /// Stop the Tailscale node and clean up resources.
    func stop() {
        logger.info("Stopping Tailscale node")

        for fd in activeFDs {
            Darwin.close(fd)
        }
        activeFDs.removeAll()

        // TODO: Replace with actual libtailscale C API calls:
        //   if tsHandle >= 0 {
        //       tailscale_close(tsHandle)
        //       tsHandle = -1
        //   }

        tsHandle = -1
        state = .disconnected
    }

    // MARK: - Dial

    /// Connect to a Tailscale peer and return a file descriptor.
    func dial(host: String, port: UInt16) async throws -> Int32 {
        guard state == .connected else {
            throw TailscaleError.notConnected
        }

        logger.info("Dialing \(host):\(port) via Tailscale")

        // TODO: Replace with actual libtailscale C API call:
        //   var conn: Int32 = -1
        //   let rc = tailscale_dial(tsHandle, "tcp", "\(host):\(port)", &conn)
        //   if rc != 0 { throw TailscaleError.dialFailed(errMsg) }
        //   activeFDs.insert(conn)
        //   return conn

        throw TailscaleError.dialFailed("libtailscale framework not yet linked")
    }

    /// Release a specific fd from tracking (called when SSH disconnects cleanly).
    func releaseFD(_ fd: Int32) {
        activeFDs.remove(fd)
    }

    // MARK: - Helpers

    private var isErrorState: Bool {
        if case .error = state { return true }
        return false
    }
}
