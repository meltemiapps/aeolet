#if DEBUG
import Foundation
import UIKit

/// Test-only stand-in for Google, compiled into Debug builds only (and excluded from Release by file name too).
/// Launch with -AeoletMockGmail and every request from Network sessions is answered here instead of by Google.
///
/// Optional launch arguments and environment:
/// - `-AeoletResetState`: wipes Keychain items, private files and preferences before the app starts.
/// - `-AeoletDisableAnimations`: turns UIKit animations off to make UI tests faster and steadier.
/// - `AEOLET_MOCK_FAULT`: `401`, `403`, `429`, `500`, `missingField` (applied to the thread list) or `offline` (every request).
enum MockGmail {
    static let isActive = ProcessInfo.processInfo.arguments.contains("-AeoletMockGmail")
    static let fault = ProcessInfo.processInfo.environment["AEOLET_MOCK_FAULT"].flatMap { $0.isEmpty ? nil : $0 }

    static func install(into configuration: URLSessionConfiguration) {
        guard isActive else { return }
        configuration.protocolClasses = [MockGmailProtocol.self] + (configuration.protocolClasses ?? [])
    }

    /// Runs before any model loads, so a reset leaves nothing from earlier runs behind.
    static func prepareLaunch() {
        guard isActive else { return }
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-AeoletResetState") {
            KeychainStore.deleteAll()
            PrivateFile.deleteAll()
            if let domain = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: domain) }
        }
        if arguments.contains("-AeoletDisableAnimations") { UIView.setAnimationsEnabled(false) }
        _ = MockGmailServer.shared
    }

    /// Stands in for Google's sign-in page: signs in the first mock account that isn't signed in yet.
    static func signInCallback(state: String) async -> URL {
        let existing = Set(await TokenStore.shared.accounts())
        let accounts = MockGmailServer.shared.accountAddresses
        let account = accounts.first { !existing.contains($0) } ?? accounts[0]
        MockGmailServer.shared.record("SIGNIN account=\(account)")
        var components = URLComponents(string: AppConfig.redirectURI)!
        components.queryItems = [URLQueryItem(name: "state", value: state), URLQueryItem(name: "code", value: "mock-code-\(account)")]
        return components.url!
    }

    /// A file the compose screen can attach without the system document picker.
    static let sampleAttachment = OutgoingAttachment(filename: "Itinerary.pdf", mimeType: "application/pdf", data: MockGmailFixtures.pdf(title: "Itinerary"))
}

// MARK: - URLProtocol

final class MockGmailProtocol: URLProtocol {
    /// Claims every request, so a mock run can never reach the real network.
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.body(of: request)
        switch MockGmailServer.shared.handle(request, body: body) {
        case let .failure(error):
            client?.urlProtocol(self, didFailWithError: error)
        case let .success(reply):
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json; charset=UTF-8"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

// MARK: - Server

struct MockReply {
    let status: Int
    let data: Data

    static func json(_ object: Any, status: Int = 200) -> MockReply {
        MockReply(status: status, data: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data())
    }

    static func googleError(_ status: Int, _ message: String, reason: String) -> MockReply {
        json(["error": ["code": status, "message": message, "errors": [["message": message, "domain": "global", "reason": reason]],
                        "status": reason.uppercased()]], status: status)
    }
}

final class MockGmailServer: @unchecked Sendable {
    static let shared = MockGmailServer()
    static let didChange = Notification.Name("MockGmailServerDidChange")

    struct Message {
        let id: String
        var threadID: String
        var labels: Set<String>
        let raw: [UInt8]
        let entity: MIMEEntity
        let date: Date

        func header(_ name: String) -> String { MIMEParser.decodeEncodedWords(entity.header(name) ?? "") }
    }

    struct Label {
        let id: String
        let name: String
        let type: String
    }

    final class Mailbox {
        let address: String
        /// The name Gmail's sendAs settings report for the primary address.
        let displayName: String
        var messages: [Message] = []
        var labels: [Label]
        init(address: String, displayName: String, labels: [Label]) {
            self.address = address
            self.displayName = displayName
            self.labels = labels
        }
    }

    private let lock = NSRecursiveLock()
    private var mailboxes: [String: Mailbox] = [:]
    private var accessTokens: [String: String] = [:]
    private var revoked: Set<String> = []
    private var counter = 0
    private var inboxListings: [String: Int] = [:]
    private(set) var log: [String] = []
    private var sequence = 0
    private(set) var accountAddresses: [String] = []

    private init() {
        let built = MockGmailFixtures.mailboxes(server: self)
        accountAddresses = built.map(\.address)
        for mailbox in built { mailboxes[mailbox.address] = mailbox }
    }

    func record(_ line: String) {
        NSLog("MockGmail %@", line)
        lock.lock()
        sequence += 1
        log.append("#\(sequence) \(line)")
        if log.count > 200 { log.removeFirst(log.count - 200) }
        lock.unlock()
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: nil) }
    }

