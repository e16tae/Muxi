import Security
import XCTest

@testable import Muxi

final class KeychainServiceTests: XCTestCase {
    let service = KeychainService()
    let testAccount = "test-\(UUID().uuidString)"

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Keychain requires code signing entitlements, unavailable on CI.
        // Probe with a dummy query to detect errSecMissingEntitlement (-34018).
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "__keychain_probe__",
            kSecReturnData as String: true,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        try XCTSkipIf(
            status == errSecMissingEntitlement,
            "Keychain is unavailable (missing code signing entitlements)"
        )
    }

    override func tearDown() {
        super.tearDown()
        try? service.deletePassword(account: testAccount)
        try? service.deleteSSHKey(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
    }

    // MARK: - Password Tests

    func testSaveAndRetrievePassword() throws {
        try service.savePassword("s3cret", account: testAccount)
        let retrieved = try service.retrievePassword(account: testAccount)
        XCTAssertEqual(retrieved, "s3cret")
    }

    func testUpdatePassword() throws {
        try service.savePassword("old", account: testAccount)
        try service.savePassword("new", account: testAccount)
        let retrieved = try service.retrievePassword(account: testAccount)
        XCTAssertEqual(retrieved, "new")
    }

    func testDeletePassword() throws {
        try service.savePassword("temp", account: testAccount)
        try service.deletePassword(account: testAccount)
        XCTAssertThrowsError(try service.retrievePassword(account: testAccount))
    }

    func testRetrieveNonexistentPassword() {
        XCTAssertThrowsError(
            try service.retrievePassword(account: "nonexistent-\(UUID())")
        )
    }

    // MARK: - SSH Key Tests

    func testSaveAndRetrieveSSHKey() throws {
        let keyId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let keyData = Data("fake-private-key-data".utf8)
        let sshKey = SSHKey(id: keyId, name: "My Key", type: .ed25519)

        try service.saveSSHKey(sshKey, privateKeyData: keyData)

        let (retrieved, data) = try service.retrieveSSHKey(id: keyId)
        XCTAssertEqual(retrieved.name, "My Key")
        XCTAssertEqual(retrieved.type, .ed25519)
        XCTAssertEqual(data, keyData)
    }

    func testListSSHKeys() throws {
        let keyId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let keyData = Data("key-data".utf8)
        let sshKey = SSHKey(id: keyId, name: "Listed Key", type: .rsa)

        try service.saveSSHKey(sshKey, privateKeyData: keyData)

        let keys = try service.listSSHKeys()
        XCTAssertTrue(keys.contains(where: { $0.id == keyId }))
    }
}
