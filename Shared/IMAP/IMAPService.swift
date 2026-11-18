import Foundation
import SwiftMail

enum IMAPServiceError: LocalizedError {
    case folderMissing(String)
    case staleMessage
    case noRecipients

    var errorDescription: String? {
        switch self {
        case let .folderMissing(kind): return "This account has no \(kind) folder."
        case .staleMessage: return "This folder changed on the server. Refresh and try again."
        case .noRecipients: return "Add at least one recipient."
        }
    }
}

/// An IMAP/SMTP account. Talks only to the servers in its settings, always over TLS with full certificate
/// and host name checks, and sends the password only to them.
struct IMAPService: MailService {
    let settings: MailAccount

    init(settings: MailAccount) { self.settings = settings }

    var account: String { settings.email }

    var features: MailFeatures { MailFeatures(labels: false, searchesAllMail: false, limitOwner: "the") }

    private var session: IMAPSession { IMAPSessionPool.session(for: settings) }

    /// Messages per page. Kept small enough that a page of envelopes stays well inside one response.
    private static let pageSize = 40
    /// Search looks at this many of the newest messages, so the reply line stays inside the parser's limit.
    private static let searchWindow = 800

    // MARK: Folders

    func labels() async throws -> [GmailLabel] {
        try await session.run { server, folders in
            let unread = (try? await server.mailboxStatus(folders.inbox).unseenCount) ?? nil
            return folders.labels(inboxUnread: unread)
        }
    }

    func label(_ id: String) async throws -> GmailLabel {
        try await session.run { server, folders in
            let name = try folders.folder(forLabel: id)
            let unread = try await server.mailboxStatus(name).unseenCount
            return GmailLabel(id: id, name: folders.displayName(of: name), type: id == "INBOX" ? "system" : "user",
                              messagesUnread: unread, threadsUnread: nil)
        }
    }

    // MARK: Conversations

