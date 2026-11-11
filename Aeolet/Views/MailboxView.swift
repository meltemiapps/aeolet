import SwiftUI

struct MailboxView: View {
    let account: String
    @EnvironmentObject private var app: AppModel
    @StateObject private var model: MailboxModel
    @State private var showFolders = false
    @State private var showSettings = false
    @State private var compose: ComposeContext?

    init(account: String) {
        self.account = account
        _model = StateObject(wrappedValue: MailboxModel(account: account))
    }

    var body: some View {
        NavigationStack {
            List {
                if let message = model.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                ForEach(model.threads) { thread in
                    NavigationLink(value: thread) {
                        ThreadRow(thread: thread)
                    }
                    .task { await model.loadMoreIfNeeded(current: thread) }
                    .swipeActions(edge: .leading) {
                        Button {
                            Task { await model.toggleRead(thread) }
                        } label: {
                            Label(thread.isUnread ? "Read" : "Unread", systemImage: thread.isUnread ? "envelope.open" : "envelope.badge")
                        }
                        .tint(Theme.aegean)
                        Button {
                            Task { await model.toggleStar(thread) }
                        } label: {
                            Label("Star", systemImage: thread.isStarred ? "star.slash" : "star")
                        }
                        .tint(.yellow)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await model.trash(thread) }
                        } label: {
                            Label("Bin", systemImage: "trash")
                        }
                        if thread.labelIds.contains("INBOX") {
                            Button {
                                Task { await model.archive(thread) }
                            } label: {
                                Label("Archive", systemImage: "archivebox")
                            }
                            .tint(.indigo)
                        }
                    }
                    .contextMenu {
                        Button("Report spam", systemImage: "exclamationmark.octagon") {
                            Task { await model.markSpam(thread) }
                        }
                    }
                }
                if model.isLoading && !model.threads.isEmpty {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            }
            .listStyle(.plain)
            .refreshable { await model.refresh() }
            .overlay {
                if model.threads.isEmpty {
                    if model.isLoading {
                        ProgressView()
                    } else if model.errorMessage == nil {
                        ContentUnavailableView("No conversations", systemImage: "tray")
                    }
                }
            }
            .navigationTitle(model.title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $model.query, placement: Self.searchPlacement, prompt: "Search mail")
            .onSubmit(of: .search) { Task { await model.runSearch() } }
            .onChange(of: model.query) { _, value in
                if value.isEmpty { Task { await model.clearSearch() } }
            }
            .navigationDestination(for: ThreadSummary.self) { thread in
                ThreadDetailView(account: account, summary: thread, mailbox: model)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showFolders = true } label: { Image(systemName: "sidebar.left") }
                        .accessibilityLabel("Folders and accounts")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { compose = .new } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("New message")
                }
            }
        }
        .task { await model.start() }
        .sheet(isPresented: $showFolders) {
            FoldersView(model: model, showSettings: $showSettings)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(item: $compose) { context in
            ComposeView(account: account, context: context)
        }
    }
}

extension MailboxView {
    /// On iPad the default search field sits in the top toolbar, and there it stops the list's
    /// pull-to-refresh control from being installed. The search drawer under the title keeps both working.
    static var searchPlacement: SearchFieldPlacement {
        UIDevice.current.userInterfaceIdiom == .pad ? .navigationBarDrawer(displayMode: .always) : .automatic
    }
}

struct ThreadRow: View {
    let thread: ThreadSummary

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(thread.isUnread ? Theme.aegean : Color.clear)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(thread.sender.isEmpty ? "(Unknown)" : thread.sender)
                        .font(.subheadline.weight(thread.isUnread ? .semibold : .regular))
                        .lineLimit(1)
                    if thread.messageCount > 1 {
                        Text("\(thread.messageCount)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if thread.isStarred {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                    }
                    Text(Self.label(for: thread.date)).font(.caption).foregroundStyle(.secondary)
                }
                Text(thread.subject).font(.subheadline.weight(thread.isUnread ? .medium : .regular)).lineLimit(1)
                switch thread.preview {
                case let .text(snippet):
                    Text(snippet).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                case .encrypted:
                    // Inline images rather than Label, which would shift the row's separator inset.
                    Text("\(Image(systemName: "lock.fill")) Encrypted message").font(.footnote).foregroundStyle(.secondary)
                case .signed:
                    Text("\(Image(systemName: "signature")) Signed message").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private static func label(for date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

struct FoldersView: View {
    @ObservedObject var model: MailboxModel
    @Binding var showSettings: Bool
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Accounts") {
                    ForEach(app.accounts, id: \.self) { account in
                        Button {
                            app.select(account)
                            dismiss()
                        } label: {
                            HStack {
                                Text(account).foregroundStyle(.primary)
                                Spacer()
                                if account == app.currentAccount { Image(systemName: "checkmark") }
                            }
                        }
                    }
                    Button("Add Gmail account", systemImage: "plus") {
                        Task { await app.signIn() }
                    }
                }
                Section("Folders") {
                    ForEach(model.labels) { label in
                        Button {
                            dismiss()
                            Task { await model.select(label: label.id) }
                        } label: {
                            HStack {
                                Label(label.displayName, systemImage: label.symbol).foregroundStyle(.primary)
                                Spacer()
                                if let unread = label.messagesUnread, unread > 0 {
                                    Text("\(unread)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Mailboxes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings") {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showSettings = true }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
