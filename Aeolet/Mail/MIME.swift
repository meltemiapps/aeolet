import CoreFoundation
import Foundation

// MARK: - Display model

struct MailAttachment: Identifiable, Hashable {
    enum Source: Hashable {
        case gmail(messageID: String, attachmentID: String)
        case local(Data)
    }

    let id = UUID()
    let filename: String
    let mimeType: String
    let size: Int
    let contentID: String?
    let source: Source
}

struct MailBody: Hashable {
    var html: String?
    var text: String?
    var attachments: [MailAttachment] = []

    var plainText: String { text ?? html?.strippingHTML ?? "" }
}

// MARK: - Gmail JSON payload to display model

enum GmailBodyExtractor {
    static func body(of message: GmailMessage) -> MailBody {
        var body = MailBody()
        if let payload = message.payload { visit(payload, messageID: message.id, into: &body) }
        return body
    }

    private static func visit(_ part: GmailPart, messageID: String, into body: inout MailBody) {
        let type = (part.mimeType ?? "").lowercased()
        if let attachmentID = part.body?.attachmentId {
            let name = (part.filename?.isEmpty == false) ? part.filename! : "attachment"
            let cid = part.header("Content-ID")?.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
            body.attachments.append(MailAttachment(
                filename: name, mimeType: type, size: part.body?.size ?? 0, contentID: cid,
                source: .gmail(messageID: messageID, attachmentID: attachmentID)))
        } else if type == "text/html" || type == "text/plain", part.filename?.isEmpty != false,
                  let encoded = part.body?.data, let data = Data(base64URL: encoded) {
            let text = MIMEParser.decodeText([UInt8](data), charset: MIMEParser.parameters(of: part.header("Content-Type") ?? "").params["charset"])
            if type == "text/html" {
                if body.html == nil { body.html = text }
            } else if body.text == nil {
                body.text = text
            }
        }
        part.parts?.forEach { visit($0, messageID: messageID, into: &body) }
    }
}

// MARK: - Parser

struct MIMEEntity {
    var headers: [(name: String, value: String)] = []
    var contentType = "text/plain"
    var parameters: [String: String] = [:]
    var body: [UInt8] = []
    var parts: [MIMEEntity] = []
    /// The exact bytes of this entity as transmitted, needed to verify PGP/MIME signatures.
    var raw: [UInt8] = []

    func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    func first(where predicate: (MIMEEntity) -> Bool) -> MIMEEntity? {
        if predicate(self) { return self }
        for part in parts {
            if let found = part.first(where: predicate) { return found }
        }
        return nil
    }
}

enum MIMEParser {
    private static let maximumDepth = 24

    static func parse(_ bytes: [UInt8], depth: Int = 0) -> MIMEEntity {
        var entity = MIMEEntity()
        entity.raw = bytes
        let (headerLines, bodyStart) = splitHeaders(bytes)
        entity.headers = headerLines
        let parsedType = parameters(of: entity.header("Content-Type") ?? "text/plain")
        entity.contentType = parsedType.value.lowercased()
        entity.parameters = parsedType.params

        let content = Array(bytes[min(bodyStart, bytes.count)...])
        if entity.contentType.hasPrefix("multipart/"), let boundary = entity.parameters["boundary"], depth < maximumDepth {
            entity.parts = splitMultipart(content, boundary: boundary).map { parse($0, depth: depth + 1) }
        } else {
            entity.body = decodeTransfer(content, encoding: entity.header("Content-Transfer-Encoding"))
        }
        return entity
    }

    static func display(_ root: MIMEEntity) -> MailBody {
        var body = MailBody()
        collect(root, into: &body)
        return body
    }

    private static func collect(_ entity: MIMEEntity, into body: inout MailBody) {
        if !entity.parts.isEmpty {
            entity.parts.forEach { collect($0, into: &body) }
            return
        }
        let disposition = parameters(of: entity.header("Content-Disposition") ?? "")
        let filename = disposition.params["filename"] ?? entity.parameters["name"]
        let isAttachment = disposition.value.lowercased() == "attachment" || filename != nil
        if !isAttachment, entity.contentType == "text/html" {
            if body.html == nil { body.html = decodeText(entity.body, charset: entity.parameters["charset"]) }
        } else if !isAttachment, entity.contentType == "text/plain" {
            if body.text == nil { body.text = decodeText(entity.body, charset: entity.parameters["charset"]) }
        } else if entity.contentType != "application/pgp-signature" {
            let cid = entity.header("Content-ID")?.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
            body.attachments.append(MailAttachment(
                filename: filename ?? "attachment", mimeType: entity.contentType, size: entity.body.count,
                contentID: cid, source: .local(Data(entity.body))))
        }
    }