    func threads(labelID: String?, query: String?, pageToken: String?, limit: Int) async throws -> (items: [ThreadSummary], next: String?) {
        try await session.run { server, folders in
            let labelID = labelID ?? "INBOX"
            let folder = try folders.folder(forLabel: labelID)
            let selection = try await server.selectMailbox(folder)
            let validity = selection.uidValidity.value
            let total = selection.messageCount
            guard total > 0 else { return ([], nil) }

            var listed: [IMAPListedMessage]
            var next: String?
            if let query = query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
                let window = SequenceNumberSet(max(1, total - Self.searchWindow + 1)...total)
                let found: ExtendedSearchResult<SequenceNumber> = try await server.extendedSearch(identifierSet: window, criteria: [.text(query)])
                let numbers = (found.all?.toArray() ?? []).map(\.value).sorted(by: >).prefix(Self.pageSize)
                guard !numbers.isEmpty else { return ([], nil) }
                let set = SequenceNumberSet(numbers.map { SequenceNumber($0) })
                listed = try await Self.list(server, set)
            } else {
                let end = pageToken.flatMap(Int.init).map { min($0, total) } ?? total
                guard end >= 1 else { return ([], nil) }
                let start = max(1, end - Self.pageSize + 1)
                listed = try await Self.list(server, SequenceNumberSet(start...end))
                next = start > 1 ? String(start - 1) : nil
            }
            let summaries = IMAPMapping.conversations(listed).compactMap {
                IMAPMapping.summary($0, folder: folder, validity: validity, folderLabel: labelID)
            }
            return (summaries, next)
        }
    }

    private static func list(_ server: IMAPServer, _ set: SequenceNumberSet) async throws -> [IMAPListedMessage] {
        let infos = try await server.fetchMessageInfosBulk(
            using: set, options: [.envelope, .internalDate, .flags], headerFields: ["Content-Type", "References"])
        return infos.compactMap(listed)
    }

    private static func listed(_ info: MessageInfo) -> IMAPListedMessage? {
        guard let uid = info.uid?.value else { return nil }
        let from = info.fromAddresses.flatMap(\.mailboxes).map { address -> String in
            guard let name = address.name, !name.isEmpty else { return address.address }
            return "\(name) <\(address.address)>"
        }.joined(separator: ", ")
        let subject = info.subject ?? ""
        return IMAPListedMessage(
            uid: uid, from: from, subject: subject.isEmpty ? "" : subject,
            date: info.date ?? info.internalDate ?? Date(timeIntervalSince1970: 0),
            isSeen: info.flags.contains(.seen), isFlagged: info.flags.contains(.flagged),
            contentType: info.additionalFields?["content-type"],
            messageID: info.messageId?.description, inReplyTo: info.inReplyTo?.description,
            references: (info.references ?? []).map(\.description))
    }

    func thread(_ id: String) async throws -> GmailThread {
        guard let ref = IMAPRef(id) else { throw IMAPServiceError.staleMessage }
        return try await session.run { server, folders in
            try await Self.select(server, ref)
            let uids = UIDSet(ref.uids.map { UID($0) })
            let infos = try await server.fetchMessageInfosBulk(using: uids, options: [.flags, .internalDate])
            var messages: [GmailMessage] = []
            for info in infos.sorted(by: { ($0.internalDate ?? .distantPast) < ($1.internalDate ?? .distantPast) }) {
                guard let uid = info.uid else { continue }
                let raw = try await server.fetchRawMessage(identifier: uid)
                let messageID = ref.single(uid.value).encoded
                await IMAPRawCache.shared.store(raw, for: messageID)
                let label = folders.label(forFolder: ref.folder)
                messages.append(IMAPMapping.message(
                    raw: raw, id: messageID, threadID: id,
                    labelIds: IMAPMapping.labels(folderLabel: label, seen: info.flags.contains(.seen), flagged: info.flags.contains(.flagged)),
                    internalDate: info.internalDate ?? Date()))
            }
            return GmailThread(id: id, snippet: nil, messages: messages)
        }
    }

    private static func select(_ server: IMAPServer, _ ref: IMAPRef) async throws {
        let selection = try await server.selectMailbox(ref.folder)
        guard selection.uidValidity.value == ref.validity else { throw IMAPServiceError.staleMessage }
    }

    /// UNREAD and STARRED become the \Seen and \Flagged flags. Removing INBOX archives, adding SPAM moves to Junk.
    /// Other Gmail labels have no IMAP equivalent and are ignored (the label menu is hidden for IMAP accounts).
    func modifyThread(_ id: String, add: [String], remove: [String]) async throws {
        guard let ref = IMAPRef(id) else { throw IMAPServiceError.staleMessage }
        try await session.run { server, _ in
            try await Self.select(server, ref)
            let uids = UIDSet(ref.uids.map { UID($0) })
            if add.contains("UNREAD") { try await server.store(flags: [.seen], on: uids, operation: .remove) }
            if remove.contains("UNREAD") { try await server.store(flags: [.seen], on: uids, operation: .add) }
            if add.contains("STARRED") { try await server.store(flags: [.flagged], on: uids, operation: .add) }
            if remove.contains("STARRED") { try await server.store(flags: [.flagged], on: uids, operation: .remove) }
            if add.contains("SPAM") {
                guard let junk = try? await server.junkFolder else { throw IMAPServiceError.folderMissing("Junk") }
                if junk.name != ref.folder { try await server.move(messages: uids, to: junk.name) }
            } else if add.contains("TRASH") {
                try await Self.moveToTrash(server, uids: uids, from: ref.folder)
            } else if remove.contains("INBOX") {
                guard let archive = try? await server.archiveFolder else { throw IMAPServiceError.folderMissing("Archive") }
                if archive.name != ref.folder { try await server.move(messages: uids, to: archive.name) }
            }
        }
    }

    /// Moves to the server's Trash. Never deletes permanently: mail already in Trash stays there.
    func trashThread(_ id: String) async throws {
        guard let ref = IMAPRef(id) else { throw IMAPServiceError.staleMessage }
        try await session.run { server, _ in
            try await Self.select(server, ref)
            try await Self.moveToTrash(server, uids: UIDSet(ref.uids.map { UID($0) }), from: ref.folder)
        }
    }

    private static func moveToTrash(_ server: IMAPServer, uids: UIDSet, from folder: String) async throws {
        guard let trash = try? await server.trashFolder else { throw IMAPServiceError.folderMissing("Trash") }
        if trash.name != folder { try await server.move(messages: uids, to: trash.name) }
    }

    // MARK: Messages

    func rawMessage(_ id: String) async throws -> Data {
        if let cached = await IMAPRawCache.shared.raw(for: id) { return cached }
        guard let ref = IMAPRef(id), let uid = ref.uids.first else { throw IMAPServiceError.staleMessage }
        let raw = try await session.run { server, _ in
            try await Self.select(server, ref)
            return try await server.fetchRawMessage(identifier: UID(uid))
        }
        await IMAPRawCache.shared.store(raw, for: id)
        return raw
    }

    func attachment(messageID: String, attachmentID: String) async throws -> Data {
        let raw = try await rawMessage(messageID)
        guard let data = IMAPMapping.attachment(raw: raw, path: attachmentID) else { throw IMAPServiceError.staleMessage }
        return data
    }

    func metadata(messageID: String) async throws -> GmailMessage {
        guard let ref = IMAPRef(messageID), let uid = ref.uids.first else { throw IMAPServiceError.staleMessage }
        return try await session.run { server, _ in
            try await Self.select(server, ref)
            guard let info = try await server.fetchMessageInfo(for: UID(uid), options: [.envelope, .flags]),
                  let item = Self.listed(info) else { throw IMAPServiceError.staleMessage }
            return GmailMessage(
                id: messageID, threadId: messageID, labelIds: nil, snippet: nil, internalDate: nil, historyId: nil,
                payload: GmailPart(partId: nil, mimeType: nil, filename: nil, headers: [
                    GmailHeader(name: "From", value: item.from), GmailHeader(name: "Subject", value: item.subject),
                ], body: nil, parts: nil),
                raw: nil)
        }
    }

    // MARK: Sending

    func send(message: Data, threadID: String?) async throws {
        let recipients = IMAPMapping.recipients(of: message)
        guard !recipients.isEmpty else { throw IMAPServiceError.noRecipients }
        try await SMTPSender.send(IMAPMapping.removingBcc(from: message), from: settings.email, to: recipients, settings: settings)
        // Most servers do not file what SMTP sends, so the copy in Sent is added here. A failure to file it
        // must not look like a failure to send.
        try? await session.run { server, _ in
            guard let sent = try? await server.sentFolder else { return }
            try await server.append(rawMessage: String(decoding: message, as: UTF8.self), to: sent.name, flags: [.seen], internalDate: Date())
        }
    }

    func saveDraft(message: Data, threadID: String?) async throws {
        try await session.run { server, _ in
            guard let drafts = try? await server.draftsFolder else { throw IMAPServiceError.folderMissing("Drafts") }
            try await server.append(rawMessage: String(decoding: message, as: UTF8.self), to: drafts.name, flags: [.draft, .seen], internalDate: Date())
        }
    }

    func senderDisplayName() async throws -> String? {
        let name = settings.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    // MARK: New mail

    /// "UIDVALIDITY:UIDNEXT" of the inbox.
    func newMailBookmark() async throws -> String? {
        try await session.run { server, folders in
            let status = try await server.mailboxStatus(folders.inbox)
            guard let validity = status.uidValidity?.value, let next = status.uidNext?.value else { return nil }
            return "\(validity):\(next)"
        }
    }

    func newInboxMessageIDs(since bookmark: String) async throws -> (ids: [String], latest: String?) {
        let parts = bookmark.split(separator: ":").compactMap { UInt32($0) }
        guard parts.count == 2 else { throw GmailError.historyExpired }
        return try await session.run { server, folders in
            let inbox = folders.inbox
            let selection = try await server.selectMailbox(inbox)
            let validity = selection.uidValidity.value
            guard validity == parts[0] else { throw GmailError.historyExpired }
            let latest = "\(validity):\(selection.uidNext.value)"
            guard selection.uidNext.value > parts[1] else { return ([], latest) }
            let infos = try await server.fetchMessageInfos(uidRange: UID(parts[1])..., options: [.flags])
            let ids = infos
                .filter { ($0.uid?.value ?? 0) >= parts[1] && !$0.flags.contains(.seen) }
                .compactMap { $0.uid?.value }
                .map { IMAPRef(folder: inbox, validity: validity, uids: [$0]).encoded }
            return (ids, latest)
        }
    }
}

