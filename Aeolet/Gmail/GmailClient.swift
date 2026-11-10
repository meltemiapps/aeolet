import Foundation

enum GmailError: LocalizedError {
    case http(Int, String)
    case historyExpired
    case invalidResponse
    case incomplete(String)

    var errorDescription: String? {
        switch self {
        case let .http(code, message): return message.isEmpty ? "Gmail returned status \(code)." : message
        case .historyExpired: return "Mail history expired."
        case .invalidResponse: return "Gmail returned an unexpected response."
        case let .incomplete(detail): return "Gmail returned an incomplete response (\(detail))."
        }
    }
}

/// Direct device-to-Google client. There is no intermediary server.
struct GmailClient {
    let account: String

    private static let base = "https://gmail.googleapis.com/gmail/v1/users/me"
    private static let uploadBase = "https://gmail.googleapis.com/upload/gmail/v1/users/me"

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 60
        return URLSession(configuration: configuration)
    }()

    // MARK: Transport

    private func perform(_ original: URLRequest, attempt: Int = 0, forceRefresh: Bool = false) async throws -> Data {
        var request = original
        let token = try await TokenStore.shared.accessToken(for: account, forceRefresh: forceRefresh)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await Self.session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw GmailError.invalidResponse }

        switch status {
        case 200..<300:
            return data
        case 401 where attempt == 0:
            return try await perform(original, attempt: 1, forceRefresh: true)
        case 403, 429, 500, 502, 503, 504:
            let body = String(decoding: data, as: UTF8.self)
            let isRateLimit = status != 403 || body.contains("rateLimitExceeded") || body.contains("userRateLimitExceeded")
            if isRateLimit && attempt < 4 {
                let delay = UInt64(pow(2.0, Double(attempt)) * 500_000_000) + UInt64.random(in: 0..<250_000_000)
                try await Task.sleep(nanoseconds: delay)
                return try await perform(original, attempt: attempt + 1)
            }
            throw GmailError.http(status, Self.message(from: data))
        default:
            throw GmailError.http(status, Self.message(from: data))
        }
    }

    /// Google's human-readable reason from a JSON error body, or "" if there is none.
    /// Handles both API errors ({"error": {"message": ...}}) and OAuth errors ({"error": "...", "error_description": ...}).
    static func message(from data: Data) -> String {
        struct APIEnvelope: Decodable {
            struct Inner: Decodable { let message: String? }
            let error: Inner?
        }
        struct OAuthEnvelope: Decodable {
            let error: String?
            let error_description: String?
        }
        if let message = (try? JSONDecoder().decode(APIEnvelope.self, from: data))?.error?.message, !message.isEmpty {
            return message
        }
        if let body = try? JSONDecoder().decode(OAuthEnvelope.self, from: data) {
            return body.error_description ?? body.error ?? ""
        }
        return ""
    }

    /// Decodes a Google response. If it doesn't have the expected shape, throws Google's own reason when the body
    /// carries one, otherwise names what was missing instead of Foundation's generic "data is missing" text.
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch let error as DecodingError {
            let reason = message(from: data)
            if !reason.isEmpty { throw GmailError.http(0, reason) }
            throw GmailError.incomplete(describe(error))
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ codingPath: [CodingKey], _ key: CodingKey? = nil) -> String {
            let keys = (codingPath + (key.map { [$0] } ?? [])).map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
            return keys.isEmpty ? "response" : keys.joined(separator: ".")
        }
        switch error {
        case let .keyNotFound(key, context): return "missing \(path(context.codingPath, key))"
        case let .valueNotFound(_, context): return "empty \(path(context.codingPath))"
        case let .typeMismatch(_, context): return "unexpected value for \(path(context.codingPath))"
        case .dataCorrupted: return "not valid JSON"
        @unknown default: return "unreadable"
        }
    }

    private func url(_ path: String, _ query: [(String, String)] = []) -> URL {
        var text = Self.base + path
        if !query.isEmpty {
            text += "?" + query.map { "\($0.0)=\($0.1.formEncoded)" }.joined(separator: "&")
        }
        return URL(string: text)!
    }

    private func get<T: Decodable>(_ path: String, _ query: [(String, String)] = []) async throws -> T {
        let data = try await perform(URLRequest(url: url(path, query)))
        return try Self.decode(T.self, from: data)
    }

    @discardableResult
    private func postJSON(_ path: String, body: [String: Any]? = nil) async throws -> Data {
        var request = URLRequest(url: url(path))
        request.httpMethod = "POST"
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return try await perform(request)
    }

    // MARK: Account and labels

    func profile() async throws -> GmailProfile { try await get("/profile") }

    func labels() async throws -> [GmailLabel] {
        struct Response: Decodable { let labels: [GmailLabel]? }
        let listed: Response = try await get("/labels")
        let visible = (listed.labels ?? []).filter(\.isUserFacing)
        let detailed: [GmailLabel] = await withTaskGroup(of: GmailLabel?.self) { group in
            var out: [GmailLabel] = []
            for (index, label) in visible.enumerated() {
                if index >= 6 { if let done = await group.next(), let done { out.append(done) } }
                group.addTask {
                    let detail: GmailLabel? = try? await self.get("/labels/\(label.id.formEncoded)")
                    return detail ?? label
                }
            }
            for await item in group { if let item { out.append(item) } }
            return out
        }
        let result = detailed.isEmpty ? visible : detailed
        return result.sorted {
            $0.sortRank != $1.sortRank ? $0.sortRank < $1.sortRank
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // MARK: Threads

    func threads(labelID: String?, query: String?, pageToken: String?, limit: Int = 30) async throws -> (items: [ThreadSummary], next: String?) {
        var parameters: [(String, String)] = [("maxResults", String(limit))]
        if let labelID { parameters.append(("labelIds", labelID)) }
        if let query, !query.isEmpty { parameters.append(("q", query)) }
        if let pageToken { parameters.append(("pageToken", pageToken)) }
        let list: GmailThreadList = try await get("/threads", parameters)
        let ids = (list.threads ?? []).map(\.id)

        let found: [(Int, ThreadSummary)] = try await withThrowingTaskGroup(of: (Int, ThreadSummary?).self) { group in
            var collected: [(Int, ThreadSummary)] = []
            for (index, id) in ids.enumerated() {
                if index >= 6, let done = try await group.next(), let summary = done.1 {
                    collected.append((done.0, summary))
                }
                group.addTask {
                    let thread = try await self.threadMetadata(id)
                    return (index, ThreadSummary(thread: thread))
                }
            }
            for try await done in group {
                if let summary = done.1 { collected.append((done.0, summary)) }
            }
            return collected
        }
        return (found.sorted { $0.0 < $1.0 }.map(\.1), list.nextPageToken)
    }

    private func threadMetadata(_ id: String) async throws -> GmailThread {
        try await get("/threads/\(id)", [
            ("format", "metadata"),
            ("metadataHeaders", "From"),
            ("metadataHeaders", "Subject"),
            ("fields", "id,snippet,messages(id,labelIds,snippet,internalDate,payload/headers)"),
        ])
    }

    func thread(_ id: String) async throws -> GmailThread {
        try await get("/threads/\(id)", [("format", "full")])
    }

    func modifyThread(_ id: String, add: [String] = [], remove: [String] = []) async throws {
        try await postJSON("/threads/\(id)/modify", body: ["addLabelIds": add, "removeLabelIds": remove])
    }

    func trashThread(_ id: String) async throws { try await postJSON("/threads/\(id)/trash") }
    func untrashThread(_ id: String) async throws { try await postJSON("/threads/\(id)/untrash") }

    // MARK: Messages

    func rawMessage(_ id: String) async throws -> Data {
        let message: GmailMessage = try await get("/messages/\(id)", [("format", "raw")])
        guard let raw = message.raw, let data = Data(base64URL: raw) else { throw GmailError.invalidResponse }
        return data
    }

    func attachment(messageID: String, attachmentID: String) async throws -> Data {
        struct Response: Decodable { let data: String }
        let response: Response = try await get("/messages/\(messageID)/attachments/\(attachmentID)")
        guard let data = Data(base64URL: response.data) else { throw GmailError.invalidResponse }
        return data
    }

    func metadata(messageID: String) async throws -> GmailMessage {
        try await get("/messages/\(messageID)", [
            ("format", "metadata"), ("metadataHeaders", "From"), ("metadataHeaders", "Subject"),
        ])
    }

    /// Uses Gmail's multipart upload, so attachments are not limited by the JSON request size.
    private func upload(path: String, metadata: [String: Any], message: Data) async throws {
        let boundary = "aeolet-upload-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
        body.append(try JSONSerialization.data(withJSONObject: metadata))
        body.append(Data("\r\n--\(boundary)\r\nContent-Type: message/rfc822\r\n\r\n".utf8))
        body.append(message)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: URL(string: Self.uploadBase + path + "?uploadType=multipart")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        _ = try await perform(request)
    }

    func send(message: Data, threadID: String?) async throws {
        var metadata: [String: Any] = [:]
        if let threadID { metadata["threadId"] = threadID }
        try await upload(path: "/messages/send", metadata: metadata, message: message)
    }

    func saveDraft(message: Data, threadID: String?) async throws {
        var inner: [String: Any] = [:]
        if let threadID { inner["threadId"] = threadID }
        try await upload(path: "/drafts", metadata: ["message": inner], message: message)
    }

    // MARK: Background sync

    func addedInboxMessageIDs(since historyID: String) async throws -> (ids: [String], latest: String?) {
        do {
            let response: GmailHistoryResponse = try await get("/history", [
                ("startHistoryId", historyID),
                ("historyTypes", "messageAdded"),
                ("labelId", "INBOX"),
                ("maxResults", "50"),
            ])
            let messages = (response.history ?? []).flatMap { $0.messagesAdded ?? [] }.map(\.message)
            let incoming = messages.filter { !($0.labelIds ?? []).contains("SENT") && !($0.labelIds ?? []).contains("DRAFT") }
            var ids: [String] = []
            for message in incoming where !ids.contains(message.id) { ids.append(message.id) }
            return (ids, response.historyId)
        } catch GmailError.http(404, _) {
            throw GmailError.historyExpired
        }
    }
}
