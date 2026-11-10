import Foundation
import WebKit

enum PGPError: LocalizedError {
    case unavailable
    case operation(String)
    case noPrivateKey
    case passphraseRequired
    case missingRecipientKeys([String])
    case malformedMessage

    var errorDescription: String? {
        switch self {
        case .unavailable: return "The encryption engine could not start on this device."
        case let .operation(message):
            if message.lowercased().contains("passphrase") || message.lowercased().contains("session key") {
                return "Wrong passphrase, or this message was not encrypted to your key."
            }
            return message
        case .noPrivateKey: return "Add your PGP key in Settings first."
        case .passphraseRequired: return "Your key passphrase is required."
        case let .missingRecipientKeys(list): return "No PGP key on file for: \(list.joined(separator: ", ")). Add their public key or turn encryption off."
        case .malformedMessage: return "This encrypted message could not be read."
        }
    }
}

enum SignatureState: String, Decodable, Hashable {
    case none, valid, invalid, unknownKey
}

struct PGPGeneratedKey: Decodable {
    let privateKey: String
    let publicKey: String
    let fingerprint: String
}

struct PGPKeyDetails: Decodable {
    let fingerprint: String
    let userIDs: [String]
    let isPrivate: Bool
    let isLocked: Bool
    let canEncrypt: Bool
    let algorithm: String
    let expires: String
    let publicKey: String
}

struct PGPDecrypted {
    let data: Data
    let signature: SignatureState
    let signer: String
}

private struct PGPEnvelope: Decodable {
    let ok: Bool
    let error: String?
}

private struct PGPSuccess<Value: Decodable>: Decodable {
    let value: Value
}

/// Runs OpenPGP.js in a hidden web view that has no network path:
/// the page's Content-Security-Policy is default-src 'none' and navigation is refused.
/// An HTTPS base URL is used only because WebCrypto requires a secure context; nothing is loaded from it.
@MainActor
final class PGPEngine: NSObject, WKNavigationDelegate {
    static let shared = PGPEngine()

    private var webView: WKWebView?
    private var isReady = false
    private var waiters: [CheckedContinuation<Void, Error>] = []

    private static let page = """
    <!doctype html><html><head><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'wasm-unsafe-eval'"><title>pgp</title></head><body></body></html>
    """

    private func prepare() async throws -> WKWebView {
        if let webView, isReady { return webView }
        if webView == nil { try load() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            waiters.append(continuation)
        }
        guard let webView else { throw PGPError.unavailable }
        return webView
    }

    private func load() throws {
        guard let url = Bundle.main.url(forResource: "openpgp-bridge", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { throw PGPError.unavailable }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(
            WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.loadHTMLString(Self.page, baseURL: URL(string: "https://pgp.invalid/"))
        webView = view
    }

    private func finishWaiters(_ error: Error?) {
        let pending = waiters
        waiters = []
        for waiter in pending {
            if let error { waiter.resume(throwing: error) } else { waiter.resume() }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let allowed = !isReady && navigationAction.request.url?.host == "pgp.invalid"
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("isSecureContext && !!crypto.subtle && typeof __job === 'function'") { [weak self] value, _ in
            let supported = value as? Bool == true
            Task { @MainActor in
                guard let self else { return }
                if supported {
                    self.isReady = true
                    self.finishWaiters(nil)
                } else {
                    self.reset()
                    self.finishWaiters(PGPError.unavailable)
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        reset()
        finishWaiters(PGPError.unavailable)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        reset()
    }

    private func reset() {
        webView?.navigationDelegate = nil
        webView = nil
        isReady = false
    }

    private func call<T: Decodable>(_ operation: String, _ payload: [String: Any]) async throws -> T {
        let view = try await prepare()
        let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        let output: String = try await withCheckedThrowingContinuation { continuation in
            view.callAsyncJavaScript("return await globalThis.__job(name, json);",
                                     arguments: ["name": operation, "json": json],
                                     in: nil, in: .page) { result in
                switch result {
                case let .success(value):
                    if let text = value as? String {
                        continuation.resume(returning: text)
                    } else {
                        continuation.resume(throwing: PGPError.unavailable)
                    }
                case let .failure(error):
                    continuation.resume(throwing: error)
                }
            }
        }
        let data = Data(output.utf8)
        let envelope = try JSONDecoder().decode(PGPEnvelope.self, from: data)
        guard envelope.ok else { throw PGPError.operation(envelope.error ?? "Encryption failed.") }
        return try JSONDecoder().decode(PGPSuccess<T>.self, from: data).value
    }

    // MARK: Operations

    func generateKey(name: String, email: String, passphrase: String) async throws -> PGPGeneratedKey {
        try await call("generateKey", ["name": name, "email": email, "passphrase": passphrase])
    }

    func inspect(armored: String) async throws -> PGPKeyDetails {
        try await call("inspect", ["armored": armored])
    }

    func encrypt(_ data: Data, recipients: [String], signingKey: String?, passphrase: String?) async throws -> String {
        struct Output: Decodable { let armored: String }
        var payload: [String: Any] = ["data": data.base64EncodedString(), "recipients": recipients]
        if let signingKey { payload["signingKey"] = signingKey }
        if let passphrase { payload["passphrase"] = passphrase }
        let output: Output = try await call("encrypt", payload)
        return output.armored
    }

    func decrypt(armored: String, privateKey: String, passphrase: String, verificationKeys: [String]) async throws -> PGPDecrypted {
        struct Output: Decodable { let data: String; let signature: SignatureState; let signer: String }
        let output: Output = try await call("decrypt", [
            "armored": armored, "privateKey": privateKey, "passphrase": passphrase, "verificationKeys": verificationKeys,
        ])
        guard let data = Data(base64Encoded: output.data) else { throw PGPError.malformedMessage }
        return PGPDecrypted(data: data, signature: output.signature, signer: output.signer)
    }

    func signDetached(_ data: Data, privateKey: String, passphrase: String) async throws -> (signature: String, micalg: String) {
        struct Output: Decodable { let signature: String; let micalg: String }
        let output: Output = try await call("signDetached", [
            "data": data.base64EncodedString(), "privateKey": privateKey, "passphrase": passphrase,
        ])
        return (output.signature, output.micalg)
    }

    func verifyDetached(_ data: Data, signature: String, keys: [String]) async throws -> (state: SignatureState, signer: String) {
        struct Output: Decodable { let signature: SignatureState; let signer: String }
        let output: Output = try await call("verifyDetached", [
            "data": data.base64EncodedString(), "signature": signature, "keys": keys,
        ])
        return (output.signature, output.signer)
    }

    func verifyCleartext(armored: String, keys: [String]) async throws -> (text: String, state: SignatureState, signer: String) {
        struct Output: Decodable { let text: String; let signature: SignatureState; let signer: String }
        let output: Output = try await call("verifyCleartext", ["armored": armored, "keys": keys])
        return (output.text, output.signature, output.signer)
    }
}
