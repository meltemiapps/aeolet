import AppKit
import SwiftUI
import UserNotifications

@main
struct AeoletMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var app = AppModel()
    @StateObject private var pgp = PGPStore.shared

    init() {
        #if DEBUG
        MockGmail.prepareLaunch()
        #endif
    }

    var body: some Scene {
        WindowGroup("Aeolet", id: WindowID.main) {
            MainWindow()
                .environmentObject(app)
                .environmentObject(pgp)
                .tint(Theme.aegean)
                .onAppear { delegate.attach(app: app, pgp: pgp) }
        }
        .defaultSize(width: 1280, height: 800)
        .commands { MailCommands(app: app) }

        WindowGroup("New Message", id: WindowID.compose, for: ComposeRequest.self) { $request in
            ComposeWindow(request: request)
                .environmentObject(app)
                .environmentObject(pgp)
                .tint(Theme.aegean)
        }
        .defaultSize(width: 720, height: 640)

        WindowGroup("Message", id: WindowID.thread, for: ThreadWindowRequest.self) { $request in
            ThreadWindow(request: request)
                .environmentObject(app)
                .environmentObject(pgp)
                .tint(Theme.aegean)
        }
        .defaultSize(width: 820, height: 760)

        Settings {
            MacSettingsView()
                .environmentObject(app)
                .environmentObject(pgp)
                .tint(Theme.aegean)
        }
    }
}

enum WindowID {
    static let main = "main"
    static let compose = "compose"
    static let thread = "thread"
}

/// App-wide Mac behaviour: the privacy lock, new-mail checks and notification clicks.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private weak var app: AppModel?
    private weak var pgp: PGPStore?
    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Wires lock and watcher to the shared models once the first window exists.
    func attach(app: AppModel, pgp: PGPStore) {
        guard self.app == nil else { return }
        self.app = app
        self.pgp = pgp
        MailWatcher.shared.start(app: app)

        // iOS locks when Aeolet leaves the foreground. The Mac equivalent: hidden, asleep, or the screen locked.
        // Switching to another app does not lock, because Mac windows stay on screen side by side.
        let lock: @Sendable (Notification) -> Void = { [weak self] _ in Task { @MainActor in self?.leaveForeground() } }
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: .main, using: lock),
            workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: lock),
            workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main, using: lock),
            workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main, using: lock),
            DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main, using: lock),
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.app?.didBecomeActive() }
            },
        ]
    }

    private func leaveForeground() {
        app?.didEnterBackground()
        pgp?.forgetPassphrases()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { true }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.list, .banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let account = info["account"] as? String, let thread = info["threadID"] as? String, !thread.isEmpty else { return }
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            if let window = MailWindowModel.lastActive {
                Task { await window.reveal(account: account, threadID: thread) }
            }
        }
    }
}

extension Notification.Name {
    /// Posted after a timed check found new inbox mail.
    static let aeoletNewMail = Notification.Name("AeoletNewMail")
}
