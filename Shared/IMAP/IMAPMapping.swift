import Foundation

/// Identifies IMAP messages without any server-side state: the folder, its UIDVALIDITY and the UIDs.
/// A conversation's ID lists every UID in it, so opening, archiving or binning it needs no lookup.
struct IMAPRef: Codable, Hashable {
    var folder: String
    var validity: UInt32
    var uids: [UInt32]

    private enum CodingKeys: String, CodingKey {
        case folder = "f", validity = "v", uids = "u"
    }

    private static let prefix = "imap."

    var encoded: String {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return Self.prefix + data.base64URLEncoded
    }

    init(folder: String, validity: UInt32, uids: [UInt32]) {
        self.folder = folder
        self.validity = validity
        self.uids = uids
    }

    init?(_ text: String) {
        guard text.hasPrefix(Self.prefix), let data = Data(base64URL: String(text.dropFirst(Self.prefix.count))),
              let decoded = try? JSONDecoder().decode(IMAPRef.self, from: data), !decoded.uids.isEmpty else { return nil }
        self = decoded
    }

    func single(_ uid: UInt32) -> IMAPRef { IMAPRef(folder: folder, validity: validity, uids: [uid]) }
}

/// The few fields of a listed message that the mailbox needs, independent of the IMAP library.
struct IMAPListedMessage: Hashable {
    var uid: UInt32
    var from: String
    var subject: String
    var date: Date
    var isSeen: Bool
    var isFlagged: Bool
    var contentType: String?
    var messageID: String?
    var inReplyTo: String?
    var references: [String]
}

enum IMAPMapping {
    // MARK: Conversations

    /// Groups messages that reply to one another. Two messages share a conversation when their Message-ID,
    /// In-Reply-To or References overlap. Messages are compared only within one folder and one page.
    static func conversations(_ messages: [IMAPListedMessage]) -> [[IMAPListedMessage]] {
        var parent: [String: String] = [:]
        func find(_ key: String) -> String {
            var key = key
            while let next = parent[key], next != key { key = next }
            return key
        }
        func union(_ a: String, _ b: String) {
            let rootA = find(a), rootB = find(b)
            if rootA != rootB { parent[rootB] = rootA }
        }
        func keys(of message: IMAPListedMessage) -> [String] {
            let ids = ([message.messageID, message.inReplyTo].compactMap { $0 } + message.references)
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")).lowercased() }
                .filter { !$0.isEmpty }
            return ids.isEmpty ? ["uid:\(message.uid)"] : ids
        }

        for message in messages {
            let found = keys(of: message)
            for key in found where parent[key] == nil { parent[key] = key }
            for key in found.dropFirst() { union(found[0], key) }
        }
        var groups: [String: [IMAPListedMessage]] = [:]
        for message in messages { groups[find(keys(of: message)[0]), default: []].append(message) }
        return groups.values
            .map { $0.sorted { $0.date < $1.date } }
            .sorted { ($0.last?.date ?? .distantPast) > ($1.last?.date ?? .distantPast) }
    }

    /// A conversation in the shape ThreadSummary already reads.
    static func summary(_ group: [IMAPListedMessage], folder: String, validity: UInt32, folderLabel: String) -> ThreadSummary? {
        let ref = IMAPRef(folder: folder, validity: validity, uids: group.map(\.uid))
        let messages = group.map { item in
            GmailMessage(
                id: ref.single(item.uid).encoded, threadId: ref.encoded,
                labelIds: labels(folderLabel: folderLabel, seen: item.isSeen, flagged: item.isFlagged),
                snippet: "", internalDate: String(Int(item.date.timeIntervalSince1970 * 1000)), historyId: nil,
                payload: GmailPart(partId: nil, mimeType: nil, filename: nil, headers: [
                    GmailHeader(name: "From", value: item.from),
                    GmailHeader(name: "Subject", value: item.subject),
                ] + (item.contentType.map { [GmailHeader(name: "Content-Type", value: $0)] } ?? []), body: nil, parts: nil),
                raw: nil)
        }
        return ThreadSummary(thread: GmailThread(id: ref.encoded, snippet: "", messages: messages))
    }

    static func labels(folderLabel: String, seen: Bool, flagged: Bool) -> [String] {
        var labels = [folderLabel]
        if !seen { labels.append("UNREAD") }
        if flagged { labels.append("STARRED") }
        return labels
    }

    // MARK: Message bodies

