import SwiftUI

/// A viewer window: accounts and labels | conversations | the selected conversation.
struct MainWindow: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var window = MailWindowModel()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack {
            content
            #if DEBUG
            if MockGmail.isActive { MockGmailProbe() }
            #endif
        }
        .lockable()
        .focusedSceneObject(window)
        .onAppear { window.openWindow = openWindow }
        .background(WindowAccessor { nsWindow in
            MailWindowModel.track(window, in: nsWindow)
            #if DEBUG
            MacWindowSizing.apply(to: nsWindow)
            #endif
        })
        .alert("Aeolet", isPresented: Binding(
            get: { app.errorMessage != nil },
            set: { if !$0 { app.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        if !AppConfig.isConfigured {
            ContentUnavailableView {
                Label("Google client ID needed", systemImage: "key")
            } description: {
                Text("Add your own Google OAuth client ID to Config.xcconfig and rebuild. The README has the steps.")
            }
            .frame(minWidth: 600, minHeight: 400)
        } else if !app.isLoaded {
            ProgressView().frame(minWidth: 600, minHeight: 400)
        } else if app.accounts.isEmpty {
            MacSignInView()
        } else {
            MailSplitView(window: window)
        }
    }
}

struct MailSplitView: View {
    @ObservedObject var window: MailWindowModel
    @EnvironmentObject private var app: AppModel
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(window: window)
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 320)
        } content: {
            Group {
                if let mailbox = window.mailbox {
                    ThreadListView(window: window, mailbox: mailbox)
                } else {
                    Color.clear
                }
            }
            .navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 560)
        } detail: {
            if let thread = window.thread {
                MacThreadView(model: thread, window: window).id(thread.threadID)
            } else {
                ContentUnavailableView("No Conversation Selected", systemImage: "envelope")
            }
        }
        .frame(minWidth: 900, minHeight: 520)
        .onAppear { window.syncAccounts(app.accounts, preferred: app.currentAccount) }
        .onChange(of: app.accounts) { _, accounts in window.syncAccounts(accounts, preferred: app.currentAccount) }
        .onChange(of: window.selection?.account) { _, account in if let account { app.select(account) } }
        .onReceive(NotificationCenter.default.publisher(for: .aeoletNewMail)) { _ in
            if window.selection?.label == "INBOX" { Task { await window.mailbox?.refresh() } }
        }
        .alert("Aeolet", isPresented: Binding(
            get: { window.errorMessage != nil },
            set: { if !$0 { window.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(window.errorMessage ?? "")
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var window: MailWindowModel
    @EnvironmentObject private var app: AppModel

    var body: some View {
        List(selection: $window.selection) {
            ForEach(app.accounts, id: \.self) { account in
                AccountSection(account: account, mailbox: window.mailboxModel(for: account))
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button {
                Task { await app.signIn() }
            } label: {
                Label("Add Account", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .disabled(app.isSigningIn)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AccountSection: View {
    let account: String
    @ObservedObject var mailbox: MailboxModel

    /// Until Gmail answers, the inbox is still there to choose.
    private var labels: [GmailLabel] {
        mailbox.labels.isEmpty
            ? [GmailLabel(id: "INBOX", name: "INBOX", type: "system", messagesUnread: nil, threadsUnread: nil)]
            : mailbox.labels
    }

    var body: some View {
        Section(account) {
            ForEach(labels) { label in
                Label(label.displayName, systemImage: label.symbol)
                    .badge(label.messagesUnread ?? 0)
                    .tag(SidebarItem(account: account, label: label.id))
                    .accessibilityIdentifier("label-\(account)-\(label.id)")
            }
        }
    }
}

// MARK: - Conversation list

struct ThreadListView: View {
    @ObservedObject var window: MailWindowModel
    @ObservedObject var mailbox: MailboxModel

    var body: some View {
        List(selection: $window.selectedThreadID) {
            if let message = mailbox.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .selectionDisabled()
            }
            ForEach(mailbox.threads) { thread in
                MacThreadRow(thread: thread)
                    .accessibilityIdentifier("thread-\(thread.subject)")
                    .tag(thread.id)
                    .task { await mailbox.loadMoreIfNeeded(current: thread) }
                    .swipeActions(edge: .leading) {
                        Button { Task { await mailbox.toggleRead(thread) } } label: {
                            Label(thread.isUnread ? "Read" : "Unread", systemImage: thread.isUnread ? "envelope.open" : "envelope.badge")
                        }
                        .tint(Theme.aegean)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { Task { await mailbox.trash(thread) } } label: {
                            Label("Bin", systemImage: "trash")
                        }
                        if thread.labelIds.contains("INBOX") {
                            Button { Task { await mailbox.archive(thread) } } label: {
                                Label("Archive", systemImage: "archivebox")
                            }
                            .tint(.indigo)
                        }
                    }
            }
            if mailbox.isLoading && !mailbox.threads.isEmpty {
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                    .selectionDisabled()
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: ThreadSummary.ID.self) { ids in
            if let id = ids.first, let thread = mailbox.threads.first(where: { $0.id == id }) {
                Button("Open in New Window") {
                    window.selectedThreadID = id
                    window.openInNewWindow()
                }
                Divider()
                Button(thread.isUnread ? "Mark as Read" : "Mark as Unread") { Task { await mailbox.toggleRead(thread) } }
                Button(thread.isStarred ? "Remove Star" : "Star") { Task { await mailbox.toggleStar(thread) } }
                Divider()
                if thread.labelIds.contains("INBOX") {
                    Button("Archive") { Task { await mailbox.archive(thread) } }
                }
                Button("Move to Bin") { Task { await mailbox.trash(thread) } }
                Button("Report Spam") { Task { await mailbox.markSpam(thread) } }
            }
        } primaryAction: { ids in
            if let id = ids.first {
                window.selectedThreadID = id
                window.openInNewWindow()
            }
        }
        .overlay {
            if mailbox.threads.isEmpty {
                if mailbox.isLoading {
                    ProgressView()
                } else if mailbox.errorMessage == nil {
                    ContentUnavailableView("No Conversations", systemImage: "tray")
                }
            }
        }
        .navigationTitle(mailbox.title)
        .navigationSubtitle(mailbox.account)
        .searchable(text: $mailbox.query, placement: .toolbar, prompt: "Search mail")
        .onSubmit(of: .search) { Task { await mailbox.runSearch() } }
        .onChange(of: mailbox.query) { _, value in
            if value.isEmpty { Task { await mailbox.clearSearch() } }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { Task { await window.refresh() } } label: { Label("Get New Mail", systemImage: "arrow.clockwise") }
                    .help("Get new mail")
                Button { window.compose(.new) } label: { Label("New Message", systemImage: "square.and.pencil") }
                    .help("New message (⌘N)")
            }
        }
    }
}

struct MacThreadRow: View {
    let thread: ThreadSummary

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(thread.isUnread ? Theme.aegean : Color.clear)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(thread.sender.isEmpty ? "(Unknown)" : thread.sender)
                        .font(.body.weight(thread.isUnread ? .semibold : .regular))
                        .lineLimit(1)
                    if thread.messageCount > 1 {
                        Text("\(thread.messageCount)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    if thread.isStarred {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                    }
                    Text(Self.label(for: thread.date)).font(.caption).foregroundStyle(.secondary)
                }
                Text(thread.subject).font(.callout.weight(thread.isUnread ? .medium : .regular)).lineLimit(1)
                switch thread.preview {
                case let .text(snippet):
                    Text(snippet).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                case .encrypted:
                    Text("\(Image(systemName: "lock.fill")) Encrypted message").font(.callout).foregroundStyle(.secondary)
                case .signed:
                    Text("\(Image(systemName: "signature")) Signed message").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    static func label(for date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

// MARK: - Sign-in

struct MacSignInView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "envelope.badge.shield.half.filled")
                .font(.system(size: 64))
                .foregroundStyle(Theme.aegean)
            VStack(spacing: 6) {
                Text("Aeolet").font(.largeTitle.bold())
                Text("Open-source Gmail, private by design.").foregroundStyle(.secondary)
            }
            Button {
                Task { await app.signIn() }
            } label: {
                Group {
                    if app.isSigningIn { ProgressView().controlSize(.small) } else { Text("Sign in with Google") }
                }
                .frame(width: 220)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(app.isSigningIn)
            Text("Your password goes only to Google. Aeolet receives a revocable token, stored in this Mac's Keychain.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)
        }
        .padding(40)
        .frame(minWidth: 640, minHeight: 460)
    }
}
