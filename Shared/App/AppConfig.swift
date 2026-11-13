import Foundation

enum AppConfig {
    static let clientPrefix = Bundle.main.object(forInfoDictionaryKey: "GoogleClientPrefix") as? String ?? ""
    static var isConfigured: Bool { !clientPrefix.isEmpty && !clientPrefix.contains("REPLACE") }
    static var clientID: String { "\(clientPrefix).apps.googleusercontent.com" }
    static var redirectScheme: String { "com.googleusercontent.apps.\(clientPrefix)" }
    static var redirectURI: String { "\(redirectScheme):/oauth2redirect" }

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
