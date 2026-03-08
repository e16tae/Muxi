import Foundation
import CLibSSH2
import os

private let sshLog = Logger(subsystem: "com.muxi.app", category: "SSH")

/// libssh2 error code for EAGAIN (would-block in non-blocking mode)
private let kLibSSH2ErrorEAGAIN: Int = -37

/// libssh2 error code for operation timeout
private let kLibSSH2ErrorTimeout: Int32 = -14

// MARK: - SSHConnectionState

/// Represents the current state of an SSH connection.
enum SSHConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case error(String)
}

// MARK: - SSHAuth

/// Authentication credentials for establishing an SSH connection.
/// Unlike ``AuthMethod``, which stores *what kind* of auth to use,
/// ``SSHAuth`` carries the actual secret material needed at connect time.
enum SSHAuth: Sendable {
    case password(String)
    case key(privateKey: Data, passphrase: String?)
}

extension SSHAuth: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String {
        switch self {
        case .password: return "SSHAuth.password(****)"
        case .key: return "SSHAuth.key(****)"
        }
    }
    var debugDescription: String { description }
}

// MARK: - SSHError

/// Errors that can occur during SSH operations.
enum SSHError: Error, LocalizedError, Sendable {
    case notConnected
    case authenticationFailed
    case connectionFailed(String)
    case channelError(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to a server"
        case .authenticationFailed:
            return "Authentication failed"
        case .connectionFailed(let detail):
            return "Connection failed: \(detail)"
        case .channelError(let detail):
            return "Channel error: \(detail)"
        case .timeout:
            return "Connection timed out"
        }
    }
}

// MARK: - SSHChannel

/// A bidirectional channel over an SSH connection (e.g. a shell or exec
/// channel).  Consumers write input data and receive output via the
/// ``SSHServiceProtocol/startShell(onData:)`` callback.
protocol SSHChannel: AnyObject {
    /// Send data to the remote side of the channel.
    func write(_ data: Data) throws

    /// Close the channel and release resources.
    func close()

    /// Notify the remote side of a terminal size change.
    func resize(cols: Int, rows: Int) throws
}

// MARK: - SSHServiceProtocol

/// Defines the interface for SSH connectivity used throughout Muxi.
///
/// The real implementation will wrap libssh2; tests and previews can
/// substitute ``MockSSHService`` or other conforming types.
protocol SSHServiceProtocol: AnyObject {
    /// The current connection state.
    var state: SSHConnectionState { get }

    /// Open an SSH connection to the given host.
    func connect(host: String, port: UInt16, username: String, auth: SSHAuth) async throws

    /// Tear down the current connection.
    func disconnect()

    /// Execute a single command and return its standard output.
    func execCommand(_ command: String) async throws -> String

    /// Open an interactive shell channel.
    ///
    /// - Parameter onData: Called on the service's internal queue whenever
    ///   the remote side produces output.
    /// - Returns: An ``SSHChannel`` that the caller uses to send input and
    ///   resize events.
    func startShell(onData: @escaping (Data) -> Void) async throws -> SSHChannel

    /// Write data to the active shell channel, serialized on the actor.
    ///
    /// This is the thread-safe alternative to calling `SSHChannel.write()`
    /// directly from a different isolation context. All channel I/O goes
    /// through the actor to avoid concurrent libssh2 access.
    func writeToChannel(_ data: Data) async throws
}

// MARK: - LibSSH2Channel

/// Wraps a libssh2 channel pointer (`LIBSSH2_CHANNEL*`) and exposes it
/// through the ``SSHChannel`` protocol.
///
/// This is a plain class (not an actor) -- it is designed to be called from
/// the ``SSHService`` actor's isolation context.  The `write`, `close`, and
/// `resize` methods call blocking libssh2 functions and must not be used
/// from the main thread.
final class LibSSH2Channel: SSHChannel {
    private let channelPtr: OpaquePointer
    private let socketFd: Int32
    private var isClosed = false

    init(channel: OpaquePointer, socketFd: Int32) {
        self.channelPtr = channel
        self.socketFd = socketFd
    }