// MARK: - Connections

/// One logged-in connection per account, reused across screens and closed when the account is removed.
enum IMAPSessionPool {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sessions: [String: IMAPSession] = [:]

    static func session(for settings: MailAccount) -> IMAPSession {
        lock.lock()
        defer { lock.unlock() }
        if let existing = sessions[settings.id], existing.settings == settings { return existing }
        let session = IMAPSession(settings: settings)
        sessions[settings.id] = session
        return session
    }

    static func close(_ email: String) async {
        let session = lock.withLock { sessions.removeValue(forKey: email.lowercased()) }
        await session?.close()
    }
}

/// The account's folders, as the mailbox shows them.
struct IMAPFolders: Sendable {
    let all: [Mailbox.Info]
    let inbox: String
    let special: [String: String]

    init(server: IMAPServer) async throws {
        try await server.listSpecialUseMailboxes()
        all = await server.mailboxes.filter(\.isSelectable)
        inbox = (try? await server.inboxFolder.name) ?? "INBOX"
        var special: [String: String] = ["INBOX": inbox]
        if let name = try? await server.sentFolder.name { special["SENT"] = name }
        if let name = try? await server.draftsFolder.name { special["DRAFT"] = name }
        if let name = try? await server.junkFolder.name { special["SPAM"] = name }
        if let name = try? await server.trashFolder.name { special["TRASH"] = name }
        self.special = special
    }

    func folder(forLabel id: String) throws -> String {
        if let name = special[id] { return name }
        if id.hasPrefix("folder:") { return String(id.dropFirst("folder:".count)) }
        throw IMAPServiceError.folderMissing(id.capitalized)
    }

