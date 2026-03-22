import Foundation
import SwiftData

// MARK: - AuthMethod

/// Describes how the user authenticates with the remote server.
/// The actual secret (password or private key) lives in the Keychain,
/// referenced by the server's ``Server/id`` or the key's ``SSHKey/id``.
enum AuthMethod: Codable, Equatable, Sendable {
    /// Password authentication. The password is stored in the Keychain
    /// keyed by the owning ``Server/id``.
    case password

    /// Public-key authentication. The private key is stored in the
    /// Keychain keyed by the associated ``SSHKey/id``.
    case key(keyId: UUID)
}

// MARK: - KeyType

/// The cryptographic algorithm used by an SSH key pair.
enum KeyType: String, Codable, Sendable {
    case ed25519
    case rsa
}

// MARK: - SSHKey

/// Lightweight metadata about an SSH key pair.
/// The actual private key material is stored in the Keychain,
/// referenced by ``id``.
struct SSHKey: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var type: KeyType
}

// MARK: - Server

/// A saved SSH server connection profile persisted with SwiftData.
@Model
final class Server {
    @Attribute(.unique) var id: UUID
    var name: String
    var host: String
    var port: UInt16
    var username: String
    var authMethod: AuthMethod
    var agentForwarding: Bool

    /// The SHA-256 fingerprint of the server's host key, in OpenSSH format
    /// (e.g., `"SHA256:xyzabc123..."`).
    ///
    /// `nil` means this is a first connection and TOFU verification is needed.
    /// Stored in SwiftData (not a secret — safe for model storage).
    var hostKeyFingerprint: String?

    /// The Tailscale node ID of the device to connect through.
    /// `nil` means this is a direct SSH connection (no Tailscale).
    var tailscaleDeviceID: String?

    /// Human-readable Tailscale device name (e.g., "my-server").
    var tailscaleDeviceName: String?

    /// Whether this server connects through Tailscale.
    var isTailscale: Bool { tailscaleDeviceID != nil }

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: UInt16 = 22,
        username: String,
        authMethod: AuthMethod,
        agentForwarding: Bool = false,
        hostKeyFingerprint: String? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.agentForwarding = agentForwarding
        self.hostKeyFingerprint = hostKeyFingerprint
    }
}
