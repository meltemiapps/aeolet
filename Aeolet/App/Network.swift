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

extension Error {
    /// What to show a person. Network failures get plain words; some arrive without a readable description
    /// and would otherwise show as "The operation couldn't be completed. (NSURLErrorDomain error -1009.)".
    var userMessage: String {
        if let error = self as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                return "You're offline. Check your connection and try again."
            case .timedOut:
                return "Gmail took too long to respond. Try again."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "Can't reach Gmail right now. Try again in a moment."
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
                return "A secure connection to Google couldn't be made. If you're on public Wi-Fi, sign in to it first."
            default:
                break
            }
        }
        return localizedDescription
    }
}
