import Foundation

struct GmailHeader: Codable, Hashable {
    let name: String
    let value: String
}

struct GmailBody: Codable, Hashable {
    let size: Int?
    let data: String?
    let attachmentId: String?
}

struct GmailPart: Codable, Hashable {
    let partId: String?
    let mimeType: String?
    let filename: String?
    let headers: [GmailHeader]?
    let body: GmailBody?
    let parts: [GmailPart]?

    func header(_ name: String) -> String? {
        headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

struct GmailMessage: Codable, Hashable, Identifiable {
    let id: String
    let threadId: String?
    let labelIds: [String]?
    let snippet: String?
    let internalDate: String?
    let historyId: String?
    let payload: GmailPart?
    let raw: String?

    func header(_ name: String) -> String? { payload?.header(name) }

    var date: Date {
        Date(timeIntervalSince1970: (Double(internalDate ?? "0") ?? 0) / 1000)
    }
}

struct GmailThread: Codable {
    let id: String
    let snippet: String?
    let messages: [GmailMessage]?
}

struct GmailThreadList: Codable {
    let threads: [GmailThread]?
    let nextPageToken: String?
}

struct GmailLabel: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let type: String?
    let messagesUnread: Int?

    var displayName: String {
        guard type == "system" else { return name }
        switch id {
        case "INBOX": return "Inbox"
        case "SENT": return "Sent"
        case "DRAFT": return "Drafts"
        case "SPAM": return "Spam"
        case "TRASH": return "Bin"
        case "STARRED": return "Starred"
        case "IMPORTANT": return "Important"
        default: return name.capitalized
        }
    }

    var symbol: String {
        switch id {
        case "INBOX": return "tray"
        case "SENT": return "paperplane"
        case "DRAFT": return "doc"
        case "SPAM": return "exclamationmark.octagon"
        case "TRASH": return "trash"
        case "STARRED": return "star"
        case "IMPORTANT": return "flag"
        default: return "tag"
        }
    }

    /// Hides Gmail's internal category and state labels from the folder list.
    var isUserFacing: Bool {
        if type != "system" { return true }
        return ["INBOX", "STARRED", "IMPORTANT", "SENT", "DRAFT", "SPAM", "TRASH"].contains(id)
    }

    var sortRank: Int {
        ["INBOX", "STARRED", "IMPORTANT", "SENT", "DRAFT", "SPAM", "TRASH"].firstIndex(of: id) ?? 100
    }
}

struct GmailProfile: Codable {
    let emailAddress: String
    let historyId: String?
}

struct GmailHistoryResponse: Codable {
    struct Added: Codable { let message: GmailMessage }
    struct Record: Codable { let messagesAdded: [Added]? }
    let history: [Record]?
    let historyId: String?
}

struct ThreadSummary: Codable, Identifiable, Hashable {
    let id: String
    var sender: String
    var subject: String
    var snippet: String
    var date: Date
    var isUnread: Bool
    var isStarred: Bool
    var messageCount: Int
    var labelIds: [String]
    /// The latest message's Content-Type. Optional so summaries cached before it existed still decode.
    var contentType: String?

    /// What the list shows under the subject. PGP mail gets a plain description instead of armour.
    enum Preview: Equatable {
        case text(String), encrypted, signed
    }

    var preview: Preview { Self.preview(snippet: snippet, contentType: contentType) }

    static func preview(snippet: String, contentType: String?) -> Preview {
        let type = contentType?.lowercased() ?? ""
        let text = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        if type.hasPrefix("multipart/encrypted") || text.hasPrefix("-----BEGIN PGP MESSAGE-----") { return .encrypted }
        if type.hasPrefix("multipart/signed") || text.hasPrefix("-----BEGIN PGP SIGNED MESSAGE-----") { return .signed }
        return .text(snippet)
    }

    init?(thread: GmailThread) {
        guard let messages = thread.messages, let last = messages.last, let first = messages.first else { return nil }
        id = thread.id
        let names = messages.compactMap { $0.header("From")?.displayNameOnly }
        var unique: [String] = []
        for name in names where !unique.contains(name) { unique.append(name) }
        sender = unique.prefix(3).joined(separator: ", ")
        let rawSubject = first.header("Subject") ?? ""
        subject = rawSubject.isEmpty ? "(No subject)" : rawSubject
        snippet = (last.snippet ?? thread.snippet ?? "").htmlEntitiesDecoded
        date = last.date
        let labels = Set(messages.flatMap { $0.labelIds ?? [] })
        labelIds = Array(labels)
        isUnread = labels.contains("UNREAD")
        isStarred = labels.contains("STARRED")
        messageCount = messages.count
        contentType = last.header("Content-Type")
    }
}
