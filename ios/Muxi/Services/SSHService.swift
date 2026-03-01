import Foundation

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

// MARK: - SSHError

/// Errors that can occur during SSH operations.
enum SSHError: Error, Sendable {
    case notConnected
    case authenticationFailed
    case connectionFailed(String)
    case channelError(String)
    case timeout
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
}

// MARK: - SSHService (stub)

/// Stub implementation of ``SSHServiceProtocol``.
///
/// State transitions are performed so that callers can observe the expected
/// lifecycle, but no real networking occurs.  The actual libssh2 integration
/// will replace the body of each method.
///
/// - Note: Marked `@MainActor` so all state mutations are safe to observe.
///   When the real libssh2 implementation is written, consider converting to
///   a dedicated `actor` with off-main-thread networking.
@MainActor
final class SSHService: @preconcurrency SSHServiceProtocol {
    private(set) var state: SSHConnectionState = .disconnected

    func connect(host: String, port: UInt16, username: String, auth: SSHAuth) async throws {
        state = .connecting
        // TODO: libssh2 connection
        state = .connected
    }

    func disconnect() {
        // TODO: libssh2 disconnect
        state = .disconnected
    }

    func execCommand(_ command: String) async throws -> String {
        guard state == .connected else { throw SSHError.notConnected }
        // TODO: libssh2 exec channel
        return ""
    }

    func startShell(onData: @escaping (Data) -> Void) async throws -> SSHChannel {
        guard state == .connected else { throw SSHError.notConnected }
        // TODO: libssh2 shell channel
        throw SSHError.channelError("Shell not yet implemented")
    }
}
