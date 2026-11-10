import Foundation

/// Refresh tokens stay in the Keychain. Access tokens exist only in memory and are refreshed on demand.
actor TokenStore {
    static let shared = TokenStore()

    private var access: [String: (token: String, expiry: Date)] = [:]
    private var inFlight: [String: Task<String, Error>] = [:]

    private static let accountsKey = "accounts"
    private static func refreshKey(_ account: String) -> String { "oauth.refresh.\(account.lowercased())" }

    func accounts() -> [String] {
        guard let data = try? KeychainStore.load(Self.accountsKey),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return list
    }

    func add(account: String, tokens: TokenResponse) throws {
        guard let refresh = tokens.refreshToken else { throw AuthError.missingRefreshToken }
        try KeychainStore.save(Data(refresh.utf8), key: Self.refreshKey(account), protection: .afterFirstUnlock)
        access[account] = (tokens.accessToken, Date().addingTimeInterval(TimeInterval(tokens.expiresIn - 60)))
        var list = accounts()
        if !list.contains(account) { list.append(account) }
        try KeychainStore.save(try JSONEncoder().encode(list), key: Self.accountsKey, protection: .afterFirstUnlock)
    }

    func accessToken(for account: String, forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let entry = access[account], entry.expiry > Date() { return entry.token }
        if let running = inFlight[account] { return try await running.value }

        guard let data = try KeychainStore.load(Self.refreshKey(account)) else {
            throw AuthError.reauthenticationRequired(account)
        }
        let refresh = String(decoding: data, as: UTF8.self)
        let task = Task<String, Error> {
            let tokens = try await GoogleOAuth.refresh(refresh, account: account)
            self.remember(account: account, tokens: tokens)
            return tokens.accessToken
        }
        inFlight[account] = task
        defer { inFlight[account] = nil }
        return try await task.value
    }

    private func remember(account: String, tokens: TokenResponse) {
        access[account] = (tokens.accessToken, Date().addingTimeInterval(TimeInterval(tokens.expiresIn - 60)))
    }

    /// Revokes the grant at Google and removes every local credential for the account.
    func remove(account: String) async {
        if let data = try? KeychainStore.load(Self.refreshKey(account)) {
            await GoogleOAuth.revoke(String(decoding: data, as: UTF8.self))
        }
        KeychainStore.delete(Self.refreshKey(account))
        access[account] = nil
        let list = accounts().filter { $0 != account }
        if let encoded = try? JSONEncoder().encode(list) {
            try? KeychainStore.save(encoded, key: Self.accountsKey, protection: .afterFirstUnlock)
        }
    }
}
