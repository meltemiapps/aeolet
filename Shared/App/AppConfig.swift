import Foundation

enum AppConfig {
    static let clientPrefix = Bundle.main.object(forInfoDictionaryKey: "GoogleClientPrefix") as? String ?? ""
    /// Whether a Google OAuth client ID is built in. Only Sign in with Google needs one: without it the app still
    /// opens and adds Gmail and Yahoo Mail with an app password, or any IMAP and SMTP account. Debug runs against
    /// the mock Gmail server can act as a build without one with -AeoletNoGoogleClientID.
    static var hasGoogleClientID: Bool {
        #if DEBUG
        if MockGmail.isActive && ProcessInfo.processInfo.arguments.contains("-AeoletNoGoogleClientID") { return false }
        #endif
        return !clientPrefix.isEmpty && !clientPrefix.contains("REPLACE")
    }
    static var clientID: String { "\(clientPrefix).apps.googleusercontent.com" }
    static var redirectScheme: String { "com.googleusercontent.apps.\(clientPrefix)" }
    static var redirectURI: String { "\(redirectScheme):/oauth2redirect" }

    /// Whether new accounts can be added with Sign in with Google. Off since 1.2: Google requires a paid
    /// security assessment (CASA) for the Gmail scope, which Aeolet hasn't had. Accounts already signed in with
    /// Google keep working, and all the Google code stays, so turning this back on restores the option.
    static let googleSignInEnabled = false

    /// Whether Sign in with Google is wanted: the flag above, or, in Debug runs against the mock Gmail server,
    /// -AeoletOfferGoogleSignIn, so UI tests can still add the Google accounts that existing users have.
    private static var wantsGoogleSignIn: Bool {
        #if DEBUG
        if MockGmail.isActive && ProcessInfo.processInfo.arguments.contains("-AeoletOfferGoogleSignIn") { return true }
        #endif
        return googleSignInEnabled
    }

    /// Whether to show Sign in with Google: it is wanted and there is a client ID to sign in with.
    static var offersGoogleSignIn: Bool { wantsGoogleSignIn && hasGoogleClientID }

    /// Shown in Settings when Sign in with Google is turned on but can't be offered, nil otherwise.
    static var googleSignInUnavailableNote: String? {
        wantsGoogleSignIn && !hasGoogleClientID
            ? "Sign in with Google is hidden because this build has no Google client ID. Set GOOGLE_CLIENT_PREFIX in Config.xcconfig to offer it."
            : nil
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
