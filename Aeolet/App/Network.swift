import Foundation

/// Every request to Google goes through sessions built here, so test builds can route them to the mock Gmail server.
enum Network {
    static func configuration(_ base: URLSessionConfiguration = .ephemeral) -> URLSessionConfiguration {
        #if DEBUG
        MockGmail.install(into: base)
        #endif
        return base
    }

    /// For one-off requests (sign-in, token refresh, key lookup). Ephemeral: no cookies, cache or credential storage.
    static let ephemeral = URLSession(configuration: configuration())
}