    private func nextID(_ prefix: String) -> String {
        counter += 1
        return "\(prefix)\(String(format: "%04d", counter))"
    }

    // MARK: Routing

    func handle(_ request: URLRequest, body: Data) -> Result<MockReply, Error> {
        lock.lock()
        defer { lock.unlock() }
        guard let url = request.url, let host = url.host else { return .failure(URLError(.badURL)) }
        let method = request.httpMethod ?? "GET"

        if MockGmail.fault == "offline" {
            record("OFFLINE \(method) \(url.path)")
            return .failure(URLError(.notConnectedToInternet))
        }

        switch host {
        case "oauth2.googleapis.com":
            return .success(handleOAuth(path: url.path, form: Self.form(body)))
        case "gmail.googleapis.com":
            return handleGmail(request, method: method, url: url, body: body)
        case "keys.openpgp.org":
            record("KEYSERVER \(url.path)")
            return .success(MockReply(status: 404, data: Data("Not found".utf8)))
        default:
            record("UNHANDLED \(method) \(url.absoluteString)")
            return .failure(URLError(.cannotFindHost))
        }
    }

    private static func form(_ body: Data) -> [String: String] {
        var out: [String: String] = [:]
        for pair in String(decoding: body, as: UTF8.self).split(separator: "&") {
            let pieces = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            if pieces.count == 2 { out[pieces[0]] = pieces[1] }
        }
        return out
    }

    private func handleOAuth(path: String, form: [String: String]) -> MockReply {
        switch path {
        case "/token":
            let account: String
            if form["grant_type"] == "authorization_code", let code = form["code"], code.hasPrefix("mock-code-") {
                account = String(code.dropFirst("mock-code-".count))
            } else if form["grant_type"] == "refresh_token", let refresh = form["refresh_token"], refresh.hasPrefix("mock-refresh-"),
                      !revoked.contains(refresh) {
                account = String(refresh.dropFirst("mock-refresh-".count))
            } else {
                record("TOKEN rejected grant=\(form["grant_type"] ?? "")")
                return .json(["error": "invalid_grant", "error_description": "Token has been expired or revoked."], status: 400)
            }
            guard mailboxes[account] != nil else {
                return .json(["error": "invalid_grant", "error_description": "Unknown account."], status: 400)
            }
            let access = "mock-access-\(account)-\(nextID(""))"
            accessTokens[access] = account
            var reply: [String: Any] = ["access_token": access, "expires_in": 3599, "token_type": "Bearer", "scope": AppConfig.gmailScope]
            if form["grant_type"] == "authorization_code" { reply["refresh_token"] = "mock-refresh-\(account)" }
            record("TOKEN grant=\(form["grant_type"] ?? "") account=\(account)")
            return .json(reply)
        case "/revoke":
            let token = form["token"] ?? ""
            revoked.insert(token)
            accessTokens = accessTokens.filter { !token.hasSuffix($0.value) }
            record("REVOKE token=\(token)")
            return .json([:])
        default:
            return .json(["error": "not_found"], status: 404)
        }
    }

