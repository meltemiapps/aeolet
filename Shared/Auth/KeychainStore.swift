import Foundation
import Security

enum KeychainError: LocalizedError {
    case status(OSStatus)
    var errorDescription: String? {
        if case let .status(code) = self {
            return "Keychain error \(code): \(SecCopyErrorMessageString(code, nil) as String? ?? "unknown")"
        }
        return nil
    }
}

/// All secrets live here: device-only, never in iCloud Keychain, never in device backups that restore elsewhere.
/// On the Mac this is the data protection keychain, the same keychain iOS uses, rather than the legacy file-based one.
enum KeychainStore {
    enum Protection {
        /// Readable by background refresh after the first unlock following a restart.
        case afterFirstUnlock
        /// Readable only while the device is unlocked. Used for PGP private keys.
        case whenUnlocked

        var attribute: CFString {
            switch self {
            case .afterFirstUnlock: return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            case .whenUnlocked: return kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            }
        }
    }

    static let service: String = {
        #if DEBUG
        // Mock runs keep their own items, so UI tests on a Mac never touch the real app's sign-in.
        if MockGmail.isActive { return "com.meltemiapps.aeolet.credentials.mock" }
        #endif
        return "com.meltemiapps.aeolet.credentials"
    }()

    private static func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    static func save(_ data: Data, key: String, protection: Protection) throws {
        #if DEBUG
        if let memory = MockKeychain.active { return memory.save(data, key: key) }
        #endif
        SecItemDelete(baseQuery(key) as CFDictionary)
        var query = baseQuery(key)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = protection.attribute
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    static func load(_ key: String) throws -> Data? {
        #if DEBUG
        if let memory = MockKeychain.active { return memory.load(key) }
        #endif
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        return item as? Data
    }

    static func delete(_ key: String) {
        #if DEBUG
        if let memory = MockKeychain.active { return memory.delete(key) }
        #endif
        SecItemDelete(baseQuery(key) as CFDictionary)
    }
}
