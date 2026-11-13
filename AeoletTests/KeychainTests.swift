import Security
import XCTest
@testable import Aeolet

/// Secrets must be device-only and never synced, in the data protection keychain, on iOS and on the Mac.
final class KeychainTests: XCTestCase {
    private let key = "unit-test.\(UUID().uuidString)"

    override func tearDown() {
        KeychainStore.delete(key)
    }

    /// CI builds the Mac app without an Apple account, so it has no provisioning profile and no keychain access group.
    private func save(_ data: Data, protection: KeychainStore.Protection) throws {
        do {
            try KeychainStore.save(data, key: key, protection: protection)
        } catch KeychainError.status(errSecMissingEntitlement) {
            throw XCTSkip("This build is not signed with a team, so it can't reach the data protection keychain.")
        }
    }

    func testItemsAreDeviceOnlyAndNotSynced() throws {
        try save(Data("secret".utf8), protection: .afterFirstUnlock)
        XCTAssertEqual(try KeychainStore.load(key), Data("secret".utf8))

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainStore.service,
            kSecAttrAccount as String: key,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &item), errSecSuccess, "Not in the data protection keychain")
        let attributes = try XCTUnwrap(item as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertNotEqual(attributes[kSecAttrSynchronizable as String] as? Bool, true)

        KeychainStore.delete(key)
        XCTAssertNil(try KeychainStore.load(key))
    }

    func testPrivateKeysNeedTheDeviceUnlocked() throws {
        try save(Data("key".utf8), protection: .whenUnlocked)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainStore.service,
            kSecAttrAccount as String: key,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnAttributes as String: true,
        ]
        var item: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &item), errSecSuccess)
        XCTAssertEqual((item as? [String: Any])?[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    }
}
