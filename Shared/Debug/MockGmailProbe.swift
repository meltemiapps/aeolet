#if DEBUG
import Combine
import SwiftUI

/// An invisible accessibility element that lets UI tests read what the app sent to the mock server
/// and which Keychain items exist. Present only in mock runs of Debug builds.
struct MockGmailProbe: View {
    @State private var snapshot = MockGmailServer.shared.snapshot()
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityIdentifier("mock-probe")
            .accessibilityLabel("Mock probe")
            .accessibilityValue(snapshot)
            .onReceive(NotificationCenter.default.publisher(for: MockGmailServer.didChange)) { _ in refresh() }
            .onReceive(timer) { _ in refresh() }
            .allowsHitTesting(false)
    }

    private func refresh() {
        let next = MockGmailServer.shared.snapshot()
        if next != snapshot { snapshot = next }
    }
}

extension KeychainStore {
    /// Every item name this app holds, used by the probe to show that signing out removes credentials.
    static func allKeys() -> [String] {
        if let memory = MockKeychain.active { return memory.keys() }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
              let list = items as? [[String: Any]] else { return [] }
        return list.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    static func deleteAll() {
        if let memory = MockKeychain.active { return memory.removeAll() }
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecUseDataProtectionKeychain as String: true] as CFDictionary)
    }
}

/// Mock runs only. A Mac app needs a provisioning profile to reach the data protection keychain, and CI builds
/// have none (no Apple account there), so a mock run that finds the keychain unavailable keeps items in memory.
/// Signed builds, and every build outside a mock run, use the real keychain.
final class MockKeychain: @unchecked Sendable {
    static let active: MockKeychain? = {
        guard MockGmail.isActive else { return nil }
        let probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.meltemiapps.aeolet.keychain-probe",
            kSecAttrAccount as String: "probe",
            kSecUseDataProtectionKeychain as String: true,
        ]
        var add = probe
        add[kSecValueData as String] = Data([1])
        let status = SecItemAdd(add as CFDictionary, nil)
        SecItemDelete(probe as CFDictionary)
        return status == errSecMissingEntitlement ? MockKeychain() : nil
    }()

    /// Kept in the mock's own private folder, so a test can relaunch the app and stay signed in.
    private static let fileName = "mock-keychain.json"
    private let lock = NSLock()
    private var items: [String: Data]

    private init() {
        items = PrivateFile.read(name: Self.fileName).flatMap { try? JSONDecoder().decode([String: Data].self, from: $0) } ?? [:]
    }

    private func change(_ body: (inout [String: Data]) -> Void) {
        lock.withLock {
            body(&items)
            if let data = try? JSONEncoder().encode(items) { try? PrivateFile.write(data, name: Self.fileName) }
        }
    }

    func save(_ data: Data, key: String) { change { $0[key] = data } }
    func load(_ key: String) -> Data? { lock.withLock { items[key] } }
    func delete(_ key: String) { change { $0[key] = nil } }
    func keys() -> [String] { lock.withLock { Array(items.keys) } }
    func removeAll() { change { $0 = [:] } }
}
#endif