    func label(forFolder name: String) -> String {
        special.first { $0.value == name }?.key ?? "folder:\(name)"
    }

    func displayName(of folder: String) -> String {
        guard let info = all.first(where: { $0.name == folder }), let delimiter = info.hierarchyDelimiter, !delimiter.isEmpty else { return folder }
        return folder.components(separatedBy: delimiter).joined(separator: " / ")
    }

    /// System folders use Gmail's label IDs, so they get the usual names, icons and order.
    func labels(inboxUnread: Int?) -> [GmailLabel] {
        var result = special.map { id, _ in
            GmailLabel(id: id, name: id, type: "system", messagesUnread: id == "INBOX" ? inboxUnread : nil, threadsUnread: nil)
        }
        let specialNames = Set(special.values)
        for info in all where !specialNames.contains(info.name) && info.name.uppercased() != "INBOX" {
            result.append(GmailLabel(id: "folder:\(info.name)", name: displayName(of: info.name), type: "user",
                                     messagesUnread: nil, threadsUnread: nil))
        }
        return result.sorted {
            $0.sortRank != $1.sortRank ? $0.sortRank < $1.sortRank
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}

/// Serialises everything on one connection: IMAP has one selected folder at a time, so two screens must
/// not interleave their SELECT and FETCH commands.
actor IMAPSession {
    let settings: MailAccount
    private var server: IMAPServer?
    private var folders: IMAPFolders?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(settings: MailAccount) { self.settings = settings }

    func run<T>(_ body: (IMAPServer, IMAPFolders) async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        do {
            let (server, folders) = try await connected()
            return try await body(server, folders)
        } catch {
            // A dropped connection is reopened once. Anything else (a wrong password, a refused command) is reported.
            guard let server, !(await server.isConnected) else { throw error }
            self.server = nil
            let (fresh, folders) = try await connected()
            return try await body(fresh, folders)
        }
    }

    private func connected() async throws -> (IMAPServer, IMAPFolders) {
        if let server, let folders, await server.isConnected { return (server, folders) }
        let fresh = try await IMAPLogin.connect(settings)
        let found = try await IMAPFolders(server: fresh)
        server = fresh
        folders = found
        return (fresh, found)
    }

    func close() async {
        await acquire()
        defer { release() }
        if let server { try? await server.disconnect() }
        server = nil
        folders = nil
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

/// Opening connections. Both protocols use the same rules: TLS always, certificates and host names always
/// checked, TLS 1.2 or later, and credentials sent only after TLS is up.
enum IMAPLogin {
    static func transport(_ security: ConnectionSecurity) -> MailTransportSecurity {
        switch security {
        case .tls: return .implicitTLS
        case .startTLS: return .startTLS
        }
    }

    static func connect(_ settings: MailAccount, password: String? = nil) async throws -> IMAPServer {
        MailLogging.silence()
        let server = IMAPServer(
            host: settings.imap.host, port: settings.imap.port,
            transportSecurity: transport(settings.imap.security),
            certificateVerificationPolicy: .fullVerification, minimumTLSVersion: .tlsv12)
        do {
            try await server.connect()
            try await server.login(username: settings.username, password: password ?? AccountStore.password(for: settings.email))
        } catch {
            try? await server.disconnect()
            throw error
        }
        return server
    }
}

enum SMTPSender {
    static func connect(_ settings: MailAccount, password: String? = nil) async throws -> SMTPServer {
        MailLogging.silence()
        let server = SMTPServer(
            host: settings.smtp.host, port: settings.smtp.port,
            transportSecurity: IMAPLogin.transport(settings.smtp.security),
            certificateVerificationPolicy: .fullVerification, minimumTLSVersion: .tlsv12)
        do {
            try await server.connect()
            try await server.login(username: settings.username, password: password ?? AccountStore.password(for: settings.email))
        } catch {
            try? await server.disconnect()
            throw error
        }
        return server
    }

    static func send(_ message: Data, from sender: String, to recipients: [String], settings: MailAccount) async throws {
        let server = try await connect(settings)
        defer { Task { try? await server.disconnect() } }
        _ = try await server.sendRawMessage(message, from: EmailAddress(address: sender),
                                            to: recipients.map { EmailAddress(address: $0) })
    }
}

/// Raw messages of recently opened conversations, in memory only, so attachments and PGP don't download a
/// message twice. Never written to disk.
actor IMAPRawCache {
    static let shared = IMAPRawCache()
    private var items: [(id: String, data: Data)] = []
    private let limit = 24

    func raw(for id: String) -> Data? { items.first { $0.id == id }?.data }

    func store(_ data: Data, for id: String) {
        items.removeAll { $0.id == id }
        items.append((id, data))
        if items.count > limit { items.removeFirst(items.count - limit) }
    }

    func removeAll() { items.removeAll() }
}
