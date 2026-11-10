import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

enum AuthError: LocalizedError {
    case cancelled, stateMismatch, missingCode, missingRefreshToken, scopeNotGranted, reauthenticationRequired(String), server(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Sign-in was cancelled."
        case .stateMismatch: return "Sign-in response failed its security check. Please try again."
        case .missingCode: return "Google did not return an authorisation code."
        case .missingRefreshToken: return "Google did not return a long-lived token. Remove the app at myaccount.google.com/permissions and sign in again."
        case .scopeNotGranted: return "Aeolet needs Gmail access to work. Sign in again and tick the Gmail permission."
        case let .reauthenticationRequired(account): return "\(account) needs to sign in again."
        case let .server(message): return message
        }
    }
}

struct PKCE {
    let verifier: String
    let challenge: String

    init() {
        self.init(verifier: Self.randomURLSafe(byteCount: 64))
    }

    init(verifier: String) {
        self.verifier = verifier
        challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
    }

    static func randomURLSafe(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        precondition(status == errSecSuccess, "System random source failed")
        return Data(bytes).base64URLEncoded
    }
}

struct TokenResponse: Decodable {
    let accessToken: String
    let expiresIn: Int
    let refreshToken: String?
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
    }
}

enum GoogleOAuth {
    private static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    private static let revokeURL = URL(string: "https://oauth2.googleapis.com/revoke")!

    static func post(_ url: URL, fields: [String: String]) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(fields.map { "\($0.key)=\($0.value.formEncoded)" }.joined(separator: "&").utf8)
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    static func exchange(code: String, verifier: String) async throws -> TokenResponse {
        let (data, status) = try await post(tokenURL, fields: [
            "client_id": AppConfig.clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": AppConfig.redirectURI,
        ])
        guard status == 200 else { throw AuthError.server(serverMessage(data, status: status)) }
        return try GmailClient.decode(TokenResponse.self, from: data)
    }

    static func refresh(_ refreshToken: String, account: String) async throws -> TokenResponse {
        let (data, status) = try await post(tokenURL, fields: [
            "client_id": AppConfig.clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ])
        if status == 400 || status == 401, String(decoding: data, as: UTF8.self).contains("invalid_grant") {
            throw AuthError.reauthenticationRequired(account)
        }
        guard status == 200 else { throw AuthError.server(serverMessage(data, status: status)) }
        return try GmailClient.decode(TokenResponse.self, from: data)
    }

    static func revoke(_ token: String) async {
        _ = try? await post(revokeURL, fields: ["token": token])
    }

    private static func serverMessage(_ data: Data, status: Int) -> String {
        struct Body: Decodable { let error: String?; let error_description: String? }
        if let body = try? JSONDecoder().decode(Body.self, from: data) {
            return body.error_description ?? body.error ?? "Google returned status \(status)."
        }
        return "Google returned status \(status)."
    }
}

/// Runs Google's own sign-in page in Apple's isolated system browser sheet.
/// The app never sees the password; it only receives a one-time code bound to a PKCE verifier.
@MainActor
final class GoogleSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func signIn() async throws -> TokenResponse {
        let pkce = PKCE()
        let state = PKCE.randomURLSafe(byteCount: 24)
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: AppConfig.clientID),
            URLQueryItem(name: "redirect_uri", value: AppConfig.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: AppConfig.gmailScope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "select_account consent"),
        ]

        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: components.url!, callbackURLScheme: AppConfig.redirectScheme) { url, error in
                if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: AuthError.cancelled)
                } else if let error {
                    continuation.resume(throwing: error)
                } else if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: AuthError.missingCode)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            self.session = session
            if !session.start() {
                continuation.resume(throwing: AuthError.server("Could not open the Google sign-in page."))
            }
        }
        session = nil

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state else { throw AuthError.stateMismatch }
        if let failure = items.first(where: { $0.name == "error" })?.value {
            throw failure == "access_denied" ? AuthError.cancelled : AuthError.server(failure)
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else { throw AuthError.missingCode }

        let tokens = try await GoogleOAuth.exchange(code: code, verifier: pkce.verifier)
        guard tokens.scope?.split(separator: " ").contains(Substring(AppConfig.gmailScope)) ?? false else {
            if let granted = tokens.refreshToken { await GoogleOAuth.revoke(granted) }
            throw AuthError.scopeNotGranted
        }
        guard tokens.refreshToken != nil else { throw AuthError.missingRefreshToken }
        return tokens
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first(where: { $0.activationState == .foregroundActive })?.keyWindow
            ?? scenes.first?.windows.first
            ?? ASPresentationAnchor()
    }
}
