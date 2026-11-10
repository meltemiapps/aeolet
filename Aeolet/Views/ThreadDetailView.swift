import QuickLook
import SwiftUI

struct ThreadDetailView: View {
    let account: String
    let summary: ThreadSummary
    let mailbox: MailboxModel

    @StateObject private var model: ThreadModel
    @EnvironmentObject private var pgp: PGPStore
    @Environment(\.dismiss) private var dismiss
    @State private var compose: ComposeContext?
    @State private var passphrase = ""
    @State private var pendingLink: URL?
    @Environment(\.openURL) private var openURL

    init(account: String, summary: ThreadSummary, mailbox: MailboxModel) {
        self.account = account
        self.summary = summary
        self.mailbox = mailbox
        _model = StateObject(wrappedValue: ThreadModel(account: account, threadID: summary.id))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Text(summary.subject).font(.title3.bold()).padding(.horizontal)
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange).padding(.horizontal)
                }
                ForEach(model.messages) { message in
                    MessageCard(message: message, model: model, pgpEnabled: pgp.isEnabled, compose: $compose, pendingLink: $pendingLink)
                }
            }
            .padding(.vertical)
        }
        .overlay { if model.isLoading { ProgressView() } }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button { Task { await act { try await model.archive() } } } label: { Image(systemName: "archivebox") }
                    .accessibilityLabel("Archive")
                Spacer()
                Button { Task { await act { try await model.trash() } } } label: { Image(systemName: "trash") }
                    .accessibilityLabel("Bin")
                Spacer()
                Button {
                    if let last = model.messages.last { compose = ComposeContext(mode: .reply, source: last) }
                } label: { Image(systemName: "arrowshape.turn.up.left") }
                    .accessibilityLabel("Reply")
            }
        }
        .task {
            await model.load()
            mailbox.markedRead(summary.id)
        }
        .sheet(item: $compose) { context in
            ComposeView(account: account, context: context)
        }
        .alert("Key passphrase", isPresented: Binding(
            get: { model.passphraseTarget != nil },
            set: { if !$0 { model.passphraseTarget = nil } }
        )) {
            SecureField("Passphrase", text: $passphrase)
            Button("Decrypt") {
                let value = passphrase
                passphrase = ""
                Task { await model.submitPassphrase(value) }
            }
            Button("Cancel", role: .cancel) { passphrase = "" }
        } message: {
            Text("Held in memory until Aeolet leaves the foreground.")
        }
        .confirmationDialog("Open this link?", isPresented: Binding(
            get: { pendingLink != nil },
            set: { if !$0 { pendingLink = nil } }
        ), titleVisibility: .visible) {
            Button("Open") { if let url = pendingLink { openURL(url) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(pendingLink?.absoluteString ?? "")
        }
    }

    private func act(_ action: () async throws -> Void) async {
        do {
            try await action()
            mailbox.removeLocally(summary.id)
            dismiss()
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}

private struct MessageCard: View {
    let message: ThreadMessage
    @ObservedObject var model: ThreadModel
    let pgpEnabled: Bool
    @Binding var compose: ComposeContext?
    @Binding var pendingLink: URL?

    @State private var height: CGFloat = 80
    @State private var allowRemote = false
    @State private var preview: URL?
    @State private var attachmentError: String?

    private var isEncrypted: Bool { message.pgp == .locked || message.wasEncrypted }

    private var hasRemoteContent: Bool {
        guard let html = message.body.html else { return false }
        return html.range(of: "src\\s*=\\s*[\"']?https?:", options: [.regularExpression, .caseInsensitive]) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if message.isExpanded {
                security
                if message.pgp != .locked {
                    if hasRemoteContent && !allowRemote && !isEncrypted {
                        Button("Load remote images", systemImage: "photo") { allowRemote = true }
                            .font(.footnote)
                    }
                    MessageWebView(html: message.body.renderableHTML, allowRemoteContent: allowRemote && !isEncrypted,
                                   height: $height, onLink: { pendingLink = $0 })
                        .frame(height: height)
                    attachments
                }
                actions
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 10)
        .quickLookPreview($preview)
        .onDisappear {
            if let preview { try? FileManager.default.removeItem(at: preview) }
        }
    }

    private var header: some View {
        Button { model.toggleExpanded(message.id) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(message.from.displayNameOnly).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Text(message.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
                Text(message.from.emailAddressOnly).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if message.isExpanded, !message.to.isEmpty {
                    Text("To \(message.to)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var security: some View {
        switch message.pgp {
        case .none:
            EmptyView()
        case .locked:
            VStack(alignment: .leading, spacing: 8) {
                Label("End-to-end encrypted", systemImage: "lock.fill").font(.footnote.weight(.semibold))
                if pgpEnabled {
                    Button("Decrypt") { Task { await model.requestDecrypt(message.id) } }
                        .buttonStyle(.borderedProminent)
                } else {
                    Text("Turn on PGP in Settings to read this message.").font(.footnote).foregroundStyle(.secondary)
                }
            }
        case let .decrypted(state, signer):
            VStack(alignment: .leading, spacing: 4) {
                Label("Decrypted on this device", systemImage: "lock.open.fill").font(.footnote.weight(.semibold)).foregroundStyle(.green)
                signatureLine(state, signer)
            }
        case let .signed(state, signer):
            signatureLine(state, signer)
        case let .failed(reason):
            VStack(alignment: .leading, spacing: 8) {
                Label(reason, systemImage: "xmark.octagon").font(.footnote).foregroundStyle(.red)
                Button("Try again") { Task { await model.requestDecrypt(message.id) } }
                    .font(.footnote)
            }
        }
    }

    @ViewBuilder
    private func signatureLine(_ state: SignatureState, _ signer: String) -> some View {
        switch state {
        case .none:
            Label("Not signed: the sender cannot be proven", systemImage: "signature").font(.footnote).foregroundStyle(.secondary)
        case .valid:
            Label(PGPStore.shared.isVerified(email: message.from) ? "Signature verified, key confirmed" : "Signature valid, key not yet confirmed",
                  systemImage: "checkmark.seal.fill")
                .font(.footnote)
                .foregroundStyle(PGPStore.shared.isVerified(email: message.from) ? Color.green : Color.orange)
        case .invalid:
            Label("Signature invalid: this message may have been altered", systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.red)
        case .unknownKey:
            Label("Signed by a key you do not have\(signer.isEmpty ? "" : " (\(signer))")", systemImage: "questionmark.circle").font(.footnote).foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var attachments: some View {
        ForEach(message.body.attachments) { item in
            Button { Task { await open(item) } } label: {
                Label("\(item.filename) · \(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))", systemImage: "paperclip")
                    .font(.footnote)
                    .lineLimit(1)
            }
        }
        if let attachmentError {
            Text(attachmentError).font(.footnote).foregroundStyle(.red)
        }
    }

    private var actions: some View {
        HStack(spacing: 20) {
            Button("Reply", systemImage: "arrowshape.turn.up.left") { compose = ComposeContext(mode: .reply, source: message) }
            Button("All", systemImage: "arrowshape.turn.up.left.2") { compose = ComposeContext(mode: .replyAll, source: message) }
            Button("Forward", systemImage: "arrowshape.turn.up.right") { compose = ComposeContext(mode: .forward, source: message) }
        }
        .font(.footnote)
        .disabled(message.pgp == .locked)
    }

    private func open(_ item: MailAttachment) async {
        // Quick Look needs a file on disk. Decrypted content must never be written to disk,
        // so attachments of encrypted messages are not previewed.
        guard !message.wasEncrypted else {
            attachmentError = "Attachments of encrypted messages can't be previewed, because previewing would write the decrypted file to storage."
            return
        }
        do {
            let data = try await model.attachmentData(item)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let safeName = (item.filename as NSString).lastPathComponent
            let url = folder.appendingPathComponent(safeName.isEmpty ? "attachment" : safeName)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            preview = url
        } catch {
            attachmentError = "Could not open \(item.filename)."
        }
    }
}
