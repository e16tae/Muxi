import Foundation
import UIKit

// MARK: - TailscaleProvider

enum TailscaleProvider: String, Codable, Sendable {
    case official
    case headscale
}

// MARK: - TailscaleAccount

struct TailscaleAccount: Sendable {
    let provider: TailscaleProvider
    let controlURL: String
    let hostname: String
    var isRegistered: Bool
    var lastConnected: Bool
}

// MARK: - TailscaleAccountManager

/// Manages Tailscale account configuration for both official Tailscale (OAuth)
/// and self-hosted Headscale (pre-auth key) providers.
///
/// Non-secret config is stored in UserDefaults; secrets (tokens, keys) go to
/// Keychain via ``KeychainService``.
@MainActor @Observable
final class TailscaleAccountManager {

    // MARK: - Storage Keys

    private static let providerKey = "tailscale.provider"
    private static let controlURLKey = "tailscale.controlURL"
    private static let hostnameKey = "tailscale.hostname"
    private static let isRegisteredKey = "tailscale.isRegistered"
    private static let lastConnectedKey = "tailscale.lastConnected"

    // Keychain accounts
    private static let accessTokenAccount = "tailscale.accessToken"
    private static let refreshTokenAccount = "tailscale.refreshToken"
    private static let preAuthKeyAccount = "tailscale.preAuthKey"
    private static let apiKeyAccount = "tailscale.apiKey"

    // MARK: - Dependencies

    private let defaults: UserDefaults
    private let keychainService: KeychainService

    // MARK: - Observable State

    private(set) var provider: TailscaleProvider?
    private(set) var controlURL: String = ""
    private(set) var hostname: String = ""
    private(set) var isRegistered: Bool = false

    var lastConnected: Bool {
        didSet { defaults.set(lastConnected, forKey: Self.lastConnectedKey) }
    }

    // MARK: - Computed Properties

    var isConfigured: Bool {
        guard let provider else { return false }
        switch provider {
        case .official:
            return (try? keychainService.retrievePassword(account: Self.accessTokenAccount)) != nil
        case .headscale:
            return !controlURL.isEmpty && isRegistered
        }
    }

    var account: TailscaleAccount? {
        guard let provider else { return nil }
        return TailscaleAccount(
            provider: provider,
            controlURL: controlURL,
            hostname: hostname,
            isRegistered: isRegistered,
            lastConnected: lastConnected
        )
    }

    // MARK: - Init

    init(defaults: UserDefaults = .standard, keychainService: KeychainService = KeychainService()) {
        self.defaults = defaults
        self.keychainService = keychainService
        self.lastConnected = defaults.bool(forKey: Self.lastConnectedKey)
        loadFromStorage()
    }

    // MARK: - Configuration

    /// Configure a Headscale (self-hosted) account.
    ///
    /// The account is **not** considered configured until ``markRegistered()``
    /// is called after the tsnet node successfully registers with the control
    /// server.
    func configureHeadscale(controlURL: String, preAuthKey: String, apiKey: String, hostname: String) {
        provider = .headscale
        self.controlURL = controlURL
        self.hostname = hostname
        isRegistered = false

        defaults.set(TailscaleProvider.headscale.rawValue, forKey: Self.providerKey)
        defaults.set(controlURL, forKey: Self.controlURLKey)
        defaults.set(hostname, forKey: Self.hostnameKey)
        defaults.set(false, forKey: Self.isRegisteredKey)

        try? keychainService.savePassword(preAuthKey, account: Self.preAuthKeyAccount)
        try? keychainService.savePassword(apiKey, account: Self.apiKeyAccount)
    }

    /// Configure an official Tailscale account with OAuth tokens.
    ///
    /// Official accounts are considered configured immediately since the
    /// tokens are obtained after successful authentication.
    func configureOfficial(accessToken: String, refreshToken: String, hostname: String) {
        provider = .official
        self.controlURL = "https://controlplane.tailscale.com"
        self.hostname = hostname
        isRegistered = true

        defaults.set(TailscaleProvider.official.rawValue, forKey: Self.providerKey)
        defaults.set(controlURL, forKey: Self.controlURLKey)
        defaults.set(hostname, forKey: Self.hostnameKey)
        defaults.set(true, forKey: Self.isRegisteredKey)

        try? keychainService.savePassword(accessToken, account: Self.accessTokenAccount)
        try? keychainService.savePassword(refreshToken, account: Self.refreshTokenAccount)
    }

    /// Mark the current Headscale account as successfully registered.
    ///
    /// After registration completes, the pre-auth key is deleted from Keychain
    /// since it is no longer needed.
    func markRegistered() {
        isRegistered = true
        defaults.set(true, forKey: Self.isRegisteredKey)
        try? keychainService.deletePassword(account: Self.preAuthKeyAccount)
    }

    // MARK: - Secret Accessors

    func preAuthKey() -> String? {
        try? keychainService.retrievePassword(account: Self.preAuthKeyAccount)
    }

    func accessToken() -> String? {
        try? keychainService.retrievePassword(account: Self.accessTokenAccount)
    }

    func apiKey() -> String? {
        try? keychainService.retrievePassword(account: Self.apiKeyAccount)
    }

    // MARK: - Sign Out

    /// Clear all Tailscale account state (UserDefaults + Keychain).
    func signOut() {
        provider = nil
        controlURL = ""
        hostname = Self.defaultHostname()
        isRegistered = false
        lastConnected = false

        defaults.removeObject(forKey: Self.providerKey)
        defaults.removeObject(forKey: Self.controlURLKey)
        defaults.removeObject(forKey: Self.hostnameKey)
        defaults.removeObject(forKey: Self.isRegisteredKey)
        defaults.removeObject(forKey: Self.lastConnectedKey)

        try? keychainService.deletePassword(account: Self.accessTokenAccount)
        try? keychainService.deletePassword(account: Self.refreshTokenAccount)
        try? keychainService.deletePassword(account: Self.preAuthKeyAccount)
        try? keychainService.deletePassword(account: Self.apiKeyAccount)
    }

    // MARK: - Migration

    /// Migrate from the old ``TailscaleConfigStore`` format (single Headscale
    /// provider, no provider field) to the new dual-provider format.
    func migrateIfNeeded() {
        let oldControlURL = defaults.string(forKey: Self.controlURLKey) ?? ""
        let oldHasKey = (try? keychainService.retrievePassword(account: Self.preAuthKeyAccount)) != nil
        guard provider == nil, !oldControlURL.isEmpty, oldHasKey else { return }

        provider = .headscale
        controlURL = oldControlURL
        hostname = defaults.string(forKey: Self.hostnameKey) ?? Self.defaultHostname()
        isRegistered = true

        defaults.set(TailscaleProvider.headscale.rawValue, forKey: Self.providerKey)
        defaults.set(true, forKey: Self.isRegisteredKey)
    }

    // MARK: - Private

    private func loadFromStorage() {
        if let raw = defaults.string(forKey: Self.providerKey),
           let p = TailscaleProvider(rawValue: raw)
        {
            provider = p
        }
        controlURL = defaults.string(forKey: Self.controlURLKey) ?? ""
        hostname = defaults.string(forKey: Self.hostnameKey) ?? Self.defaultHostname()
        isRegistered = defaults.bool(forKey: Self.isRegisteredKey)
    }

    private static func defaultHostname() -> String {
        let deviceName = UIDevice.current.name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return deviceName.isEmpty ? "muxi-ios" : "muxi-\(deviceName)"
    }
}