    private func handleGmail(_ request: URLRequest, method: String, url: URL, body: Data) -> Result<MockReply, Error> {
        let bearer = (request.value(forHTTPHeaderField: "Authorization") ?? "").replacingOccurrences(of: "Bearer ", with: "")
        guard let account = accessTokens[bearer], let mailbox = mailboxes[account] else {
            record("\(method) \(url.path) unauthorised")
            return .success(.googleError(401, MockGmailFixtures.message401, reason: "authError"))
        }
        let query = Dictionary(grouping: URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [], by: \.name)
            .mapValues { $0.compactMap(\.value) }
        let path = url.path
        let isUpload = path.hasPrefix("/upload/")
        let route = path.replacingOccurrences(of: "/upload", with: "").replacingOccurrences(of: "/gmail/v1/users/me", with: "")
        let parts = route.split(separator: "/").map(String.init)

        if method == "GET", route == "/threads", let fault = MockGmail.fault, let reply = faultReply(fault) {
            record("FAULT \(fault) GET /threads account=\(account)")
            return .success(reply)
        }

        switch (method, parts.first ?? "", parts.count) {
        case ("GET", "profile", 1):
            record("GET /profile account=\(account)")
            return .success(.json(["emailAddress": account, "messagesTotal": mailbox.messages.count,
                                   "threadsTotal": Set(mailbox.messages.map(\.threadID)).count, "historyId": "\(1000 + counter)"]))
        case ("GET", "settings", 2) where parts[1] == "sendAs":
            record("GET /settings/sendAs account=\(account)")
            return .success(.json(["sendAs": [
                ["sendAsEmail": "\(account.split(separator: "@")[0])+alias@example.com", "displayName": "Alias", "isPrimary": false, "isDefault": false],
                ["sendAsEmail": account, "displayName": mailbox.displayName, "replyToAddress": "", "signature": "",
                 "isPrimary": true, "isDefault": true, "treatAsAlias": false],
            ]]))
        case ("GET", "labels", 1):
            return .success(.json(["labels": mailbox.labels.map { ["id": $0.id, "name": $0.name, "type": $0.type] }]))
        case ("GET", "labels", 2):
            guard let label = mailbox.labels.first(where: { $0.id == parts[1] }) else { return .success(notFound()) }
            let unread = Set(mailbox.messages.filter { $0.labels.contains(label.id) && $0.labels.contains("UNREAD") }.map(\.threadID)).count
            return .success(.json(["id": label.id, "name": label.name, "type": label.type, "messagesUnread": unread, "threadsUnread": unread]))
        case ("GET", "threads", 1):
            return .success(listThreads(mailbox, query: query))
        case ("GET", "threads", 2):
            let messages = mailbox.messages.filter { $0.threadID == parts[1] }.sorted { $0.date < $1.date }
            guard !messages.isEmpty else { return .success(notFound()) }
            let format = query["format"]?.first ?? "full"
            if format == "full" { record("GET /threads/\(parts[1]) account=\(account)") }
            return .success(.json(["id": parts[1], "historyId": "\(1000 + counter)", "snippet": snippet(messages.last!),
                                   "messages": messages.map { json($0, format: format, headers: query["metadataHeaders"]) }]))
        case ("POST", "threads", 3):
            return .success(modifyThread(mailbox, id: parts[1], action: parts[2], body: body))
        case ("GET", "messages", 2):
            guard let message = mailbox.messages.first(where: { $0.id == parts[1] }) else { return .success(notFound()) }
            let format = query["format"]?.first ?? "full"
            if format == "raw" { record("GET /messages/\(message.id) format=raw account=\(account)") }
            return .success(.json(json(message, format: format)))
        case ("GET", "messages", 4) where parts[2] == "attachments":
            guard let message = mailbox.messages.first(where: { $0.id == parts[1] }),
                  let data = attachments(of: message)[parts[3]] else { return .success(notFound()) }
            record("GET attachment \(parts[3]) account=\(account)")
            return .success(.json(["size": data.count, "data": Data(data).base64URLEncoded]))
        case ("POST", "messages", 2) where isUpload && parts[1] == "send":
            return .success(receiveUpload(mailbox, request: request, body: body, draft: false))
        case ("POST", "drafts", 1) where isUpload:
            return .success(receiveUpload(mailbox, request: request, body: body, draft: true))
        case ("GET", "history", 1):
            return .success(.json(["historyId": "\(1000 + counter)"]))
        default:
            record("UNHANDLED \(method) \(path)")
            return .success(notFound())
        }
    }

