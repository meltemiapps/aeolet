import Foundation

enum AppConfig {
    static let clientPrefix = Bundle.main.object(forInfoDictionaryKey: "GoogleClientPrefix") as? String ?? ""
    static var isConfigured: Bool { !clientPrefix.isEmpty && !clientPrefix.contains("REPLACE") }
    static var clientID: String { "\(clientPrefix).apps.googleusercontent.com" }
    static var redirectScheme: String { "com.googleusercontent.apps.\(clientPrefix)" }
    static var redirectURI: String { "\(redirectScheme):/oauth2redirect" }

    /// Whether new accounts can be added with Sign in with Google. Off since 1.2: Google requires a paid
    /// security assessment (CASA) for the Gmail scope, which Aeolet hasn't had. Accounts already signed in with
    /// Google keep working, and all the Google code stays, so turning this back on restores the option.
    static let googleSignInEnabled = false

    /// Whether to show Sign in with Google. Debug runs against the mock Gmail server can opt in with
    /// -AeoletOfferGoogleSignIn, so UI tests can still add the Google accounts that existing users have.
    static var offersGoogleSignIn: Bool {
        #if DEBUG
        if MockGmail.isActive && ProcessInfo.processInfo.arguments.contains("-AeoletOfferGoogleSignIn") { return true }
        #endif
        return googleSignInEnabled
    }

    /// Least privilege that still covers read, label, trash, draft and send. It cannot permanently delete mail.
    static let gmailScope = "https://www.googleapis.com/auth/gmail.modify"

    static let backgroundTaskID = "com.meltemiapps.aeolet.refresh"
    static let publisherName = "Meltemi Apps"

    static var publisherURL: URL? { url(forKey: "PublisherURL") }
    static var sourceCodeURL: URL? { url(forKey: "SourceCodeURL") }

    private static func url(forKey key: String) -> URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              value.hasPrefix("https:"), !value.contains("REPLACE") else { return nil }
        return URL(string: value)
    }
}
