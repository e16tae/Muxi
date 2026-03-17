import Foundation
import Security

// MARK: - KeychainError

/// Errors that can occur when interacting with the iOS Keychain.
enum KeychainError: Error, LocalizedError {
    case itemNotFound
    case duplicateItem
    case unexpectedStatus(OSStatus)
    case dataConversionFailed

    var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return "No credentials found in Keychain"
        case .duplicateItem:
            return "Duplicate Keychain item"
        case .unexpectedStatus(let status):
            return "Keychain error (OSStatus \(status))"
        case .dataConversionFailed:
            return "Failed to decode Keychain data"
        }
    }
}

// MARK: - KeychainService

/// Stores and retrieves secrets (passwords and SSH private keys) in the
/// iOS Keychain.  Password items use the ``serviceName`` identifier;
/// SSH-key items use the ``sshKeyService`` identifier.
final class KeychainService {
    private let serviceName = "com.muxi.app"
    private let sshKeyService = "com.muxi.ssh-keys"

    // MARK: - Internal Helpers

    /// Upsert pattern: try `SecItemUpdate`, fall back to `SecItemAdd` if not found.
    private func updateOrAdd(
        query: [String: Any],
        updateAttrs: [String: Any]
    ) throws {
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            for (k, v) in updateAttrs { addQuery[k] = v }
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    /// Delete a Keychain item. Silently succeeds if the item does not exist.
    private func deleteItem(query: [String: Any]) throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Base search query for a password item.
    private func passwordQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
        ]
    }

    /// Base search query for an SSH key item.
    private func sshKeyQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sshKeyService,
            kSecAttrAccount as String: account,
        ]
    }

    // MARK: - Passwords

    /// Save or update a password for the given account.
    ///
    /// Uses an update-first-then-add pattern so that calling this method
    /// twice with the same account overwrites the previous value.
    func savePassword(_ password: String, account: String) throws {
        guard let data = password.data(using: .utf8) else {
            throw KeychainError.dataConversionFailed
        }

        let query = passwordQuery(account: account)
        try updateOrAdd(query: query, updateAttrs: [kSecValueData as String: data])
    }

    /// Retrieve the password associated with the given account.
    ///
    /// - Throws: ``KeychainError/itemNotFound`` if no entry exists.
    func retrievePassword(account: String) throws -> String {
        var query = passwordQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            if status == errSecItemNotFound {
                throw KeychainError.itemNotFound
            }
            throw KeychainError.unexpectedStatus(status)
        }

        guard let password = String(data: data, encoding: .utf8) else {
            throw KeychainError.dataConversionFailed
        }
        return password
    }

    /// Delete the password for the given account.
    ///
    /// Silently succeeds if the item does not exist.
    func deletePassword(account: String) throws {
        try deleteItem(query: passwordQuery(account: account))
    }

    // MARK: - SSH Keys

    /// Save an SSH key's private data and metadata to the Keychain.
    ///
    /// Uses an update-first-then-add pattern.  The ``SSHKey`` metadata is stored
    /// as JSON in the item's `kSecAttrComment` attribute.
    func saveSSHKey(_ key: SSHKey, privateKeyData: Data) throws {
        let metadata = try JSONEncoder().encode(key)

        guard let commentString = String(data: metadata, encoding: .utf8) else {
            throw KeychainError.dataConversionFailed
        }

        let query = sshKeyQuery(account: key.id.uuidString)
        let updateAttrs: [String: Any] = [
            kSecAttrLabel as String: key.name,
            kSecAttrComment as String: commentString,
            kSecValueData as String: privateKeyData,
        ]
        try updateOrAdd(query: query, updateAttrs: updateAttrs)
    }

    /// Retrieve an SSH key's metadata and private key data from the Keychain.
    ///
    /// - Throws: ``KeychainError/itemNotFound`` if no key with the given
    ///   ID exists.
    func retrieveSSHKey(id: UUID) throws -> (SSHKey, Data) {
        var query = sshKeyQuery(account: id.uuidString)
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw KeychainError.itemNotFound
            }
            throw KeychainError.unexpectedStatus(status)
        }

        guard let dict = result as? [String: Any],
              let privateKeyData = dict[kSecValueData as String] as? Data,
              let comment = dict[kSecAttrComment as String] as? String,
              let metadataData = comment.data(using: .utf8),
              let sshKey = try? JSONDecoder().decode(SSHKey.self, from: metadataData)
        else {
            throw KeychainError.dataConversionFailed
        }

        return (sshKey, privateKeyData)
    }

    /// Delete an SSH key from the Keychain.
    ///
    /// Silently succeeds if the item does not exist.
    func deleteSSHKey(id: UUID) throws {
        try deleteItem(query: sshKeyQuery(account: id.uuidString))
    }

    /// List all SSH key metadata stored in the Keychain.
    ///
    /// Returns an empty array when no keys have been saved.
    func listSSHKeys() throws -> [SSHKey] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sshKeyService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return []
        }

        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw KeychainError.unexpectedStatus(status)
        }

        return items.compactMap { dict in
            guard let comment = dict[kSecAttrComment as String] as? String,
                  let data = comment.data(using: .utf8),
                  let key = try? JSONDecoder().decode(SSHKey.self, from: data)
            else { return nil }
            return key
        }
    }
}