    private func notFound() -> MockReply { .googleError(404, "Requested entity was not found.", reason: "notFound") }

    private func faultReply(_ fault: String) -> MockReply? {
        switch fault {
        case "401": return .googleError(401, MockGmailFixtures.message401, reason: "authError")
        case "403": return .googleError(403, MockGmailFixtures.message403, reason: "accessNotConfigured")
        case "429": return .googleError(429, MockGmailFixtures.message429, reason: "rateLimitExceeded")
        case "500": return .googleError(500, MockGmailFixtures.message500, reason: "backendError")
        case "missingField": return .json(["threads": [["snippet": "A thread without an id"]], "resultSizeEstimate": 1])
        default: return nil
        }
    }

    // MARK: Threads

    private func listThreads(_ mailbox: Mailbox, query: [String: [String]]) -> MockReply {
        let label = query["labelIds"]?.first
        let search = (query["q"]?.first ?? "").lowercased()
        let limit = Int(query["maxResults"]?.first ?? "") ?? 100
        let offset = Int(query["pageToken"]?.first ?? "") ?? 0
        let showsBin = label == "TRASH" || label == "SPAM"
        if label == "INBOX" && offset == 0 && search.isEmpty {
            inboxListings[mailbox.address, default: 0] += 1
            // The second inbox load (a pull to refresh) brings in one new message, like real mail arriving.
            if inboxListings[mailbox.address] == 2 {
                store(raw: MockGmailFixtures.arrival(for: mailbox.address), in: mailbox, labels: ["INBOX", "UNREAD"], threadID: nil)
            }
        }

        let visible = mailbox.messages.filter { message in
            if !showsBin && (message.labels.contains("TRASH") || message.labels.contains("SPAM")) { return false }
            if let label, !message.labels.contains(label) { return false }
            if !search.isEmpty {
                let text = [message.header("From"), message.header("To"), message.header("Subject"), MIMEParser.display(message.entity).plainText]
                    .joined(separator: " ").lowercased()
                return text.contains(search)
            }
            return true
        }
        let latest = Dictionary(grouping: visible, by: \.threadID).mapValues { $0.map(\.date).max()! }
        let ordered = latest.sorted { $0.value > $1.value }.map(\.key)
        let page = Array(ordered.dropFirst(offset).prefix(limit))
        record("LIST label=\(label ?? "-") q=\(search) count=\(page.count) account=\(mailbox.address)")

        var reply: [String: Any] = ["resultSizeEstimate": ordered.count,
                                    "threads": page.map { id in ["id": id, "snippet": "", "historyId": "\(1000 + counter)"] }]
        if offset + limit < ordered.count { reply["nextPageToken"] = String(offset + limit) }
        return .json(reply)
    }

    private func modifyThread(_ mailbox: Mailbox, id: String, action: String, body: Data) -> MockReply {
        guard mailbox.messages.contains(where: { $0.threadID == id }) else { return notFound() }
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        var add = Set(object["addLabelIds"] as? [String] ?? [])
        var remove = Set(object["removeLabelIds"] as? [String] ?? [])
        switch action {
        case "trash": add = ["TRASH"]; remove = ["INBOX"]
        case "untrash": add = ["INBOX"]; remove = ["TRASH"]
        case "modify": break
        default: return notFound()
        }
        for index in mailbox.messages.indices where mailbox.messages[index].threadID == id {
            mailbox.messages[index].labels.formUnion(add)
            mailbox.messages[index].labels.subtract(remove)
        }
        record("\(action.uppercased()) thread=\(id) add=\(add.sorted().joined(separator: ",")) remove=\(remove.sorted().joined(separator: ",")) account=\(mailbox.address)")
        return .json(["id": id])
    }

    // MARK: Sending

