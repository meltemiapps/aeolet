import CryptoKit
import Foundation

/// Local cache of thread summaries only. Message bodies and decrypted content are never written to disk.
enum MailCache {
    /// Every cache file for an account shares this prefix, so signing out can remove exactly that account's files.
    static func prefix(account: String) -> String {
        let digest = SHA256.hash(data: Data(account.lowercased().utf8))
        return "threads-" + Data(digest).base64URLEncoded.prefix(22) + "-"
    }

    private static func name(account: String, label: String) -> String {
        let digest = SHA256.hash(data: Data("\(account.lowercased())|\(label)".utf8))
        return prefix(account: account) + Data(digest).base64URLEncoded + ".json"
    }

    static func deleteAll(account: String) {
        PrivateFile.delete(prefix: prefix(account: account))
    }

    static func load(account: String, label: String) -> [ThreadSummary] {
        guard let data = PrivateFile.read(name: name(account: account, label: label)) else { return [] }
        return (try? JSONDecoder().decode([ThreadSummary].self, from: data)) ?? []
    }

    static func save(_ items: [ThreadSummary], account: String, label: String) {
        guard let data = try? JSONEncoder().encode(Array(items.prefix(100))) else { return }
        try? PrivateFile.write(data, name: name(account: account, label: label))
    }
}
