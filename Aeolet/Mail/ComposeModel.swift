import Foundation

struct ComposeContext: Identifiable {
    enum Mode { case new, reply, replyAll, forward }
    let id = UUID()
    let mode: Mode
    let source: ThreadMessage?

    static let new = ComposeContext(mode: .new, source: nil)
}

@MainActor
final class ComposeModel: ObservableObject {
    let account: String
    let context: ComposeContext
    private let client: GmailClient
    private let pgp = PGPStore.shared

    @Published var to = ""
    @Published var cc = ""
    @Published var bcc = ""
    @Published var subject = ""
    @Published var body = ""
    @Published var attachments: [OutgoingAttachment] = []
    @Published var encrypt = false
    @Published var sign = false
    @Published var isWorking = false
    @Published var errorMessage: String?
    @Published var needsPassphrase = false
    @Published var confirmPlaintextReply = false
    /// Set when attachments are refused for size, or photos or files can't be read.
    @Published var attachmentNotice: String?
    @Published var isAddingPhotos = false

    /// Settings > Attachments. Off by default: photos are sent as JPEG without location.
    static let keepPhotoOriginalsKey = "keepPhotoOriginals"

    private var plaintextReplyConfirmed = false

    init(account: String, context: ComposeContext) {
        self.account = account
        self.context = context
        client = GmailClient(account: account)
        prefill()
    }

    var canUsePGP: Bool { pgp.isEnabled && pgp.ownKey(for: account) != nil }
    var quotesEncryptedMessage: Bool { context.source?.wasEncrypted == true }

    var recipients: [String] { to.splitAddresses + cc.splitAddresses }

    var missingKeys: [String] {
        guard encrypt else { return [] }
        return recipients.filter { pgp.publicKey(forEmail: $0) == nil }
    }

    private func prefill() {
        guard let source = context.source else { return }
        let baseSubject = source.subject == "(No subject)" ? "" : source.subject
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        switch context.mode {
        case .reply, .replyAll:
            to = source.from
            if context.mode == .replyAll {
                let me = account.lowercased()
                let others = (source.to.splitAddresses + source.cc.splitAddresses).filter { $0.emailAddressOnly != me }
                cc = others.joined(separator: ", ")
            }
            subject = baseSubject.lowercased().hasPrefix("re:") ? baseSubject : "Re: \(baseSubject)"
            let quoted = source.body.plainText.components(separatedBy: .newlines).map { "> \($0)" }.joined(separator: "\n")
            body = "\n\nOn \(formatter.string(from: source.date)), \(source.from.displayNameOnly) wrote:\n\(quoted)"
        case .forward:
            subject = baseSubject.lowercased().hasPrefix("fwd:") ? baseSubject : "Fwd: \(baseSubject)"
            body = "\n\n---------- Forwarded message ----------\nFrom: \(source.from)\nDate: \(formatter.string(from: source.date))\nSubject: \(source.subject)\nTo: \(source.to)\n\n\(source.body.plainText)"
            Task { await loadForwardedAttachments(source) }
        case .new:
            break
        }

        if canUsePGP && source.wasEncrypted {
            encrypt = true
            sign = true
        }
    }

    private func loadForwardedAttachments(_ source: ThreadMessage) async {
        for item in source.body.attachments where item.contentID == nil || item.mimeType.hasPrefix("image/") == false {
            do {
                let data: Data
                switch item.source {
                case let .local(local): data = local
                case let .gmail(messageID, attachmentID): data = try await client.attachment(messageID: messageID, attachmentID: attachmentID)
                }
                add([OutgoingAttachment(filename: item.filename, mimeType: item.mimeType, data: data)])
            } catch {
                errorMessage = "Could not include \(item.filename)."
            }
        }
    }

    // MARK: Attachments

    var attachmentsTotal: Int { attachments.reduce(0) { $0 + $1.data.count } }
    var isOverAttachmentLimit: Bool { attachmentsTotal > AttachmentLimit.maxTotalBytes }

    /// Adds attachments in order while they fit within Gmail's limit, and explains any it refuses.
    func add(_ items: [OutgoingAttachment]) {
        var refused: [String] = []
        for item in items {
            if attachmentsTotal + item.data.count > AttachmentLimit.maxTotalBytes {
                refused.append(item.filename)
            } else {
                attachments.append(item)
            }
        }
        if !refused.isEmpty { attachmentNotice = AttachmentLimit.message(refused: refused, currentTotal: attachmentsTotal) }
    }

    func addPhotos(_ providers: [NSItemProvider]) async {
        guard !providers.isEmpty else { return }
        isAddingPhotos = true
        defer { isAddingPhotos = false }
        let keep = UserDefaults.standard.bool(forKey: Self.keepPhotoOriginalsKey)
        let (items, failed) = await PhotoAttachments.load(providers, keepOriginals: keep)
        add(items)
        if !failed.isEmpty, attachmentNotice == nil {
            attachmentNotice = "Could not add \(failed.joined(separator: ", ")). The photo may still be downloading from iCloud; try again in a moment."
        }
    }