    func write(_ data: Data) throws {
        guard !isClosed else {
            throw SSHError.channelError("Channel is closed")
        }
        try data.withUnsafeBytes { rawBuffer in
            guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(
                to: CChar.self
            ) else { return }
            let count = rawBuffer.count
            var totalWritten = 0
            while totalWritten < count {
                let rc = libssh2_channel_write_ex(
                    channelPtr, 0,
                    ptr.advanced(by: totalWritten),
                    count - totalWritten
                )
                if rc == kLibSSH2ErrorEAGAIN {
                    // Wait for socket to become writable instead of busy-spinning
                    var pollFd = pollfd(fd: socketFd, events: Int16(POLLOUT), revents: 0)
                    poll(&pollFd, 1, 100)  // Wait up to 100ms for writable
                    continue
                }
                if rc < 0 {
                    throw SSHError.channelError(
                        "Channel write failed (rc=\(rc))"
                    )
                }
                totalWritten += Int(rc)
            }
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        libssh2_channel_close(channelPtr)
        libssh2_channel_wait_closed(channelPtr)
        libssh2_channel_free(channelPtr)
    }

    func resize(cols: Int, rows: Int) throws {
        guard !isClosed else {
            throw SSHError.channelError("Channel is closed")
        }
        let rc = libssh2_channel_request_pty_size_ex(
            channelPtr,
            Int32(cols),
            Int32(rows),
            0,
            0
        )
        if rc != 0 {
            throw SSHError.channelError(
                "PTY resize failed (rc=\(rc))"
            )
        }
    }

    deinit {
        close()
    }
}

// MARK: - SSHService

/// Real libssh2-backed implementation of ``SSHServiceProtocol``.
///
/// Uses an actor to serialize all SSH operations onto a single executor,
/// which prevents concurrent access to the underlying C pointers. Networking
/// runs off the main thread; the ``state`` property is protected by an
/// `OSAllocatedUnfairLock` so it can be read safely from any isolation context.
actor SSHService: SSHServiceProtocol {

    /// Thread-safe backing storage for the connection state.
    private let _state = OSAllocatedUnfairLock(initialState: SSHConnectionState.disconnected)

    /// Current connection state, readable from any isolation context.
    nonisolated var state: SSHConnectionState {
        _state.withLock { $0 }
    }

    /// Update the connection state in a thread-safe manner.
    private func updateState(_ newState: SSHConnectionState) {
        _state.withLock { $0 = newState }
    }

    /// Whether libssh2 global initialization succeeded.
    private var libssh2Initialized = false

    /// The libssh2 session handle (`LIBSSH2_SESSION*`).
    private var session: OpaquePointer?

    /// The POSIX socket file descriptor backing the connection.
    private var socketFd: Int32 = -1

    /// Background task that reads from the shell channel and delivers data
    /// via the `onData` callback.
    private var readTask: Task<Void, Never>?

    /// Timeout applied to socket send/receive and libssh2 session operations.
    private let connectionTimeout: TimeInterval

    init(connectionTimeout: TimeInterval = 30) {
        self.connectionTimeout = connectionTimeout
        let rc = libssh2_init(0)
        libssh2Initialized = (rc == 0)
    }

    deinit {
        if libssh2Initialized {
            libssh2_exit()
        }
    }

    // MARK: - Connect

    func connect(
        host: String,
        port: UInt16,
        username: String,
        auth: SSHAuth
    ) async throws {
        // Clean up any previous connection first.
        if state != .disconnected {
            await performDisconnect()
        }

        updateState(.connecting)
        sshLog.info("Connecting to \(host):\(port) as \(username)")

        do {
            guard libssh2Initialized else {
                sshLog.error("libssh2 not initialized")
                throw SSHError.connectionFailed("libssh2 initialization failed")
            }

            // Resolve the host first so we know the address family.
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC  // Support both IPv4 and IPv6
            hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            let portString = String(port)
            let gaiRc = getaddrinfo(host, portString, &hints, &result)
            guard gaiRc == 0, let addrInfo = result else {
                let errorMsg = gaiRc != 0
                    ? String(cString: gai_strerror(gaiRc))
                    : "No address found"
                throw SSHError.connectionFailed(
                    "Host resolution failed: \(errorMsg)"
                )
            }
            defer { freeaddrinfo(result) }

            // Create a TCP socket matching the resolved address family.
            let fd = socket(addrInfo.pointee.ai_family, SOCK_STREAM, 0)
            guard fd >= 0 else {
                throw SSHError.connectionFailed("Failed to create socket")
            }
            socketFd = fd

            // Apply socket-level timeouts so read/write don't block
            // indefinitely on stalled networks.
            // Note: SO_SNDTIMEO/SO_RCVTIMEO do NOT bound the connect() syscall
            // on Darwin — TCP SYN timeout is kernel-controlled (~75s). The
            // libssh2 session timeout (below) covers handshake/auth phases.
            let wholeSeconds = Int(connectionTimeout)
            let microseconds = Int32((connectionTimeout - Double(wholeSeconds)) * 1_000_000)
            var timeout = timeval(tv_sec: wholeSeconds, tv_usec: microseconds)
            if setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) != 0 {
                // Non-fatal: proceed without send timeout
            }
            if setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) != 0 {
                // Non-fatal: proceed without receive timeout
            }

            // Connect the socket.
            let connectRc = Darwin.connect(
                fd, addrInfo.pointee.ai_addr, addrInfo.pointee.ai_addrlen
            )
            guard connectRc == 0 else {
                Darwin.close(fd)
                socketFd = -1
                throw SSHError.connectionFailed(
                    "Socket connect failed (errno=\(errno))"
                )
            }

            // Create and configure the libssh2 session.
            guard let sess = libssh2_session_init_ex(nil, nil, nil, nil) else {
                Darwin.close(fd)
                socketFd = -1
                throw SSHError.connectionFailed(
                    "libssh2_session_init failed"
                )
            }
            session = sess

            // Apply a session-level timeout (in milliseconds) so that
            // libssh2 blocking operations (handshake, auth) respect the
            // configured limit. This timeout is inactive in non-blocking mode
            // (the shell read loop), where the caller's own poll loop controls
            // timing.
            libssh2_session_set_timeout(sess, Int(connectionTimeout * 1000))

            // Blocking mode for the handshake and authentication.
            libssh2_session_set_blocking(sess, 1)

            let hsRc = libssh2_session_handshake(sess, fd)
            guard hsRc == 0 else {
                let msg = lastSessionError(sess)
                cleanupSession()
                if hsRc == kLibSSH2ErrorTimeout {
                    throw SSHError.timeout
                }
                throw SSHError.connectionFailed(
                    "SSH handshake failed: \(msg)"
                )
            }

            // Authenticate.
            try authenticate(session: sess, username: username, auth: auth)

            updateState(.connected)
            sshLog.info("SSH connected successfully")
        } catch {
            sshLog.error("SSH connection error: \(error)")
            updateState(.error(error.localizedDescription))
            throw error
        }
    }

    // MARK: - Disconnect

    /// Tear down the SSH connection and reset state.
    ///
    /// Marked `nonisolated` because ``SSHServiceProtocol`` declares
    /// `disconnect()` as synchronous (non-async).  The actual cleanup
    /// is dispatched onto the actor's executor via an unstructured task
    /// so that it is serialized with other actor operations.
    nonisolated func disconnect() {
        Task { await performDisconnect() }
    }

    /// Actor-isolated disconnect logic.
    private func performDisconnect() async {
        readTask?.cancel()
        await readTask?.value  // Wait for read loop to exit
        readTask = nil
        activeShellChannel = nil
        cleanupSession()
        updateState(.disconnected)
    }

    // MARK: - Execute Command

    func execCommand(_ command: String) async throws -> String {
        guard state == .connected, let sess = session else {
            throw SSHError.notConnected
        }

        // Open a channel for command execution.
        guard let channel = libssh2_channel_open_ex(
            sess, "session", 7,
            UInt32(2 * 1024 * 1024),  // LIBSSH2_CHANNEL_WINDOW_DEFAULT
            UInt32(32768),  // LIBSSH2_CHANNEL_PACKET_DEFAULT
            nil, 0
        ) else {
            throw SSHError.channelError(
                "Failed to open channel: \(lastSessionError(sess))"
            )
        }

        // Run the command on the channel.
        let runRc = command.withCString { cmdPtr in
            libssh2_channel_process_startup(
                channel, "exec", 4, cmdPtr, UInt32(command.utf8.count)
            )
        }
        guard runRc == 0 else {
            libssh2_channel_free(channel)
            throw SSHError.channelError(
                "Command execution failed: \(lastSessionError(sess))"
            )
        }

        // Read all stdout into a buffer.
        var output = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while true {
            let bytesRead = libssh2_channel_read_ex(
                channel, 0, buffer, bufferSize
            )
            if bytesRead > 0 {
                buffer.withMemoryRebound(to: UInt8.self, capacity: Int(bytesRead)) { ptr in
                    output.append(ptr, count: Int(bytesRead))
                }
            } else if bytesRead == 0 {
                if libssh2_channel_eof(channel) != 0 {
                    break
                }
                // Avoid tight spin — yield briefly when no data and no EOF
                try? await Task.sleep(for: .milliseconds(10))
            } else if bytesRead < 0 {
                libssh2_channel_close(channel)
                libssh2_channel_wait_closed(channel)
                libssh2_channel_free(channel)
                throw SSHError.channelError("Read failed: \(lastSessionError(sess))")
            }
        }

        // Clean up the channel.
        libssh2_channel_close(channel)
        libssh2_channel_wait_closed(channel)
        libssh2_channel_free(channel)

        return String(data: output, encoding: .utf8) ?? ""
    }

    // MARK: - Start Shell

    func startShell(
        onData: @escaping (Data) -> Void
    ) async throws -> SSHChannel {
        guard state == .connected, let sess = session else {
            throw SSHError.notConnected
        }

        // Open a session channel for the interactive shell.
        guard let channel = libssh2_channel_open_ex(
            sess, "session", 7,
            UInt32(2 * 1024 * 1024),  // LIBSSH2_CHANNEL_WINDOW_DEFAULT
            UInt32(32768),  // LIBSSH2_CHANNEL_PACKET_DEFAULT
            nil, 0
        ) else {
            throw SSHError.channelError(
                "Failed to open shell channel: \(lastSessionError(sess))"
            )
        }

        // Request a pseudo-terminal.
        let ptyRc = libssh2_channel_request_pty_ex(
            channel,
            "xterm-256color", 14,
            nil, 0,
            80, 24,   // LIBSSH2_TERM_WIDTH, LIBSSH2_TERM_HEIGHT
            0, 0      // LIBSSH2_TERM_WIDTH_PX, LIBSSH2_TERM_HEIGHT_PX
        )
        guard ptyRc == 0 else {
            libssh2_channel_free(channel)
            throw SSHError.channelError(
                "PTY request failed: \(lastSessionError(sess))"
            )
        }

        // Start the default shell.
        let shellRc = libssh2_channel_process_startup(
            channel, "shell", 5, nil, 0
        )
        guard shellRc == 0 else {
            libssh2_channel_free(channel)
            throw SSHError.channelError(
                "Shell start failed: \(lastSessionError(sess))"
            )
        }

        // Switch to non-blocking mode for the read loop so we can yield
        // back to the Swift concurrency runtime between reads.
        libssh2_session_set_blocking(sess, 0)

        let fd = self.socketFd
        let sshChannel = LibSSH2Channel(channel: channel, socketFd: fd)

        // Background task: continuously read from the channel and deliver
        // data to the caller's callback.
        let bufferSize = 8192
        readTask = Task { [weak self] in
            let buf = UnsafeMutablePointer<CChar>.allocate(
                capacity: bufferSize
            )
            defer { buf.deallocate() }

            while !Task.isCancelled {
                let bytesRead = libssh2_channel_read_ex(
                    channel, 0, buf, bufferSize
                )
                if bytesRead > 0 {
                    let data = Data(bytes: buf, count: Int(bytesRead))
                    onData(data)
                } else if bytesRead == kLibSSH2ErrorEAGAIN {
                    // Wait for socket to become readable instead of fixed sleep.
                    var pollFd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    poll(&pollFd, 1, 50)  // Returns immediately when data arrives, up to 50ms
                    if Task.isCancelled { break }
                } else if bytesRead == 0
                            && libssh2_channel_eof(channel) != 0 {
                    // Remote side closed the channel.
                    break
                } else if bytesRead < 0 {
                    // A real error occurred -- stop reading.
                    break
                } else {
                    // bytesRead == 0 but no EOF -- wait for readable data.
                    var pollFd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    poll(&pollFd, 1, 50)  // Returns immediately when data arrives, up to 50ms
                    if Task.isCancelled { break }
                }

                // Yield to the actor's executor so queued messages (e.g.
                // writeToChannel) can be processed between read iterations.
                // Without this, the synchronous C calls above would
                // monopolize the actor and starve pending writes.
                await Task.yield()
            }

            // Restore blocking mode so subsequent cleanup calls succeed.
            if let self = self {
                let sess = await self.session
                if let sess {
                    libssh2_session_set_blocking(sess, 1)
                }
                // Signal that the connection dropped so observers can
                // trigger reconnection (but not on intentional cancel).
                if !Task.isCancelled {
                    await self.updateState(.disconnected)
                }
            }
        }

        self.activeShellChannel = sshChannel
        return sshChannel
    }

    // MARK: - Channel Write (Actor-Isolated)

    /// The currently active shell channel, stored on the actor for thread-safe writes.
    private var activeShellChannel: LibSSH2Channel?

    func writeToChannel(_ data: Data) async throws {
        guard let channel = activeShellChannel else {
            throw SSHError.notConnected
        }
        try channel.write(data)
    }

    // MARK: - Private Helpers

    /// Authenticate with the remote server using the provided credentials.
    private func authenticate(
        session sess: OpaquePointer,
        username: String,
        auth: SSHAuth
    ) throws {
        switch auth {
        case .password(let password):
            let rc = username.withCString { userPtr in
                password.withCString { passPtr in
                    libssh2_userauth_password_ex(
                        sess,
                        userPtr, UInt32(username.utf8.count),
                        passPtr, UInt32(password.utf8.count),
                        nil
                    )
                }
            }
            guard rc == 0 else {
                cleanupSession()
                throw SSHError.authenticationFailed
            }

        case .key(let privateKey, let passphrase):
            let rc = privateKey.withUnsafeBytes { keyBuffer -> Int32 in
                guard let keyPtr = keyBuffer.baseAddress?
                    .assumingMemoryBound(to: CChar.self) else {
                    return -1
                }
                let keyLen = keyBuffer.count
                return username.withCString { userPtr in
                    if let passphrase {
                        return passphrase.withCString { ppPtr in
                            libssh2_userauth_publickey_frommemory(
                                sess,
                                userPtr, username.utf8.count,
                                nil, 0,
                                keyPtr, keyLen,
                                ppPtr
                            )
                        }
                    } else {
                        return libssh2_userauth_publickey_frommemory(
                            sess,
                            userPtr, username.utf8.count,
                            nil, 0,
                            keyPtr, keyLen,
                            nil
                        )
                    }
                }
            }
            guard rc == 0 else {
                cleanupSession()
                throw SSHError.authenticationFailed
            }
        }
    }

    /// Extract the last error message from a libssh2 session.
    private func lastSessionError(_ sess: OpaquePointer) -> String {
        var msgPtr: UnsafeMutablePointer<CChar>?
        var msgLen: Int32 = 0
        libssh2_session_last_error(sess, &msgPtr, &msgLen, 0)
        if let msgPtr, msgLen > 0 {
            return String(cString: msgPtr)
        }
        return "Unknown error"
    }

    /// Tear down the libssh2 session and close the socket.
    private func cleanupSession() {
        if let sess = session {
            libssh2_session_disconnect_ex(
                sess,
                11,  // SSH_DISCONNECT_BY_APPLICATION
                "Bye", ""
            )
            libssh2_session_free(sess)
            session = nil
        }
        if socketFd >= 0 {
            Darwin.close(socketFd)
            socketFd = -1
        }
    }
}
