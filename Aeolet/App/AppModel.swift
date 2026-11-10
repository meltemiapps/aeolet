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
    @Published var requireDeviceAuth = UserDefaults.standard.bool(forKey: "requireDeviceAuth") {
        didSet { UserDefaults.standard.set(requireDeviceAuth, forKey: "requireDeviceAuth") }
    }

    private let signInFlow = GoogleSignIn()
    private var isAuthenticating = false

    init() {
        Task { await load() }
    }

    private func load() async {
        accounts = await TokenStore.shared.accounts()
        let last = UserDefaults.standard.string(forKey: "lastAccount") ?? ""
        currentAccount = accounts.contains(last) ? last : accounts.first
        isLocked = requireDeviceAuth
        isLoaded = true
        if isLocked { unlock() }
    }

    func select(_ account: String) {
        currentAccount = account
        UserDefaults.standard.set(account, forKey: "lastAccount")
    }

    func signIn() async {
        guard !isSigningIn else { return }
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            let tokens = try await signInFlow.signIn()
            let email = try await Self.resolveEmail(accessToken: tokens.accessToken)
            try await TokenStore.shared.add(account: email, tokens: tokens)
            accounts = await TokenStore.shared.accounts()
            select(email)
            await BackgroundSync.establishBaseline(account: email)
            await BackgroundSync.requestNotificationPermission()
        } catch AuthError.cancelled {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func resolveEmail(accessToken: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession(configuration: .ephemeral).data(for: request)
        return try JSONDecoder().decode(GmailProfile.self, from: data).emailAddress
    }

    func signOut(_ account: String) async {
        await TokenStore.shared.remove(account: account)
        PGPStore.shared.deleteOwnKey(account: account)
        accounts = await TokenStore.shared.accounts()
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
