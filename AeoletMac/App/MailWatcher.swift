import AppKit
import ServiceManagement
import SwiftUI

/// Checks Gmail for new inbox mail on a timer while Aeolet is running. There is no server and no push:
/// the Mac asks Google directly, the same way the iOS app does in background refresh.
@MainActor
final class MailWatcher: ObservableObject {
    static let shared = MailWatcher()

    static let intervalKey = "refreshMinutes"
    static let intervals = [1, 5, 15, 30, 60]

    @Published var minutes: Int {
        didSet {
            AppDefaults.store.set(minutes, forKey: Self.intervalKey)
            restart()
        }
    }
    @Published private(set) var lastCheck: Date?

    private weak var app: AppModel?
    private var loop: Task<Void, Never>?
    private var badgeTask: Task<Void, Never>?

    private init() {
        let saved = AppDefaults.store.integer(forKey: Self.intervalKey)
        minutes = Self.intervals.contains(saved) ? saved : 5
    }

    func start(app: AppModel) {
        self.app = app
        restart()
    }

    private func restart() {
        loop?.cancel()
        loop = Task { [weak self] in
            // A first check soon after launch sets the starting point, so only newer mail is announced.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            while !Task.isCancelled {
                await self?.check()
                let wait = UInt64((self?.minutes ?? 5) * 60) * 1_000_000_000
                try? await Task.sleep(nanoseconds: wait)
            }
        }
    }

    func check() async {
        guard app != nil, !(await TokenStore.shared.accounts()).isEmpty else {
            NSApp.dockTile.badgeLabel = nil
            return
        }
        if await BackgroundSync.checkAll() > 0 {
            NotificationCenter.default.post(name: .aeoletNewMail, object: nil)
        }
        lastCheck = Date()
        await updateBadge()
    }

    /// The Dock shows unread inbox conversations across every account.
    func updateBadge() async {
        var total = 0
        for account in await TokenStore.shared.accounts() {
            if let inbox = try? await GmailClient(account: account).label("INBOX") {
                total += inbox.threadsUnread ?? inbox.messagesUnread ?? 0
            }
        }
        NSApp.dockTile.badgeLabel = total > 0 ? "\(total)" : nil
    }

    /// Recounts shortly after the person reads, archives or bins mail, coalescing bursts into one request per account.
    func updateBadgeSoon() {
        badgeTask?.cancel()
        badgeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await self?.updateBadge()
        }
    }
}

/// Open at Login, through the system's login items (System Settings > General > Login Items).
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