    private func receiveUpload(_ mailbox: Mailbox, request: URLRequest, body: Data, draft: Bool) -> MockReply {
        let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard let boundary = MIMEParser.parameters(of: contentType).params["boundary"] else {
            return .googleError(400, "Invalid multipart request.", reason: "badRequest")
        }
        let envelope = MIMEParser.parse(Array(Data("Content-Type: multipart/related; boundary=\"\(boundary)\"\r\n\r\n".utf8)) + [UInt8](body))
        guard envelope.parts.count == 2 else { return .googleError(400, "Invalid multipart request.", reason: "badRequest") }
        let metadata = (try? JSONSerialization.jsonObject(with: Data(envelope.parts[0].body))) as? [String: Any] ?? [:]
        let raw = envelope.parts[1].body
        let requestedThread = (draft ? (metadata["message"] as? [String: Any])?["threadId"] : metadata["threadId"]) as? String

        let sent = store(raw: raw, in: mailbox, labels: draft ? ["DRAFT"] : ["SENT"], threadID: requestedThread)
        let summary = Self.summary(of: sent, threadID: requestedThread)
        record("\(draft ? "DRAFT" : "SEND") account=\(mailbox.address) from=\(sent.header("From")) | \(summary)")

        if !draft {
            let recipients = (sent.header("To") + "," + sent.header("Cc") + "," + sent.header("Bcc"))
                .splitAddresses.map(\.emailAddressOnly)
            for address in Set(recipients) where address != mailbox.address {
                guard let target = mailboxes[address] else { continue }
                let delivered = store(raw: Self.withoutBcc(raw), in: target, labels: ["INBOX", "UNREAD"], threadID: nil)
                record("DELIVER to=\(address) message=\(delivered.id) thread=\(delivered.threadID)")
            }
        }
        return .json(["id": sent.id, "threadId": sent.threadID, "labelIds": Array(sent.labels)])
    }

    /// Recipients never see Bcc, just as with Gmail.
    private static func withoutBcc(_ raw: [UInt8]) -> [UInt8] {
        let text = String(decoding: raw, as: UTF8.self)
        guard let end = text.range(of: "\r\n\r\n") else { return raw }
        let headers = text[..<end.lowerBound].components(separatedBy: "\r\n").filter { !$0.lowercased().hasPrefix("bcc:") }
        return Array((headers.joined(separator: "\r\n") + text[end.lowerBound...]).utf8)
    }

    @discardableResult
    func store(raw: [UInt8], in mailbox: Mailbox, labels: Set<String>, threadID: String?, date: Date = Date()) -> Message {
        let entity = MIMEParser.parse(raw)
        let replyTo = MIMEParser.decodeEncodedWords(entity.header("In-Reply-To") ?? "")
        let joined = threadID ?? mailbox.messages.first { !replyTo.isEmpty && $0.header("Message-ID") == replyTo }?.threadID
        let message = Message(id: nextID("m"), threadID: joined ?? nextID("t"), labels: labels, raw: raw, entity: entity, date: date)
        mailbox.messages.append(message)
        return message
    }

    static func summary(of message: Message, threadID: String?) -> String {
        var files: [String] = []
        func walk(_ entity: MIMEEntity) {
            entity.parts.forEach(walk)
            let disposition = MIMEParser.parameters(of: entity.header("Content-Disposition") ?? "")
            if let name = disposition.params["filename"] ?? entity.parameters["name"] { files.append(MIMEParser.decodeEncodedWords(name)) }
        }
        walk(message.entity)
        let pgp = message.entity.first { $0.contentType == "multipart/encrypted" } != nil ? "encrypted"
            : message.entity.first { $0.contentType == "multipart/signed" } != nil ? "signed" : "none"
        return [
            "to=\(message.header("To"))",
            "cc=\(message.header("Cc"))",
            "bcc=\(message.header("Bcc"))",
            "subject=\(message.header("Subject"))",
            "inReplyTo=\(message.header("In-Reply-To"))",
            "threadId=\(threadID ?? "")",
            "attachments=\(files.joined(separator: ","))",
            "pgp=\(pgp)",
        ].joined(separator: " | ")
    }

