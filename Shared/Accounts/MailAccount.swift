import Foundation

/// How a connection is encrypted. There is deliberately no plain-text case: Aeolet never sends mail,
/// a password or a token over a connection without TLS.
enum ConnectionSecurity: String, Codable, CaseIterable, Identifiable {
    /// TLS from the first byte (IMAP 993, SMTP 465).
    case tls
    /// A plain greeting upgraded with STARTTLS (IMAP 143, SMTP 587). If the server does not offer STARTTLS,
    /// or the upgrade fails, the connection is closed before anything else is sent.
    case startTLS

    var id: String { rawValue }

    var label: String {
        switch self {
        case .tls: return "SSL/TLS"
        case .startTLS: return "STARTTLS"
        }
    }
}

struct ServerEndpoint: Codable, Hashable {
    var host: String
    var port: Int
    var security: ConnectionSecurity

    /// A bare host name or IP address: no scheme, path, spaces or port.
    var isValid: Bool {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed == host, (1...65535).contains(port) else { return false }
        let forbidden = CharacterSet(charactersIn: "/:@ ?#\\").union(.whitespacesAndNewlines).union(.controlCharacters)
        return host.rangeOfCharacter(from: forbidden) == nil || host.hasPrefix("[")
    }
}

/// An IMAP/SMTP account. Everything here is non-secret; the password lives in its own Keychain item.
struct MailAccount: Codable, Hashable, Identifiable {
    enum Provider: String, Codable {
        case manual
    }

    var email: String
    /// Shown in the From line of mail you send. Optional.
    var displayName: String
    var provider: Provider
    var username: String
    var imap: ServerEndpoint
    var smtp: ServerEndpoint

    var id: String { email.lowercased() }

    var domain: String { email.split(separator: "@").last.map(String.init)?.lowercased() ?? "" }

    var isValid: Bool { Self.isPlausibleEmail(email) && !username.isEmpty && imap.isValid && smtp.isValid }

    static func isPlausibleEmail(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."),
              !parts[1].hasPrefix("."), !parts[1].hasSuffix(".") else { return false }
        return text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    }

    /// The starting point when nothing could be discovered: the mail domain itself, on the implicit-TLS ports.
    static func defaults(for email: String) -> MailAccount {
        let domain = email.split(separator: "@").last.map(String.init)?.lowercased() ?? ""
        return MailAccount(
            email: email, displayName: "", provider: .manual, username: email,
            imap: ServerEndpoint(host: domain, port: 993, security: .tls),
            smtp: ServerEndpoint(host: domain, port: 465, security: .tls))
    }
}
