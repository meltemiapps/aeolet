import BackgroundTasks
import Foundation
import UserNotifications

/// Without a server there is no Gmail push. iOS decides when this runs; delivery is opportunistic, not instant.
enum BackgroundSync {
    private static func historyKey(_ account: String) -> String { "history.\(account.lowercased())" }

    /// Drops the account's new-mail bookmark when it signs out.
    static func forget(account: String) {
        UserDefaults.standard.removeObject(forKey: historyKey(account))
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: AppConfig.backgroundTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func requestNotificationPermission() async {
        #if DEBUG
        if MockGmail.isActive { return }
        #endif
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
    }

    static func run() async {
        schedule()
        for account in await TokenStore.shared.accounts() {
            await refresh(account: account)
        }
    }

    /// Establishes the starting point so the next refresh reports only newer mail.
    static func establishBaseline(account: String) async {
        if let profile = try? await GmailClient(account: account).profile(), let history = profile.historyId {
            UserDefaults.standard.set(history, forKey: historyKey(account))
        }
    }

    private static func refresh(account: String) async {
        let client = GmailClient(account: account)
        guard let start = UserDefaults.standard.string(forKey: historyKey(account)) else {
            await establishBaseline(account: account)
            return
        }
        do {
            let result = try await client.addedInboxMessageIDs(since: start)
            if let latest = result.latest { UserDefaults.standard.set(latest, forKey: historyKey(account)) }
            for id in result.ids.prefix(5) {
                guard let message = try? await client.metadata(messageID: id) else { continue }
                await notify(account: account, message: message)
            }
        } catch GmailError.historyExpired {
            await establishBaseline(account: account)
        } catch {
            return
        }
    }

    private static func notify(account: String, message: GmailMessage) async {
        let content = UNMutableNotificationContent()
        content.title = message.header("From")?.displayNameOnly ?? account
        content.body = message.header("Subject") ?? "New message"
        content.threadIdentifier = account
        content.sound = .default
        let request = UNNotificationRequest(identifier: message.id, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