    // MARK: Gmail JSON

    private func snippet(_ message: Message) -> String {
        let text = MIMEParser.display(message.entity).plainText
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return String(text.prefix(140))
    }

    /// Like Gmail, format=metadata returns only the headers named in metadataHeaders (all of them when none are named).
    private func json(_ message: Message, format: String, headers wanted: [String]? = nil) -> [String: Any] {
        var out: [String: Any] = [
            "id": message.id, "threadId": message.threadID, "labelIds": message.labels.sorted(),
            "snippet": snippet(message), "historyId": "\(1000 + counter)",
            "internalDate": String(Int64(message.date.timeIntervalSince1970 * 1000)), "sizeEstimate": message.raw.count,
        ]
        if format == "raw" {
            out["raw"] = Data(message.raw).base64URLEncoded
        } else {
            var payload = part(message.entity, partID: "", messageID: message.id, headersOnly: format == "metadata")
            if format == "metadata", let wanted, !wanted.isEmpty, let all = payload["headers"] as? [[String: String]] {
                let names = Set(wanted.map { $0.lowercased() })
                payload["headers"] = all.filter { names.contains($0["name"]?.lowercased() ?? "") }
            }
            out["payload"] = payload
        }
        return out
    }

    private func part(_ entity: MIMEEntity, partID: String, messageID: String, headersOnly: Bool) -> [String: Any] {
        var out: [String: Any] = [
            "partId": partID,
            "mimeType": entity.contentType,
            "filename": Self.filename(of: entity),
            "headers": entity.headers.map { ["name": $0.name, "value": $0.value] },
        ]
        if headersOnly { return out }
        if !entity.parts.isEmpty {
            out["body"] = ["size": 0]
            out["parts"] = entity.parts.enumerated().map { index, child in
                part(child, partID: partID.isEmpty ? "\(index)" : "\(partID).\(index)", messageID: messageID, headersOnly: false)
            }
        } else if Self.isInlineText(entity) {
            out["body"] = ["size": entity.body.count, "data": Data(entity.body).base64URLEncoded]
        } else {
            out["body"] = ["size": entity.body.count, "attachmentId": "att-\(messageID)-\(partID.isEmpty ? "0" : partID)"]
        }
        return out
    }

    private func attachments(of message: Message) -> [String: [UInt8]] {
        var out: [String: [UInt8]] = [:]
        func walk(_ entity: MIMEEntity, _ partID: String) {
            if entity.parts.isEmpty {
                if !Self.isInlineText(entity) { out["att-\(message.id)-\(partID.isEmpty ? "0" : partID)"] = entity.body }
                return
            }
            for (index, child) in entity.parts.enumerated() { walk(child, partID.isEmpty ? "\(index)" : "\(partID).\(index)") }
        }
        walk(message.entity, "")
        return out
    }

    private static func filename(of entity: MIMEEntity) -> String {
        let disposition = MIMEParser.parameters(of: entity.header("Content-Disposition") ?? "")
        return MIMEParser.decodeEncodedWords(disposition.params["filename"] ?? entity.parameters["name"] ?? "")
    }

    private static func isInlineText(_ entity: MIMEEntity) -> Bool {
        (entity.contentType == "text/plain" || entity.contentType == "text/html") && filename(of: entity).isEmpty
    }

    // MARK: Inspection for the UI tests

    /// Summary the probe exposes to UI tests: request log, accounts the server knows, and Keychain item names.
    func snapshot() -> String {
        // Accessibility truncates long values, so only the latest requests are exposed, each numbered.
        lock.lock()
        let lines = log.suffix(25).map { String($0.prefix(400)) }
        let total = sequence
        lock.unlock()
        let files = PrivateFile.names()
        var caches: [String: Int] = [:]
        for account in accountAddresses { caches[account] = files.filter { $0.hasPrefix(MailCache.prefix(account: account)) }.count }
        let state: [String: Any] = ["seq": total, "log": lines, "keychain": KeychainStore.allKeys().sorted(), "cacheFiles": caches]
        return String(decoding: (try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
    }
}
#endif
