import Foundation
import SwiftUI

extension Data {
    init?(base64URL: String) {
        var text = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = text.count % 4
        if remainder > 0 { text += String(repeating: "=", count: 4 - remainder) }
        self.init(base64Encoded: text, options: .ignoreUnknownCharacters)
    }

    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension String {
    /// Percent-encodes for application/x-www-form-urlencoded and URL query values.
    var formEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }

    var htmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    var htmlEntitiesDecoded: String {
        var out = self
        let named = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&nbsp;": " "]
        for (entity, value) in named where entity != "&amp;" {
            out = out.replacingOccurrences(of: entity, with: value)
        }
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Plain-text rendering of HTML. Never uses an HTML importer, which could fetch remote content.
    var strippingHTML: String {
        var out = self
        for pattern in ["(?is)<(style|script|head)[^>]*>.*?</\\1>", "(?i)<br\\s*/?>", "(?i)</(p|div|tr|li|h[1-6])>"] {
            let replacement = pattern.contains("style") ? "" : "\n"
            out = out.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        out = out.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return out.htmlEntitiesDecoded.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var emailAddressOnly: String {
        if let open = lastIndex(of: "<"), let close = lastIndex(of: ">"), open < close {
            return String(self[index(after: open)..<close]).trimmingCharacters(in: .whitespaces).lowercased()
        }
        return trimmingCharacters(in: .whitespaces).lowercased()
    }

    var displayNameOnly: String {
        guard let open = firstIndex(of: "<") else { return self }
        let name = self[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        return name.isEmpty ? emailAddressOnly : name
    }

    /// Splits a recipient list on commas that are outside quotes and angle brackets.
    var splitAddresses: [String] {
        var result: [String] = []
        var current = ""
        var quoted = false
        var angle = false
        for ch in self {
            if ch == "\"" { quoted.toggle() }
            if ch == "<" { angle = true }
            if ch == ">" { angle = false }
            if (ch == "," || ch == ";") && !quoted && !angle {
                result.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        result.append(current)
        return result.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

enum Theme {
    static let aegean = Color(red: 0.05, green: 0.36, blue: 0.58)
}

/// The app's preferences. Mock runs use a separate store, so UI tests on a Mac never reset the real app's settings.
enum AppDefaults {
    static let store: UserDefaults = {
        #if DEBUG
        if MockGmail.isActive, let mock = UserDefaults(suiteName: "com.meltemiapps.aeolet.mock") { return mock }
        #endif
        return .standard
    }()
}

/// Stores small app data with file protection and outside device backups.
/// On the Mac it lives inside the app's sandbox container, which other apps cannot read.
enum PrivateFile {
    private static var folderName: String {
        #if DEBUG
        if MockGmail.isActive { return "Private-Mock" }
        #endif
        return "Private"
    }

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(folderName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: base.path) {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            var copy = base
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? copy.setResourceValues(values)
        }
        return base
    }

    static func write(_ data: Data, name: String) throws {
        try data.write(to: directory.appendingPathComponent(name),
                       options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func read(name: String) -> Data? {
        try? Data(contentsOf: directory.appendingPathComponent(name))
    }

    static func deleteAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    static func names() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    static func delete(prefix: String) {
        for name in names() where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
