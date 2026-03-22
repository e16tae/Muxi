import Foundation
import Security
import Testing

@testable import Muxi

/// Helper: probe Keychain availability — returns `true` when the Keychain
/// is accessible, `false` when running in an environment without code-signing
/// entitlements (CI simulators typically return errSecMissingEntitlement).
private func isKeychainAvailable() -> Bool {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrAccount as String: "__keychain_probe__",
        kSecReturnData as String: true,
    ]
    let status = SecItemCopyMatching(query as CFDictionary, nil)
    return status != errSecMissingEntitlement
}

@Suite("TailscaleAccountManager", .serialized)
@MainActor
struct TailscaleAccountManagerTests {

    private func makeManager() -> TailscaleAccountManager {
        let defaults = UserDefaults(suiteName: "test.tailscale.\(UUID().uuidString)")!
        let manager = TailscaleAccountManager(defaults: defaults, keychainService: KeychainService())
        // Clean any leftover keychain state from prior test runs
        manager.signOut()
        return manager
    }

    @Test("Initial state has no account configured")
    func initialState() {
        let manager = makeManager()
        #expect(manager.isConfigured == false)
        #expect(manager.provider == nil)
        #expect(manager.lastConnected == false)
    }

    @Test("Save Headscale account")
    func saveHeadscaleAccount() throws {
        let manager = makeManager()
        manager.configureHeadscale(
            controlURL: "https://hs.example.com",
            preAuthKey: "hskey-123",
            apiKey: "hsapi-456",
            hostname: "muxi-test"
        )
        #expect(manager.provider == .headscale)
        #expect(manager.controlURL == "https://hs.example.com")
        #expect(manager.hostname == "muxi-test")
        #expect(manager.isConfigured == false)  // not registered yet
        manager.signOut()
    }

    @Test("Headscale isConfigured after registration")
    func headscaleConfiguredAfterRegistration() {
        let manager = makeManager()
        manager.configureHeadscale(
            controlURL: "https://hs.example.com",
            preAuthKey: "hskey-123",
            apiKey: "hsapi-456",
            hostname: "muxi-test"
        )
        manager.markRegistered()
        #expect(manager.isConfigured == true)
        manager.signOut()
    }

    @Test("Save Official Tailscale account")
    func saveOfficialAccount() throws {
        try #require(isKeychainAvailable(), "Keychain unavailable (missing entitlements)")
        let manager = makeManager()
        manager.configureOfficial(
            accessToken: "tskey-access-123",
            refreshToken: "tskey-refresh-456",
            hostname: "muxi-test"
        )
        #expect(manager.provider == .official)
        #expect(manager.isConfigured == true)
        manager.signOut()
    }

    @Test("lastConnected persists across instances")
    func lastConnectedPersists() {
        let defaults = UserDefaults(suiteName: "test.tailscale.\(UUID().uuidString)")!
        let manager1 = TailscaleAccountManager(defaults: defaults, keychainService: KeychainService())
        manager1.lastConnected = true

        let manager2 = TailscaleAccountManager(defaults: defaults, keychainService: KeychainService())
        #expect(manager2.lastConnected == true)
    }

    @Test("Sign out clears all state")
    func signOutClearsAll() {
        let manager = makeManager()
        manager.configureOfficial(
            accessToken: "tskey-access-123",
            refreshToken: "tskey-refresh-456",
            hostname: "muxi-test"
        )
        manager.signOut()
        #expect(manager.provider == nil)
        #expect(manager.isConfigured == false)
        #expect(manager.lastConnected == false)
    }

    @Test("Account struct populated from storage")
    func accountFromStorage() {
        let manager = makeManager()
        manager.configureHeadscale(
            controlURL: "https://hs.example.com",
            preAuthKey: "hskey-123",
            apiKey: "hsapi-456",
            hostname: "muxi-test"
        )
        manager.markRegistered()

        let account = manager.account
        #expect(account != nil)
        #expect(account?.provider == .headscale)
        #expect(account?.controlURL == "https://hs.example.com")
        #expect(account?.isRegistered == true)
        manager.signOut()
    }
}
