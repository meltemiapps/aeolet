import Foundation

/// What the mailbox, conversation, compose and new-mail code needs from an account. Gmail (through its API) and
/// IMAP/SMTP accounts both provide it, so every screen works the same way for both.
///
/// The shared value types are the Gmail-shaped ones the app already used (GmailLabel, GmailThread, GmailMessage,
/// ThreadSummary). For IMAP, folders become labels, and flags become the UNREAD and STARRED labels.
protocol MailService {
    var account: String { get }
    var features: MailFeatures { get }

    func labels() async throws -> [GmailLabel]
    /// One label with its unread count, such as INBOX for the Dock badge.
    func label(_ id: String) async throws -> GmailLabel
    func threads(labelID: String?, query: String?, pageToken: String?, limit: Int) async throws -> (items: [ThreadSummary], next: String?)
    func thread(_ id: String) async throws -> GmailThread
    func modifyThread(_ id: String, add: [String], remove: [String]) async throws
    func trashThread(_ id: String) async throws
    func rawMessage(_ id: String) async throws -> Data
    func attachment(messageID: String, attachmentID: String) async throws -> Data
    func metadata(messageID: String) async throws -> GmailMessage
    func send(message: Data, threadID: String?) async throws
    func saveDraft(message: Data, threadID: String?) async throws
    func senderDisplayName() async throws -> String?

    /// An opaque bookmark for "now", so the next check reports only newer inbox mail.
    func newMailBookmark() async throws -> String?
    /// New inbox messages since the bookmark, and the bookmark to store next. Throws GmailError.historyExpired
    /// when the bookmark can no longer be used and a new one must be taken.
    func newInboxMessageIDs(since bookmark: String) async throws -> (ids: [String], latest: String?)
}

struct MailFeatures {
    /// Gmail labels can be added to and removed from a conversation. IMAP folders can't.
    var labels: Bool
    /// Search looks through all mail (Gmail) rather than only the folder on screen (IMAP).
    var searchesAllMail: Bool
    /// Whose attachment limit it is, as in "over Gmail's 25 MB limit".
    var limitOwner: String
}

extension MailService {
    func threads(labelID: String?, query: String?, pageToken: String?) async throws -> (items: [ThreadSummary], next: String?) {
        try await threads(labelID: labelID, query: query, pageToken: pageToken, limit: 30)
    }

    func modifyThread(_ id: String, remove: [String]) async throws {
        try await modifyThread(id, add: [], remove: remove)
    }

    func modifyThread(_ id: String, add: [String]) async throws {
        try await modifyThread(id, add: add, remove: [])
    }
}

extension GmailClient: MailService {
    var features: MailFeatures { MailFeatures(labels: true, searchesAllMail: true, limitOwner: "Gmail's") }

    func newMailBookmark() async throws -> String? { try await profile().historyId }

    func newInboxMessageIDs(since bookmark: String) async throws -> (ids: [String], latest: String?) {
        try await addedInboxMessageIDs(since: bookmark)
    }
}

enum MailServices {
    /// The service for an account: IMAP if it was added as an IMAP account, otherwise Gmail.
    static func service(for account: String) -> any MailService {
        if let settings = AccountStore.mailAccount(account) { return IMAPService(settings: settings) }
        return GmailClient(account: account)
    }
}
