import LocalAuthentication
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var accounts: [String] = []
    @Published var currentAccount: String?
    @Published private(set) var isLoaded = false
    @Published private(set) var isLocked = false
    @Published var isSigningIn = false
    @Published var errorMessage: String?
    @Published var requireDeviceAuth = AppDefaults.store.bool(forKey: "requireDeviceAuth") {
        didSet { AppDefaults.store.set(requireDeviceAuth, forKey: "requireDeviceAuth") }
    }

    private let signInFlow = GoogleSignIn()
    private var isAuthenticating = false

    init() {
        Task { await load() }
    }

    private func load() async {
        accounts = await AccountStore.allAccounts()
        let last = AppDefaults.store.string(forKey: "lastAccount") ?? ""
        currentAccount = accounts.contains(last) ? last : accounts.first
        isLocked = requireDeviceAuth
        isLoaded = true
        if isLocked { unlock() }
    }

    func select(_ account: String) {
        currentAccount = account
        AppDefaults.store.set(account, forKey: "lastAccount")
    }

    func signIn() async {
        guard !isSigningIn else { return }
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            let tokens = try await signInFlow.signIn()
            let email = try await Self.resolveEmail(accessToken: tokens.accessToken)
            try await TokenStore.shared.add(account: email, tokens: tokens)
            accounts = await AccountStore.allAccounts()
            select(email)
            await BackgroundSync.establishBaseline(account: email)
            await BackgroundSync.requestNotificationPermission()
        } catch AuthError.cancelled {
            return
        } catch {
            errorMessage = error.userMessage
        }
    }

    private static func resolveEmail(accessToken: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await Network.ephemeral.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw GmailError.invalidResponse }
        guard (200..<300).contains(status) else { throw GmailError.http(status, GmailClient.message(from: data)) }
        return try GmailClient.decode(GmailProfile.self, from: data).emailAddress
    }

    /// Adds an IMAP/SMTP account after proving the settings work: logs in to the IMAP server and to the SMTP
    /// server, both over TLS. Only then are the settings and the password stored, in the Keychain.
    func addMailAccount(_ account: MailAccount, password: String) async throws {
        var account = account
        account.email = account.email.trimmingCharacters(in: .whitespacesAndNewlines)
        account.username = account.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard account.isValid, !password.isEmpty else { throw AccountError.invalidSettings }
        guard !accounts.contains(where: { $0.lowercased() == account.id }) else { throw AccountError.alreadyAdded(account.email) }

        let imap = try await IMAPLogin.connect(account, password: password)
        try? await imap.disconnect()
        let smtp = try await SMTPSender.connect(account, password: password)
        try? await smtp.disconnect()

        try AccountStore.add(account, password: password)
        accounts = await AccountStore.allAccounts()
        select(account.email)
        await BackgroundSync.establishBaseline(account: account.email)
        await BackgroundSync.requestNotificationPermission()
    }

    /// Whether the account signs in with Google (and so is revoked at Google when it signs out).
    func isGoogleAccount(_ account: String) -> Bool { AccountStore.mailAccount(account) == nil }

    func signOut(_ account: String) async {
        if AccountStore.mailAccount(account) != nil {
            await IMAPSessionPool.close(account)
            await IMAPRawCache.shared.removeAll()
            AccountStore.remove(account)
        } else {
            await TokenStore.shared.remove(account: account)
        }
        PGPStore.shared.deleteOwnKey(account: account)
        MailCache.deleteAll(account: account)
        BackgroundSync.forget(account: account)
        accounts = await AccountStore.allAccounts()
        if currentAccount == account { currentAccount = accounts.first }
        if accounts.isEmpty { PrivateFile.deleteAll() }
    }

    func didEnterBackground() {
        if requireDeviceAuth { isLocked = true }
    }

    func didBecomeActive() {
        if isLocked { unlock() }
    }

    func unlock() {
        guard !isAuthenticating else { return }
        let context = LAContext()
        var failure: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &failure) else {
            errorMessage = "Set a device passcode to use app lock."
            return
        }
        isAuthenticating = true
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your mail") { success, _ in
            Task { @MainActor in
                self.isAuthenticating = false
                if success { self.isLocked = false }
            }
        }
    }
}
