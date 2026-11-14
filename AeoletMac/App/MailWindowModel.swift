import AppKit
import SwiftUI

/// What the sidebar selects: one label of one account.
struct SidebarItem: Hashable {
    let account: String
    let label: String
}

/// Opens a compose window. The context (which can hold a decrypted message being quoted) stays in memory
/// and is never written into window restoration data; only this request's id and account are.
struct ComposeRequest: Codable, Hashable {
    var id = UUID()
    let account: String
}

@MainActor
enum ComposeRegistry {
    private static var contexts: [UUID: ComposeContext] = [:]

    static func register(_ context: ComposeContext, account: String) -> ComposeRequest {
        let request = ComposeRequest(account: account)
        contexts[request.id] = context
        return request
    }

    /// A restored window after relaunch has no context any more, so it opens as a new message.
    static func take(_ request: ComposeRequest) -> ComposeContext {
        contexts.removeValue(forKey: request.id) ?? .new
    }
}

/// Opens one conversation in its own window.
struct ThreadWindowRequest: Codable, Hashable {
    let account: String
    let threadID: String
    let subject: String
}

/// The state of one viewer window: which label is open, which conversation is selected, and the commands
/// the menu bar sends to whichever window is in front.
@MainActor
final class MailWindowModel: ObservableObject {
    @Published var selection: SidebarItem? {
        didSet { if selection != oldValue { selectionChanged(from: oldValue) } }
    }
    @Published var selectedThreadID: ThreadSummary.ID? {
        didSet { if selectedThreadID != oldValue { openSelectedThread() } }
    }
    @Published private(set) var mailbox: MailboxModel?
    @Published private(set) var thread: ThreadModel?
    @Published private(set) var mailboxes: [String: MailboxModel] = [:]
    @Published var errorMessage: String?

    /// The viewer window used last, which shows conversations opened from notifications.
    private(set) static weak var lastActive: MailWindowModel?
    private var keyObserver: NSObjectProtocol?

    private static let byWindow = NSMapTable<NSWindow, MailWindowModel>.weakToWeakObjects()

    /// The model behind a viewer or conversation window, for keys the menu bar can't see.
    static func model(for window: NSWindow?) -> MailWindowModel? {
        window.flatMap { byWindow.object(forKey: $0) }
    }

