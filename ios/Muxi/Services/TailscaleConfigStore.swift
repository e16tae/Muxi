import Foundation
import UIKit

/// Persists Headscale configuration (controlURL, hostname in UserDefaults;
/// pre-auth key in Keychain).
struct TailscaleConfigStore {
    private let defaults: UserDefaults
    private let keychainService: KeychainService

    private static let controlURLKey = "tailscale.controlURL"
    private static let hostnameKey = "tailscale.hostname"
    private static let preAuthKeyAccount = "tailscale.preAuthKey"

    init(defaults: UserDefaults = .standard, keychainService: KeychainService = KeychainService()) {
        self.defaults = defaults
        self.keychainService = keychainService
    }

    var controlURL: String {
        get { defaults.string(forKey: Self.controlURLKey) ?? "" }
        nonmutating set { defaults.set(newValue, forKey: Self.controlURLKey) }
    }

    var hostname: String {
        get {
            let stored = defaults.string(forKey: Self.hostnameKey) ?? ""
            if stored.isEmpty {
                return Self.defaultHostname()
            }
            return stored
        }
        nonmutating set { defaults.set(newValue, forKey: Self.hostnameKey) }
    }

    var preAuthKey: String {
        get { (try? keychainService.retrievePassword(account: Self.preAuthKeyAccount)) ?? "" }
        nonmutating set {
            if newValue.isEmpty {
                try? keychainService.deletePassword(account: Self.preAuthKeyAccount)
            } else {
                try? keychainService.savePassword(newValue, account: Self.preAuthKeyAccount)
            }
        }
    }

    var isConfigured: Bool {
        !controlURL.isEmpty && !preAuthKey.isEmpty
    }

    func clear() {
        defaults.removeObject(forKey: Self.controlURLKey)
        defaults.removeObject(forKey: Self.hostnameKey)
        defaults.synchronize()
        try? keychainService.deletePassword(account: Self.preAuthKeyAccount)
    }

    private static func defaultHostname() -> String {
        let deviceName = UIDevice.current.name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return deviceName.isEmpty ? "muxi-ios" : "muxi-\(deviceName)"
    }
}
