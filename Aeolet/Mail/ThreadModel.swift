import Foundation

enum PGPMessageState: Hashable {
    case none
    case locked
    case decrypted(SignatureState, String)
    case signed(SignatureState, String)
    case failed(String)
}

struct ThreadMessage: Identifiable, Hashable {
    let id: String
    let threadID: String
    let from: String
    let to: String
    let cc: String
    let date: Date
    let subject: String
    let messageIDHeader: String
    let references: String
    var body: MailBody
    var pgp: PGPMessageState = .none
    var pgpKind: PGPKind = .none
    var isExpanded = false

    var wasEncrypted: Bool {
        switch pgp {
        case .locked, .decrypted: return true
        default: return false
        }
    }
}

enum PGPKind: Hashable {
    case none, encryptedMIME, signedMIME, inlineEncrypted, inlineSigned

    static func detect(_ message: GmailMessage, body: MailBody) -> PGPKind {
        func contains(_ part: GmailPart?, type: String) -> Bool {
            guard let part else { return false }
            if part.mimeType?.lowercased() == type { return true }
            return part.parts?.contains { contains($0, type: type) } ?? false
        }
        if contains(message.payload, type: "multipart/encrypted") { return .encryptedMIME }
        if contains(message.payload, type: "multipart/signed") { return .signedMIME }
        let text = body.text ?? ""
        if text.contains("-----BEGIN PGP MESSAGE-----") { return .inlineEncrypted }
        if text.contains("-----BEGIN PGP SIGNED MESSAGE-----") { return .inlineSigned }
        return .none
    }
}

@MainActor
final class ThreadModel: ObservableObject {
    let account: String
    let threadID: String
    private let client: GmailClient
    private let pgp = PGPStore.shared

    @Published var messages: [ThreadMessage] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var passphraseTarget: String?

    init(account: String, threadID: String) {
        self.account = account
        self.threadID = threadID
        client = GmailClient(account: account)
    }

    var subject: String { messages.first?.subject ?? "" }