    /// A raw RFC 822 message as the Gmail-style part tree the conversation view reads. Text parts carry their
    /// content; attachments carry their part path as the attachment ID, fetched from the same raw message on demand.
    static func message(raw: Data, id: String, threadID: String, labelIds: [String], internalDate: Date) -> GmailMessage {
        let root = MIMEParser.parse([UInt8](raw))
        return GmailMessage(
            id: id, threadId: threadID, labelIds: labelIds, snippet: nil,
            internalDate: String(Int(internalDate.timeIntervalSince1970 * 1000)), historyId: nil,
            payload: part(root, path: ""), raw: nil)
    }

    private static func part(_ entity: MIMEEntity, path: String) -> GmailPart {
        let headers = entity.headers.map { GmailHeader(name: $0.name, value: $0.value) }
        if !entity.parts.isEmpty {
            let children = entity.parts.enumerated().map { index, child in
                part(child, path: path.isEmpty ? "\(index + 1)" : "\(path).\(index + 1)")
            }
            return GmailPart(partId: path, mimeType: entity.contentType, filename: "", headers: headers,
                             body: GmailBody(size: 0, data: nil, attachmentId: nil), parts: children)
        }
        let disposition = MIMEParser.parameters(of: entity.header("Content-Disposition") ?? "")
        let filename = disposition.params["filename"] ?? entity.parameters["name"]
        let isAttachment = disposition.value.lowercased() == "attachment" || filename != nil
        let isText = entity.contentType == "text/plain" || entity.contentType == "text/html"
        let body: GmailBody
        if isText && !isAttachment {
            body = GmailBody(size: entity.body.count, data: Data(entity.body).base64URLEncoded, attachmentId: nil)
        } else {
            body = GmailBody(size: entity.body.count, data: nil, attachmentId: path.isEmpty ? "1" : path)
        }
        return GmailPart(partId: path, mimeType: entity.contentType, filename: filename ?? "", headers: headers,
                         body: body, parts: nil)
    }

    /// The decoded content of the part at a path such as "2.1", or of a single-part message for "1".
    static func attachment(raw: Data, path: String) -> Data? {
        var entity = MIMEParser.parse([UInt8](raw))
        if entity.parts.isEmpty { return path == "1" ? Data(entity.body) : nil }
        for component in path.split(separator: ".") {
            guard let index = Int(component), index >= 1, index <= entity.parts.count else { return nil }
            entity = entity.parts[index - 1]
        }
        return entity.parts.isEmpty ? Data(entity.body) : nil
    }

    // MARK: Sending

    /// The addresses in To, Cc and Bcc, which become the SMTP envelope recipients.
    static func recipients(of raw: Data) -> [String] {
        let root = MIMEParser.parse([UInt8](headerBlock(of: raw)) + [0x0D, 0x0A, 0x0D, 0x0A])
        var seen = Set<String>()
        return ["To", "Cc", "Bcc"]
            .flatMap { (root.header($0) ?? "").splitAddresses }
            .map { $0.emailAddressOnly.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// The message without its Bcc header, as it must be transmitted: hidden recipients get the mail through
    /// the SMTP envelope only, so nobody can read them from the message.
    static func removingBcc(from raw: Data) -> Data {
        let bytes = [UInt8](raw)
        let header = headerBlock(of: raw)
        let rest = bytes[header.count...]
        var kept: [String] = []
        var skipping = false
        for line in String(decoding: header, as: UTF8.self).components(separatedBy: "\r\n") {
            if let first = line.first, first == " " || first == "\t" {
                if !skipping { kept.append(line) }
                continue
            }
            skipping = line.lowercased().hasPrefix("bcc:")
            if !skipping { kept.append(line) }
        }
        return Data(kept.joined(separator: "\r\n").utf8) + Data(rest)
    }

    /// The Message-ID header's value, angle brackets included, or nil if the message has none.
    static func messageID(of raw: Data) -> String? {
        let root = MIMEParser.parse([UInt8](headerBlock(of: raw)) + [0x0D, 0x0A, 0x0D, 0x0A])
        guard let value = root.header("Message-ID")?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    /// The header lines up to, not including, the blank line.
    private static func headerBlock(of raw: Data) -> [UInt8] {
        let bytes = [UInt8](raw)
        let separator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        var index = 0
        while index + 4 <= bytes.count {
            if Array(bytes[index..<index + 4]) == separator { return Array(bytes[..<index]) }
            index += 1
        }
        return bytes
    }
}
