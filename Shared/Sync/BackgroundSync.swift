import Foundation
import UserNotifications

/// Without a server there is no Gmail push. On iOS the system decides when this runs, so delivery is
/// opportunistic, not instant (see BackgroundSchedule). The Mac app runs it on a timer while it is open.
enum BackgroundSync {
    private static func historyKey(_ account: String) -> String { "history.\(account.lowercased())" }

    /// Drops the account's new-mail bookmark when it signs out.
    static func forget(account: String) {
        AppDefaults.store.removeObject(forKey: historyKey(account))
    }

    static func requestNotificationPermission() async {
        #if DEBUG
        if MockGmail.isActive { return }
        #endif
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
    }

    /// Checks every account for new inbox mail and notifies about it. Returns how many new messages arrived.
    @discardableResult
    static func checkAll() async -> Int {
        var arrived = 0
        for account in await TokenStore.shared.accounts() {
            arrived += await refresh(account: account)
        }
        return arrived
    }

    /// Establishes the starting point so the next refresh reports only newer mail.
    static func establishBaseline(account: String) async {
        if let profile = try? await GmailClient(account: account).profile(), let history = profile.historyId {
            AppDefaults.store.set(history, forKey: historyKey(account))
        }
    }

    private static func refresh(account: String) async -> Int {
        let client = GmailClient(account: account)
        guard let start = AppDefaults.store.string(forKey: historyKey(account)) else {
            await establishBaseline(account: account)
            return 0
        }
        do {
            let result = try await client.addedInboxMessageIDs(since: start)
            if let latest = result.latest { AppDefaults.store.set(latest, forKey: historyKey(account)) }
            for id in result.ids.prefix(5) {
                guard let message = try? await client.metadata(messageID: id) else { continue }
                await notify(account: account, message: message)
            }
            return result.ids.count
        } catch GmailError.historyExpired {
            await establishBaseline(account: account)
            return 0
        } catch {
            return 0
        }
    }

    private static func notify(account: String, message: GmailMessage) async {
        let content = UNMutableNotificationContent()
        content.title = message.header("From")?.displayNameOnly ?? account
        content.body = message.header("Subject") ?? "New message"
        content.threadIdentifier = account
        content.userInfo = ["account": account, "threadID": message.threadId ?? ""]
        content.sound = .default
        let request = UNNotificationRequest(identifier: message.id, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