    func load() async {
        guard messages.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let thread = try await client.thread(threadID)
            let source = thread.messages ?? []
            var built: [ThreadMessage] = []
            for message in source {
                var body = GmailBodyExtractor.body(of: message)
                await embedInlineImages(&body)
                let kind = PGPKind.detect(message, body: body)
                let subject = message.header("Subject") ?? ""
                built.append(ThreadMessage(
                    id: message.id, threadID: threadID,
                    from: message.header("From") ?? "", to: message.header("To") ?? "", cc: message.header("Cc") ?? "",
                    date: message.date, subject: subject.isEmpty ? "(No subject)" : subject,
                    messageIDHeader: message.header("Message-ID") ?? message.header("Message-Id") ?? "",
                    references: message.header("References") ?? "",
                    body: body,
                    pgp: (kind == .encryptedMIME || kind == .inlineEncrypted) ? .locked : .none,
                    pgpKind: kind))
            }
            if let lastIndex = built.indices.last { built[lastIndex].isExpanded = true }
            for index in built.indices where source[index].labelIds?.contains("UNREAD") == true { built[index].isExpanded = true }
            messages = built
            if source.contains(where: { $0.labelIds?.contains("UNREAD") == true }) {
                try? await client.modifyThread(threadID, remove: ["UNREAD"])
            }
            if pgp.isEnabled { await autoProcessPGP() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Replaces cid: images with data: URIs so they display without any network access from the web view.
    private func embedInlineImages(_ body: inout MailBody) async {
        guard var html = body.html, html.contains("cid:") else { return }
        for item in body.attachments {
            guard let cid = item.contentID, item.mimeType.hasPrefix("image/"), item.size < 3_000_000,
                  html.contains("cid:\(cid)"),
                  case let .gmail(messageID, attachmentID) = item.source,
                  let data = try? await client.attachment(messageID: messageID, attachmentID: attachmentID) else { continue }
            html = html.replacingOccurrences(of: "cid:\(cid)", with: "data:\(item.mimeType);base64,\(data.base64EncodedString())")
        }
        body.html = html
    }

    private func autoProcessPGP() async {
        for message in messages {
            switch message.pgpKind {
            case .signedMIME, .inlineSigned:
                await verify(message.id)
            case .encryptedMIME, .inlineEncrypted:
                if pgp.cachedPassphrase(for: account) != nil { await decrypt(message.id) }
            case .none:
                break
            }
        }
    }

    private func verificationKeys(for message: ThreadMessage) -> [String] {
        [pgp.publicKey(forEmail: message.from)].compactMap { $0 }
    }

    private func update(_ id: String, _ change: (inout ThreadMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[index])
    }

    func toggleExpanded(_ id: String) {
        update(id) { $0.isExpanded.toggle() }
    }

    func requestDecrypt(_ id: String) async {
        guard pgp.ownKey(for: account) != nil else {
            errorMessage = PGPError.noPrivateKey.localizedDescription
            return
        }
        if pgp.cachedPassphrase(for: account) != nil {
            await decrypt(id)
        } else {
            passphraseTarget = id
        }
    }

    func submitPassphrase(_ passphrase: String) async {
        guard let target = passphraseTarget else { return }
        passphraseTarget = nil
        pgp.remember(passphrase: passphrase, for: account)
        await decrypt(target)
        if let message = messages.first(where: { $0.id == target }), case .failed = message.pgp {
            pgp.forgetPassphrases()
        }
    }

    private func decrypt(_ id: String) async {
        guard let message = messages.first(where: { $0.id == id }),
              let passphrase = pgp.cachedPassphrase(for: account) else { return }
        do {
            let privateKey = try pgp.privateKey(for: account)
            let keys = verificationKeys(for: message)
            if message.pgpKind == .inlineEncrypted {
                guard let armored = Self.armoredBlock(in: message.body.text ?? "", kind: "MESSAGE") else { throw PGPError.malformedMessage }
                let result = try await PGPEngine.shared.decrypt(armored: armored, privateKey: privateKey, passphrase: passphrase, verificationKeys: keys)
                update(id) {
                    $0.body = MailBody(html: nil, text: String(decoding: result.data, as: UTF8.self), attachments: [])
                    $0.pgp = .decrypted(result.signature, result.signer)
                }
                return
            }

            let root = MIMEParser.parse([UInt8](try await client.rawMessage(id)))
            guard let container = root.first(where: { $0.contentType == "multipart/encrypted" }),
                  let payload = container.parts.first(where: { $0.contentType != "application/pgp-encrypted" }) else {
                throw PGPError.malformedMessage
            }
            let armored = String(decoding: payload.body, as: UTF8.self)
            let result = try await PGPEngine.shared.decrypt(armored: armored, privateKey: privateKey, passphrase: passphrase, verificationKeys: keys)
            let inner = MIMEParser.parse([UInt8](result.data))
            var state = result.signature
            var signer = result.signer
            if state == .none, let signed = inner.first(where: { $0.contentType == "multipart/signed" }) {
                let verified = await Self.verifyDetached(signed, keys: keys)
                state = verified.state
                signer = verified.signer
            }
            update(id) {
                $0.body = MIMEParser.display(inner)
                $0.pgp = .decrypted(state, signer)
            }
        } catch {
            update(id) { $0.pgp = .failed(error.localizedDescription) }
        }
    }

    private func verify(_ id: String) async {
        guard let message = messages.first(where: { $0.id == id }) else { return }
        let keys = verificationKeys(for: message)
        do {
            if message.pgpKind == .inlineSigned {
                guard let block = Self.clearsignBlock(in: message.body.text ?? "") else { return }
                let result = try await PGPEngine.shared.verifyCleartext(armored: block, keys: keys)
                update(id) { $0.pgp = .signed(result.state, result.signer) }
                return
            }
            let root = MIMEParser.parse([UInt8](try await client.rawMessage(id)))
            guard let signed = root.first(where: { $0.contentType == "multipart/signed" }) else { return }
            let result = await Self.verifyDetached(signed, keys: keys)
            update(id) { $0.pgp = .signed(result.state, result.signer) }
        } catch {
            update(id) { $0.pgp = .signed(.invalid, "") }
        }
    }

    private static func verifyDetached(_ signed: MIMEEntity, keys: [String]) async -> (state: SignatureState, signer: String) {
        guard signed.parts.count >= 2,
              let signaturePart = signed.parts.first(where: { $0.contentType == "application/pgp-signature" }) else {
            return (.invalid, "")
        }
        let data = Data(MIMEParser.canonicalCRLF(signed.parts[0].raw))
        let signature = String(decoding: signaturePart.body, as: UTF8.self)
        do {
            return try await PGPEngine.shared.verifyDetached(data, signature: signature, keys: keys)
        } catch {
            return (.invalid, "")
        }
    }

    private static func armoredBlock(in text: String, kind: String) -> String? {
        guard let start = text.range(of: "-----BEGIN PGP \(kind)-----"),
              let end = text.range(of: "-----END PGP \(kind)-----", range: start.upperBound..<text.endIndex) else { return nil }
        return String(text[start.lowerBound..<end.upperBound])
    }

    private static func clearsignBlock(in text: String) -> String? {
        guard let start = text.range(of: "-----BEGIN PGP SIGNED MESSAGE-----"),
              let end = text.range(of: "-----END PGP SIGNATURE-----", range: start.upperBound..<text.endIndex) else { return nil }
        return String(text[start.lowerBound..<end.upperBound])
    }

    func attachmentData(_ item: MailAttachment) async throws -> Data {
        switch item.source {
        case let .local(data): return data
        case let .gmail(messageID, attachmentID): return try await client.attachment(messageID: messageID, attachmentID: attachmentID)
        }
    }

    func archive() async throws { try await client.modifyThread(threadID, remove: ["INBOX"]) }
    func trash() async throws { try await client.trashThread(threadID) }
}