    func addFiles(_ urls: [URL]) {
        let result = FileAttachments.load(urls, alreadyAttached: attachmentsTotal)
        attachments.append(contentsOf: result.attachments)
        if !result.tooLarge.isEmpty {
            attachmentNotice = AttachmentLimit.message(refused: result.tooLarge, currentTotal: attachmentsTotal)
        } else if !result.unreadable.isEmpty {
            attachmentNotice = "Could not read \(result.unreadable.joined(separator: ", ")). If it is in Google Drive or another cloud provider, check that it has downloaded."
        }
    }

    /// Display names from Gmail's sendAs settings, fetched once per account per launch.
    private static var senderNames: [String: String] = [:]

    /// The account's display name. If Gmail can't be asked (offline, say), the mail goes out with the bare address.
    private func senderName() async -> String? {
        if let cached = Self.senderNames[account] { return cached.isEmpty ? nil : cached }
        do {
            let name = try await client.senderDisplayName()
            Self.senderNames[account] = name ?? ""
            return name
        } catch {
            return nil
        }
    }

    private var isReply: Bool { context.mode == .reply || context.mode == .replyAll }

    private func buildMessage(passphrase: String?) async throws -> Data {
        let content = MIMEBuilder.contentEntity(text: body, attachments: attachments)
        let entity = try await pgp.protect(entity: content, account: account, recipients: recipients,
                                           encrypt: encrypt, sign: sign, passphrase: passphrase)
        let from = OutgoingHeaders.sender(account: account, displayName: await senderName())
        var headers = OutgoingHeaders(from: from, to: to.splitAddresses, cc: cc.splitAddresses, bcc: bcc.splitAddresses, subject: subject)
        if isReply, let source = context.source, !source.messageIDHeader.isEmpty {
            headers.inReplyTo = source.messageIDHeader
            headers.references = [source.references, source.messageIDHeader].filter { !$0.isEmpty }.joined(separator: " ")
        }
        let domain = account.split(separator: "@").last.map(String.init) ?? "localhost"
        return MIMEBuilder.message(headers: headers, entity: entity, senderDomain: domain)
    }

    /// Returns true when the message has been sent and the sheet can close.
    private var overLimitMessage: String {
        "Attachments total \(AttachmentLimit.format(attachmentsTotal)), over Gmail's \(AttachmentLimit.format(AttachmentLimit.maxTotalBytes)) limit. Remove some to send."
    }

    func send() async -> Bool {
        guard !recipients.isEmpty || !bcc.splitAddresses.isEmpty else {
            errorMessage = "Add at least one recipient."
            return false
        }
        guard !isOverAttachmentLimit else {
            errorMessage = overLimitMessage
            return false
        }
        if encrypt {
            guard bcc.splitAddresses.isEmpty else {
                errorMessage = "Remove Bcc to send encrypted. Encryption key IDs would reveal hidden recipients."
                return false
            }
            guard missingKeys.isEmpty else {
                errorMessage = PGPError.missingRecipientKeys(missingKeys).localizedDescription
                return false
            }
        } else if quotesEncryptedMessage && !plaintextReplyConfirmed {
            confirmPlaintextReply = true
            return false
        }

        var passphrase: String?
        if sign {
            passphrase = pgp.cachedPassphrase(for: account)
            if passphrase == nil {
                needsPassphrase = true
                return false
            }
        }

        isWorking = true
        defer { isWorking = false }
        do {
            let message = try await buildMessage(passphrase: passphrase)
            try await client.send(message: message, threadID: isReply ? context.source?.threadID : nil)
            return true
        } catch {
            if sign, "\(error)".lowercased().contains("passphrase") { pgp.forgetPassphrases() }
            errorMessage = error.userMessage
            return false
        }
    }

    func approvePlaintextReply() { plaintextReplyConfirmed = true }

    func submitPassphrase(_ value: String) { pgp.remember(passphrase: value, for: account) }

    /// Drafts are stored by Google in readable form, so they are refused for anything being encrypted.
    var canSaveDraft: Bool { !encrypt && !quotesEncryptedMessage }

    func saveDraft() async -> Bool {
        guard canSaveDraft else { return false }
        guard !isOverAttachmentLimit else {
            errorMessage = overLimitMessage
            return false
        }
        isWorking = true
        defer { isWorking = false }
        let wasSigning = sign
        sign = false
        defer { sign = wasSigning }
        do {
            let message = try await buildMessage(passphrase: nil)
            try await client.saveDraft(message: message, threadID: isReply ? context.source?.threadID : nil)
            return true
        } catch {
            errorMessage = error.userMessage
            return false
        }
    }
}
