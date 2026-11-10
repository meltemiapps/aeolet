#if DEBUG
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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
              let list = items as? [[String: Any]] else { return [] }
        return list.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    static func deleteAll() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
}
#endif