    // MARK: Headers

    private static func splitHeaders(_ bytes: [UInt8]) -> ([(name: String, value: String)], Int) {
        var unfolded: [String] = []
        var index = 0
        while index < bytes.count {
            var end = index
            while end < bytes.count && bytes[end] != 0x0A { end += 1 }
            let next = min(end + 1, bytes.count)
            var lineEnd = end
            if lineEnd > index && bytes[lineEnd - 1] == 0x0D { lineEnd -= 1 }
            if lineEnd == index { return (toHeaders(unfolded), next) }
            let line = String(decoding: bytes[index..<lineEnd], as: UTF8.self)
            if let first = bytes[safe: index], first == 0x20 || first == 0x09, !unfolded.isEmpty {
                unfolded[unfolded.count - 1] += " " + line.trimmingCharacters(in: .whitespaces)
            } else {
                unfolded.append(line)
            }
            index = next
        }
        return (toHeaders(unfolded), bytes.count)
    }

    private static func toHeaders(_ lines: [String]) -> [(name: String, value: String)] {
        lines.compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (String(line[..<colon]).trimmingCharacters(in: .whitespaces),
                    decodeEncodedWords(String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
        }
    }

    static func parameters(of header: String) -> (value: String, params: [String: String]) {
        var pieces: [String] = []
        var current = ""
        var quoted = false
        var previous: Character = " "
        for ch in header {
            if ch == "\"" && previous != "\\" { quoted.toggle() }
            if ch == ";" && !quoted {
                pieces.append(current)
                current = ""
            } else {
                current.append(ch)
            }
            previous = ch
        }
        pieces.append(current)

        var parameters: [String: String] = [:]
        for piece in pieces.dropFirst() {
            guard let equals = piece.firstIndex(of: "=") else { continue }
            var name = piece[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            var value = piece[piece.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
            }
            if name.hasSuffix("*") {
                name = String(name.dropLast())
                let sections = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                if sections.count == 3 { value = String(sections[2]).removingPercentEncoding ?? String(sections[2]) }
            }
            parameters[name] = value
        }
        return (pieces[0].trimmingCharacters(in: .whitespaces), parameters)
    }

    static func decodeEncodedWords(_ input: String) -> String {
        guard input.contains("=?") else { return input }
        let pattern = "=\\?([^?\\s]+)\\?([bBqQ])\\?([^?\\s]*)\\?="
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        let joined = input.replacingOccurrences(of: "\\?=\\s+=\\?", with: "?==?", options: .regularExpression)
        let source = joined as NSString
        var output = ""
        var cursor = 0
        for match in regex.matches(in: joined, range: NSRange(location: 0, length: source.length)) {
            output += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let charset = source.substring(with: match.range(at: 1))
            let mode = source.substring(with: match.range(at: 2)).uppercased()
            let text = source.substring(with: match.range(at: 3))
            let bytes: [UInt8] = mode == "B"
                ? [UInt8](Data(base64Encoded: text, options: .ignoreUnknownCharacters) ?? Data())
                : decodeQuotedPrintable(Array(text.replacingOccurrences(of: "_", with: " ").utf8))
            output += decodeText(bytes, charset: charset)
            cursor = match.range.location + match.range.length
        }
        output += source.substring(from: cursor)
        return output
    }

    // MARK: Bodies

    private static func splitMultipart(_ content: [UInt8], boundary: String) -> [[UInt8]] {
        let delimiter = Array(("--" + boundary).utf8)
        let closing = delimiter + [0x2D, 0x2D]
        var parts: [[UInt8]] = []
        var start: Int?
        var index = 0

        while index < content.count {
            var end = index
            while end < content.count && content[end] != 0x0A { end += 1 }
            let next = min(end + 1, content.count)
            var trimmed = end
            while trimmed > index, [0x0D, 0x20, 0x09].contains(content[trimmed - 1]) { trimmed -= 1 }
            let line = content[index..<trimmed]

            if line.elementsEqual(delimiter) || line.elementsEqual(closing) {
                if let begin = start {
                    var stop = index
                    if stop > begin && content[stop - 1] == 0x0A { stop -= 1 }
                    if stop > begin && content[stop - 1] == 0x0D { stop -= 1 }
                    parts.append(Array(content[begin..<max(begin, stop)]))
                }
                if line.elementsEqual(closing) { return parts }
                start = next
            }
            index = next
        }
        if let begin = start, begin < content.count { parts.append(Array(content[begin...])) }
        return parts
    }

    private static func decodeTransfer(_ content: [UInt8], encoding: String?) -> [UInt8] {
        switch encoding?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "base64":
            return [UInt8](Data(base64Encoded: Data(content), options: .ignoreUnknownCharacters) ?? Data())
        case "quoted-printable":
            return decodeQuotedPrintable(content)
        default:
            return content
        }
    }

    static func decodeQuotedPrintable(_ input: [UInt8]) -> [UInt8] {
        func hex(_ value: UInt8) -> UInt8? {
            switch value {
            case 0x30...0x39: return value - 0x30
            case 0x41...0x46: return value - 0x41 + 10
            case 0x61...0x66: return value - 0x61 + 10
            default: return nil
            }
        }
        var out: [UInt8] = []
        out.reserveCapacity(input.count)
        var index = 0
        while index < input.count {
            let byte = input[index]
            guard byte == 0x3D else {
                out.append(byte)
                index += 1
                continue
            }
            if index + 2 < input.count, let high = hex(input[index + 1]), let low = hex(input[index + 2]) {
                out.append(high << 4 | low)
                index += 3
            } else if index + 1 < input.count, input[index + 1] == 0x0A {
                index += 2
            } else if index + 2 < input.count, input[index + 1] == 0x0D, input[index + 2] == 0x0A {
                index += 3
            } else {
                out.append(byte)
                index += 1
            }
        }
        return out
    }

    static func decodeText(_ bytes: [UInt8], charset: String?) -> String {
        if let text = String(bytes: bytes, encoding: .utf8) { return text }
        if let charset {
            let converted = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            if converted != kCFStringEncodingInvalidId {
                let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(converted))
                if let text = String(bytes: bytes, encoding: encoding) { return text }
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// RFC 3156 requires signatures over CRLF line endings.
    static func canonicalCRLF(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + bytes.count / 40)
        var previous: UInt8 = 0
        for byte in bytes {
            if byte == 0x0A && previous != 0x0D { out.append(0x0D) }
            out.append(byte)
            previous = byte
        }
        return out
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - Builder

struct OutgoingAttachment: Identifiable, Hashable {
    let id = UUID()
    var filename: String
    var mimeType: String
    var data: Data
}

struct OutgoingHeaders {
    /// "Name <address>", or just the address when there is no name.
    static func sender(account: String, displayName: String?) -> String {
        let name = MIMEBuilder.sanitised(displayName ?? "")
        return name.isEmpty ? account : "\(name) <\(account)>"
    }

    var from: String
    var to: [String]
    var cc: [String] = []
    var bcc: [String] = []
    var subject: String
    var inReplyTo: String? = nil
    var references: String? = nil
}

enum MIMEBuilder {
    private static let crlf = "\r\n"

    private static func boundary() -> String { "aeolet-\(UUID().uuidString)" }

    /// Removes the line breaks that would allow header injection.
    static func sanitised(_ value: String) -> String {
        value.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    static func encodeHeaderWord(_ value: String) -> String {
        let clean = sanitised(value)
        if clean.allSatisfy({ $0.isASCII }) { return clean }
        var words: [String] = []
        var chunk = ""
        for ch in clean {
            if chunk.utf8.count + String(ch).utf8.count > 42 {
                words.append(chunk)
                chunk = ""
            }
            chunk.append(ch)
        }
        if !chunk.isEmpty { words.append(chunk) }
        return words.map { "=?UTF-8?B?\(Data($0.utf8).base64EncodedString())?=" }.joined(separator: "\r\n ")
    }

    private static func encodeAddress(_ address: String) -> String {
        let clean = sanitised(address)
        guard let open = clean.lastIndex(of: "<") else { return clean }
        let name = clean[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        let mailbox = String(clean[open...])
        if name.isEmpty { return mailbox }
        if name.allSatisfy({ $0.isASCII }) {
            // Plain names go as they are; names with RFC 5322 specials, such as "Andreou, Nikos", are quoted.
            let specials = CharacterSet(charactersIn: "()<>[]:;@\\,.\"")
            if name.unicodeScalars.allSatisfy({ !specials.contains($0) }) { return "\(name) \(mailbox)" }
            let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\" \(mailbox)"
        }
        return "\(encodeHeaderWord(name)) \(mailbox)"
    }

    private static func addressHeader(_ name: String, _ addresses: [String]) -> String? {
        guard !addresses.isEmpty else { return nil }
        return "\(name): " + addresses.map(encodeAddress).joined(separator: ",\r\n ")
    }

    private static func wrappedBase64(_ data: Data) -> String {
        data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
    }

    private static func filenameParameter(_ name: String, key: String) -> String {
        let clean = sanitised(name).replacingOccurrences(of: "\"", with: "")
        if clean.allSatisfy({ $0.isASCII }) { return "\(key)=\"\(clean)\"" }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = clean.addingPercentEncoding(withAllowedCharacters: allowed) ?? "attachment"
        return "\(key)*=UTF-8''\(encoded)"
    }

    /// Builds the body entity. Base64 keeps bytes stable through mail servers, which PGP signatures depend on.
    static func contentEntity(text: String, attachments: [OutgoingAttachment]) -> Data {
        let normalised = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        let textPart = [
            "Content-Type: text/plain; charset=utf-8",
            "Content-Transfer-Encoding: base64",
            "",
            wrappedBase64(Data(normalised.utf8)),
            "",
        ].joined(separator: crlf)
        guard !attachments.isEmpty else { return Data(textPart.utf8) }

        let mark = boundary()
        var out = Data(("Content-Type: multipart/mixed; boundary=\"\(mark)\"" + crlf + crlf).utf8)
        out.append(Data(("--\(mark)" + crlf + textPart).utf8))
        for item in attachments {
            let type = sanitised(item.mimeType.isEmpty ? "application/octet-stream" : item.mimeType)
            let head = [
                "--\(mark)",
                "Content-Type: \(type); \(filenameParameter(item.filename, key: "name"))",
                "Content-Disposition: attachment; \(filenameParameter(item.filename, key: "filename"))",
                "Content-Transfer-Encoding: base64",
                "",
                "",
            ].joined(separator: crlf)
            out.append(Data(head.utf8))
            out.append(Data((wrappedBase64(item.data) + crlf).utf8))
        }
        out.append(Data(("--\(mark)--" + crlf).utf8))
        return out
    }

    /// RFC 3156 section 5: detached signature over the exact entity bytes.
    static func signedEntity(content: Data, signature: String, micalg: String) -> Data {
        let mark = boundary()
        var out = Data(("Content-Type: multipart/signed; micalg=\(micalg); protocol=\"application/pgp-signature\"; boundary=\"\(mark)\"" + crlf + crlf).utf8)
        out.append(Data(("--\(mark)" + crlf).utf8))
        out.append(content)
        let tail = [
            "",
            "--\(mark)",
            "Content-Type: application/pgp-signature; name=\"signature.asc\"",
            "Content-Description: OpenPGP digital signature",
            "Content-Disposition: attachment; filename=\"signature.asc\"",
            "",
            canonicalLines(signature),
            "--\(mark)--",
            "",
        ].joined(separator: crlf)
        out.append(Data(tail.utf8))
        return out
    }

    /// RFC 3156 section 4: encrypted PGP/MIME structure.
    static func encryptedEntity(armored: String) -> Data {
        let mark = boundary()
        let lines = [
            "Content-Type: multipart/encrypted; protocol=\"application/pgp-encrypted\"; boundary=\"\(mark)\"",
            "",
            "This is an OpenPGP/MIME encrypted message (RFC 3156).",
            "--\(mark)",
            "Content-Type: application/pgp-encrypted",
            "Content-Description: PGP/MIME version identification",
            "",
            "Version: 1",
            "",
            "--\(mark)",
            "Content-Type: application/octet-stream; name=\"encrypted.asc\"",
            "Content-Description: OpenPGP encrypted message",
            "Content-Disposition: inline; filename=\"encrypted.asc\"",
            "",
            canonicalLines(armored),
            "--\(mark)--",
            "",
        ]
        return Data(lines.joined(separator: crlf).utf8)
    }

    private static func canonicalLines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .newlines)
            .replacingOccurrences(of: "\n", with: "\r\n")
    }

    static func message(headers: OutgoingHeaders, entity: Data, senderDomain: String, date: Date = Date()) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"

        var lines: [String] = [
            "MIME-Version: 1.0",
            "Date: \(formatter.string(from: date))",
            "Message-ID: <\(UUID().uuidString)@\(sanitised(senderDomain))>",
            "From: \(encodeAddress(headers.from))",
        ]
        lines += [addressHeader("To", headers.to), addressHeader("Cc", headers.cc), addressHeader("Bcc", headers.bcc)].compactMap { $0 }
        lines.append("Subject: \(encodeHeaderWord(headers.subject))")
        if let value = headers.inReplyTo, !value.isEmpty { lines.append("In-Reply-To: \(sanitised(value))") }
        if let value = headers.references, !value.isEmpty { lines.append("References: \(sanitised(value))") }

        var out = Data((lines.joined(separator: crlf) + crlf).utf8)
        out.append(entity)
        return out
    }
}
