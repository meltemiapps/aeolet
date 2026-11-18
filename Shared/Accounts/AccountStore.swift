import Foundation

enum AccountError: LocalizedError {
    case alreadyAdded(String)
    case invalidSettings
    case missingPassword(String)

    var errorDescription: String? {
        switch self {
        case let .alreadyAdded(email): return "\(email) is already in Aeolet."
        case .invalidSettings: return "Check the server names and ports."
        case let .missingPassword(email): return "Aeolet no longer has the password for \(email). Sign out and add the account again."
        }
    }
}

/// IMAP/SMTP accounts. Google accounts stay in TokenStore exactly as before; this list sits beside it.
///
/// The account list holds only non-secret settings (address, servers, user name), and is still kept in the Keychain,
/// so it is never in a backup or a plain file. Each password is a separate Keychain item with the same protection
/// as Google's refresh token: readable after first unlock, this device only, never synced to iCloud.
enum AccountStore {
    private static let listKey = "imap.accounts"
    static func passwordKey(_ email: String) -> String { "imap.password.\(email.lowercased())" }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: [MailAccount]?

    /// Every IMAP account, in the order they were added.
    static func mailAccounts() -> [MailAccount] {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let list = (try? KeychainStore.load(listKey)).flatMap { try? JSONDecoder().decode([MailAccount].self, from: $0) } ?? []
        cached = list
        return list
    }

    static func mailAccount(_ email: String) -> MailAccount? {
        mailAccounts().first { $0.id == email.lowercased() }
    }

    /// Google accounts first (as before), then IMAP accounts.
    static func allAccounts() async -> [String] {
        let google = await TokenStore.shared.accounts()
        let others = mailAccounts().map(\.email).filter { email in !google.contains { $0.lowercased() == email.lowercased() } }
        return google + others
    }

    static func add(_ account: MailAccount, password: String) throws {
        guard account.isValid else { throw AccountError.invalidSettings }
        guard mailAccount(account.email) == nil else { throw AccountError.alreadyAdded(account.email) }
        try KeychainStore.save(Data(password.utf8), key: passwordKey(account.email), protection: .afterFirstUnlock)
        do {
            try saveList(mailAccounts() + [account])
        } catch {
            KeychainStore.delete(passwordKey(account.email))
            throw error
        }
    }

    static func password(for email: String) throws -> String {
        guard let data = try KeychainStore.load(passwordKey(email)) else { throw AccountError.missingPassword(email) }
        return String(decoding: data, as: UTF8.self)
    }

    /// Deletes the account's settings and password from the Keychain. Nothing is sent anywhere.
    static func remove(_ email: String) {
        KeychainStore.delete(passwordKey(email))
        try? saveList(mailAccounts().filter { $0.id != email.lowercased() })
    }

    private static func saveList(_ list: [MailAccount]) throws {
        try KeychainStore.save(try JSONEncoder().encode(list), key: listKey, protection: .afterFirstUnlock)
        lock.lock()
        cached = list
        lock.unlock()
    }

    /// Mock runs and tests reset the Keychain underneath the cache.
    static func resetCache() {
        lock.lock()
        cached = nil
        lock.unlock()
    }
}