    static func track(_ model: MailWindowModel, in window: NSWindow, viewer: Bool = true) {
        byWindow.setObject(model, forKey: window)
        guard viewer else { return }
        if lastActive == nil || window.isKeyWindow { lastActive = model }
        model.keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak model] _ in
            Task { @MainActor in if let model { lastActive = model } }
        }
    }

    var openWindow: OpenWindowAction?
    /// For a window that shows a single conversation: closes it once the conversation is archived or binned.
    var closeWindow: (() -> Void)?

    var account: String? { selection?.account ?? thread?.account }

    func mailboxModel(for account: String) -> MailboxModel {
        if let existing = mailboxes[account] { return existing }
        let model = MailboxModel(account: account)
        mailboxes[account] = model
        Task { await model.loadLabels() }
        return model
    }

    func syncAccounts(_ accounts: [String], preferred: String?) {
        for gone in mailboxes.keys where !accounts.contains(gone) { mailboxes[gone] = nil }
        for account in accounts { _ = mailboxModel(for: account) }
        if let selection, accounts.contains(selection.account) { return }
        if let first = preferred.flatMap({ accounts.contains($0) ? $0 : nil }) ?? accounts.first {
            selection = SidebarItem(account: first, label: "INBOX")
        } else {
            selection = nil
        }
    }

    private func selectionChanged(from old: SidebarItem?) {
        guard let selection else {
            mailbox = nil
            selectedThreadID = nil
            return
        }
        let model = mailboxModel(for: selection.account)
        let accountChanged = old?.account != selection.account || mailbox !== model
        mailbox = model
        selectedThreadID = nil
        Task {
            if accountChanged && model.selectedLabelID == selection.label && model.threads.isEmpty {
                await model.start()
            } else {
                await model.select(label: selection.label)
            }
        }
    }

    private func openSelectedThread() {
        guard let id = selectedThreadID, let account = selection?.account else {
            thread = nil
            return
        }
        let model = ThreadModel(account: account, threadID: id)
        thread = model
        Task {
            await model.load()
            mailbox?.markedRead(id)
            MailWatcher.shared.updateBadgeSoon()
        }
    }

    /// For a window that shows one conversation and nothing else.
    func showSingle(account: String, threadID: String) {
        _ = mailboxModel(for: account)
        let model = ThreadModel(account: account, threadID: threadID)
        thread = model
        Task {
            await model.load()
            MailWatcher.shared.updateBadgeSoon()
        }
    }

    /// Shows a conversation from a notification: that account's inbox, with the conversation selected.
    func reveal(account: String, threadID: String) async {
        let item = SidebarItem(account: account, label: "INBOX")
        if selection != item { selection = item }
        await mailbox?.refresh()
        selectedThreadID = threadID
    }

    // MARK: Commands

    var selectedSummary: ThreadSummary? {
        guard let id = selectedThreadID else { return nil }
        return mailbox?.threads.first { $0.id == id }
    }

    var hasThread: Bool { thread != nil }
    var canReply: Bool { thread?.messages.last.map { $0.pgp != .locked } ?? false }

    func compose(_ mode: ComposeContext.Mode) {
        guard let account else { return }
        let context: ComposeContext
        if mode == .new {
            context = .new
        } else {
            guard let source = thread?.messages.last, source.pgp != .locked else { return }
            context = ComposeContext(mode: mode, source: source)
        }
        openWindow?(id: WindowID.compose, value: ComposeRegistry.register(context, account: account))
    }

    func reply(to message: ThreadMessage, mode: ComposeContext.Mode) {
        guard let account else { return }
        openWindow?(id: WindowID.compose, value: ComposeRegistry.register(ComposeContext(mode: mode, source: message), account: account))
    }

    func openInNewWindow() {
        guard let account, let summary = selectedSummary else { return }
        openWindow?(id: WindowID.thread, value: ThreadWindowRequest(account: account, threadID: summary.id, subject: summary.subject))
    }

    func archive() async { await removeSelected(archive: true) }
    func trash() async { await removeSelected(archive: false) }

    private func removeSelected(archive: Bool) async {
        if let mailbox, let summary = selectedSummary {
            selectNeighbour(of: summary.id)
            if archive { await mailbox.archive(summary) } else { await mailbox.trash(summary) }
            MailWatcher.shared.updateBadgeSoon()
            return
        }
        guard let thread else { return }
        do {
            if archive { try await thread.archive() } else { try await thread.trash() }
            closeWindow?()
            MailWatcher.shared.updateBadgeSoon()
        } catch {
            errorMessage = error.userMessage
        }
    }

    /// Like Mail: after a conversation leaves the list, the next one down is selected.
    private func selectNeighbour(of id: String) {
        guard let threads = mailbox?.threads, let index = threads.firstIndex(where: { $0.id == id }) else { return }
        let next = index + 1 < threads.count ? threads[index + 1] : (index > 0 ? threads[index - 1] : nil)
        selectedThreadID = next?.id
    }

    func toggleRead() async {
        guard let mailbox, let summary = selectedSummary else { return }
        await mailbox.toggleRead(summary)
        MailWatcher.shared.updateBadgeSoon()
    }

    func toggleStar() async {
        guard let mailbox, let summary = selectedSummary else { return }
        await mailbox.toggleStar(summary)
    }

    func markSpam() async {
        guard let mailbox, let summary = selectedSummary else { return }
        selectNeighbour(of: summary.id)
        await mailbox.markSpam(summary)
    }

    func refresh() async {
        await mailbox?.refresh()
        MailWatcher.shared.updateBadgeSoon()
    }
}
