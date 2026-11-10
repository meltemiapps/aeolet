import Foundation

@MainActor
final class MailboxModel: ObservableObject {
    let account: String
    private let client: GmailClient

    @Published var labels: [GmailLabel] = []
    @Published var selectedLabelID = "INBOX"
    @Published var threads: [ThreadSummary] = []
    @Published var query = ""
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var nextPage: String?
    private var activeSearch: String?

    init(account: String) {
        self.account = account
        client = GmailClient(account: account)
    }

    var title: String {
        if activeSearch != nil { return "Search" }
        return labels.first { $0.id == selectedLabelID }?.displayName ?? "Inbox"
    }

    func start() async {
        threads = MailCache.load(account: account, label: selectedLabelID)
        await refresh()
        if let found = try? await client.labels() { labels = found }
    }

    func select(label: String) async {
        selectedLabelID = label
        query = ""
        activeSearch = nil
        threads = MailCache.load(account: account, label: label)
        await refresh()
    }

    func runSearch() async {
        activeSearch = query.isEmpty ? nil : query
        await refresh()
    }

    func clearSearch() async {
        guard activeSearch != nil else { return }
        activeSearch = nil
        await refresh()
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await client.threads(labelID: activeSearch == nil ? selectedLabelID : nil, query: activeSearch, pageToken: nil)
            threads = page.items
            nextPage = page.next
            errorMessage = nil
            if activeSearch == nil { MailCache.save(page.items, account: account, label: selectedLabelID) }
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadMoreIfNeeded(current: ThreadSummary) async {
        guard current.id == threads.last?.id, let token = nextPage, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await client.threads(labelID: activeSearch == nil ? selectedLabelID : nil, query: activeSearch, pageToken: token)
            let known = Set(threads.map(\.id))
            threads += page.items.filter { !known.contains($0.id) }
            nextPage = page.next
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func perform(_ id: String, remove: Bool, action: () async throws -> Void) async {
        let snapshot = threads
        if remove { threads.removeAll { $0.id == id } }
        do {
            try await action()
        } catch {
            threads = snapshot
            errorMessage = error.localizedDescription
        }
    }

    func archive(_ thread: ThreadSummary) async {
        await perform(thread.id, remove: true) { try await client.modifyThread(thread.id, remove: ["INBOX"]) }
    }

    func trash(_ thread: ThreadSummary) async {
        await perform(thread.id, remove: true) { try await client.trashThread(thread.id) }
    }

    func markSpam(_ thread: ThreadSummary) async {
        await perform(thread.id, remove: true) { try await client.modifyThread(thread.id, add: ["SPAM"], remove: ["INBOX"]) }
    }

    func toggleRead(_ thread: ThreadSummary) async {
        guard let index = threads.firstIndex(of: thread) else { return }
        threads[index].isUnread.toggle()
        let nowUnread = threads[index].isUnread
        await perform(thread.id, remove: false) {
            try await client.modifyThread(thread.id, add: nowUnread ? ["UNREAD"] : [], remove: nowUnread ? [] : ["UNREAD"])
        }
    }

    func toggleStar(_ thread: ThreadSummary) async {
        guard let index = threads.firstIndex(of: thread) else { return }
        threads[index].isStarred.toggle()
        let nowStarred = threads[index].isStarred
        await perform(thread.id, remove: false) {
            try await client.modifyThread(thread.id, add: nowStarred ? ["STARRED"] : [], remove: nowStarred ? [] : ["STARRED"])
        }
    }

    func markedRead(_ id: String) {
        if let index = threads.firstIndex(where: { $0.id == id }) { threads[index].isUnread = false }
    }

    func removeLocally(_ id: String) {
        threads.removeAll { $0.id == id }
    }
}
