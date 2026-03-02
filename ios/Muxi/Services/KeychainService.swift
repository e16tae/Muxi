import Foundation
import Security

// MARK: - KeychainError

/// Errors that can occur when interacting with the iOS Keychain.
enum KeychainError: Error {
    case itemNotFound
    case duplicateItem
    case unexpectedStatus(OSStatus)
    case dataConversionFailed
}

// MARK: - KeychainService

/// Stores and retrieves secrets (passwords and SSH private keys) in the
/// iOS Keychain.  Password items use the ``serviceName`` identifier;
/// SSH-key items use the ``sshKeyService`` identifier.
final class KeychainService {
    private let serviceName = "com.muxi.app"
    private let sshKeyService = "com.muxi.ssh-keys"

    // MARK: - Passwords

    /// Save or update a password for the given account.
    ///
    /// Uses an update-first-then-add pattern so that calling this method
    /// twice with the same account overwrites the previous value.
    func savePassword(_ password: String, account: String) throws {
        guard let data = password.data(using: .utf8) else {
            throw KeychainError.dataConversionFailed
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
        ]

        // Try to update first
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    /// Retrieve the password associated with the given account.
    ///
    /// - Throws: ``KeychainError/itemNotFound`` if no entry exists.
    func retrievePassword(account: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: - SSH Keys

    /// Save an SSH key's private data and metadata to the Keychain.
    ///
    /// Uses a delete-then-add pattern.  The ``SSHKey`` metadata is stored
    /// as JSON in the item's `kSecAttrComment` attribute.
    func saveSSHKey(_ key: SSHKey, privateKeyData: Data) throws {
        let metadata = try JSONEncoder().encode(key)

        guard let commentString = String(data: metadata, encoding: .utf8) else {
            throw KeychainError.dataConversionFailed
        }

        let searchQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sshKeyService,
            kSecAttrAccount as String: key.id.uuidString,
        ]

        // Try to update first (atomic pattern, same as savePassword)
        let updateAttrs: [String: Any] = [
            kSecAttrLabel as String: key.name,
            kSecAttrComment as String: commentString,
            kSecValueData as String: privateKeyData,
        ]
        let updateStatus = SecItemUpdate(searchQuery as CFDictionary, updateAttrs as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var addQuery = searchQuery
            addQuery[kSecAttrLabel as String] = key.name
            addQuery[kSecAttrComment as String] = commentString
            addQuery[kSecValueData as String] = privateKeyData
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    /// Retrieve an SSH key's metadata and private key data from the Keychain.
    ///
    /// - Throws: ``KeychainError/itemNotFound`` if no key with the given
    ///   ID exists.
    func retrieveSSHKey(id: UUID) throws -> (SSHKey, Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sshKeyService,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sshKeyService,
            kSecAttrAccount as String: id.uuidString,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
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
