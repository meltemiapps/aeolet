import AppKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// One conversation, in the detail column or in its own window.
struct MacThreadView: View {
    @ObservedObject var model: ThreadModel
    @ObservedObject var window: MailWindowModel
    @EnvironmentObject private var pgp: PGPStore
    @State private var passphrase = ""
    @State private var pendingLink: URL?
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Text(model.subject.isEmpty ? " " : model.subject)
                    .font(.title2.bold())
                    .textSelection(.enabled)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).padding(.horizontal, 20)
                }
                ForEach(model.messages) { message in
                    MacMessageCard(message: message, model: model, window: window, pgpEnabled: pgp.isEnabled, pendingLink: $pendingLink)
                }
            }
            .padding(.vertical, 12)
        }
        .overlay { if model.isLoading { ProgressView() } }
        .navigationTitle(model.subject)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { Task { await window.archive() } } label: { Label("Archive", systemImage: "archivebox") }
                    .help("Archive (E)")
                Button { Task { await window.trash() } } label: { Label("Bin", systemImage: "trash") }
                    .help("Move to Bin (⌘⌫)")
                labelMenu
                Button { window.compose(.reply) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                    .help("Reply (⌘R)")
                    .disabled(!window.canReply)
                Button { window.compose(.replyAll) } label: { Label("Reply All", systemImage: "arrowshape.turn.up.left.2") }
                    .help("Reply All (⇧⌘R)")
                    .disabled(!window.canReply)
                Button { window.compose(.forward) } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
                    .help("Forward (⇧⌘F)")
                    .disabled(!window.canReply)
            }
        }
        .alert("Key passphrase", isPresented: $model.isAskingPassphrase) {
            SecureField("Passphrase", text: $passphrase)
            Button("Decrypt") {
                let value = passphrase
                passphrase = ""
                Task { await model.submitPassphrase(value) }
            }
            Button("Cancel", role: .cancel) {
                passphrase = ""
                model.cancelPassphrase()
            }
        } message: {
            Text("Held in memory until Aeolet is hidden, the Mac sleeps or the screen locks.")
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

    private var labelMenu: some View {
        Menu {
            let userLabels = (window.account.flatMap { window.mailboxes[$0]?.labels } ?? []).filter { $0.type == "user" }
            if userLabels.isEmpty { Text("No labels yet") }
            ForEach(userLabels) { label in
                Toggle(label.displayName, isOn: Binding(
                    get: { model.labelIDs.contains(label.id) },
                    set: { _ in Task { await model.toggleLabel(label.id) } }
                ))
            }
        } label: {
            Label("Labels", systemImage: "tag")
        }
        .help("Labels")
    }
}

/// A conversation in a window of its own (double-click a conversation, or Message > Open in New Window).
struct ThreadWindow: View {
    let request: ThreadWindowRequest?
    @StateObject private var window = MailWindowModel()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let thread = window.thread {
                MacThreadView(model: thread, window: window)
            } else {
                ContentUnavailableView("No Conversation", systemImage: "envelope")
            }
        }
        .frame(minWidth: 520, minHeight: 400)
        .background(WindowAccessor { MailWindowModel.track(window, in: $0, viewer: false) })
        .lockable()
        .focusedSceneObject(window)
        .onAppear {
            window.openWindow = openWindow
            window.closeWindow = { dismiss() }
            if let request, window.thread == nil { window.showSingle(account: request.account, threadID: request.threadID) }
        }
    }
}

private struct MacMessageCard: View {
    let message: ThreadMessage
    @ObservedObject var model: ThreadModel
    @ObservedObject var window: MailWindowModel
    let pgpEnabled: Bool
    @Binding var pendingLink: URL?

    @State private var height: CGFloat = 60
    @State private var allowRemote = false
    @State private var preview: URL?
    @State private var attachmentError: String?

    private var isEncrypted: Bool { message.pgp == .locked || message.wasEncrypted }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if message.isExpanded {
                security
                if message.pgp != .locked {
                    if MessageHTML.hasRemoteContent(message.body.html) && !allowRemote && !isEncrypted {
                        Button("Load Remote Images", systemImage: "photo") { allowRemote = true }
                            .controlSize(.small)
                    }
                    MacMessageWebView(html: message.body.renderableHTML, allowRemoteContent: allowRemote && !isEncrypted,
                                      height: $height, onLink: { pendingLink = $0 })
                        .frame(height: height)
                        .padding(10)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
                        .environment(\.colorScheme, .light)
                    attachments
                }
                actions
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
        .padding(.horizontal, 14)
        .quickLookPreview($preview)
        .onChange(of: preview) { old, _ in
            if let old { try? FileManager.default.removeItem(at: old.deletingLastPathComponent()) }
        }
    }

    private var header: some View {
        Button { model.toggleExpanded(message.id) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(message.from.displayNameOnly).font(.headline).lineLimit(1)
                    Text(message.from.emailAddressOnly).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Text(message.date.formatted(date: .abbreviated, time: .shortened)).font(.callout).foregroundStyle(.secondary)
                }
                if message.isExpanded, !message.to.isEmpty {
                    Text("To: \(message.to)").font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                if message.isExpanded, !message.cc.isEmpty {
                    Text("Cc: \(message.cc)").font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .contentShape(Rectangle())
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
                Label("End-to-end encrypted", systemImage: "lock.fill").font(.callout.weight(.semibold))
                if pgpEnabled {
                    Button("Decrypt") { Task { await model.requestDecrypt(message.id) } }
                        .buttonStyle(.borderedProminent)
                } else {
                    Text("Turn on PGP in Settings to read this message.").font(.callout).foregroundStyle(.secondary)
                }
            }
        case let .decrypted(state, signer):
            VStack(alignment: .leading, spacing: 4) {
                Label("Decrypted on this Mac", systemImage: "lock.open.fill").font(.callout.weight(.semibold)).foregroundStyle(.green)
                signatureLine(state, signer)
            }
        case let .signed(state, signer):
            signatureLine(state, signer)
        case let .failed(reason):
            VStack(alignment: .leading, spacing: 8) {
                Label(reason, systemImage: "xmark.octagon").font(.callout).foregroundStyle(.red)
                Button("Try Again") { Task { await model.requestDecrypt(message.id) } }
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func signatureLine(_ state: SignatureState, _ signer: String) -> some View {
        switch state {
        case .none:
            Label("Not signed: the sender cannot be proven", systemImage: "signature").font(.callout).foregroundStyle(.secondary)
        case .valid:
            let confirmed = PGPStore.shared.isVerified(email: message.from)
            Label(confirmed ? "Signature verified, key confirmed" : "Signature valid, key not yet confirmed", systemImage: "checkmark.seal.fill")
                .font(.callout)
                .foregroundStyle(confirmed ? Color.green : Color.orange)
        case .invalid:
            Label("Signature invalid: this message may have been altered", systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.red)
        case .unknownKey:
            Label("Signed by a key you do not have\(signer.isEmpty ? "" : " (\(signer))")", systemImage: "questionmark.circle").font(.callout).foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var attachments: some View {
        if !message.body.attachments.isEmpty {
            FlowRow(spacing: 8) {
                ForEach(message.body.attachments) { item in
                    AttachmentChip(item: item, encrypted: message.wasEncrypted, model: model,
                                   onPreview: { Task { await quickLook(item) } },
                                   onError: { attachmentError = $0 })
                }
            }
        }
        if let attachmentError {
            Text(attachmentError).font(.callout).foregroundStyle(.red)
        }
    }

    private var actions: some View {
        HStack(spacing: 16) {
            Button("Reply", systemImage: "arrowshape.turn.up.left") { window.reply(to: message, mode: .reply) }
            Button("Reply All", systemImage: "arrowshape.turn.up.left.2") { window.reply(to: message, mode: .replyAll) }
            Button("Forward", systemImage: "arrowshape.turn.up.right") { window.reply(to: message, mode: .forward) }
        }
        .buttonStyle(.borderless)
        .disabled(message.pgp == .locked)
    }

    private func quickLook(_ item: MailAttachment) async {
        // Previewing needs a file on disk; decrypted content is never written to disk.
        guard !message.wasEncrypted else {
            attachmentError = AttachmentFiles.encryptedRefusal
            return
        }
        do {
            preview = try await AttachmentFiles.temporaryCopy(of: item, model: model)
        } catch {
            attachmentError = "Could not open \(item.filename)."
        }
    }
}

/// One attachment: double-click to preview, drag to Finder or another app, or Save to a folder you choose.
private struct AttachmentChip: View {
    let item: MailAttachment
    let encrypted: Bool
    @ObservedObject var model: ThreadModel
    let onPreview: () -> Void
    let onError: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(for: UTType(mimeType: item.mimeType) ?? .data))
                .resizable()
                .frame(width: 20, height: 20)
            Text(item.filename).lineLimit(1)
            Text(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file)).foregroundStyle(.secondary)
            Menu {
                Button("Quick Look") { onPreview() }
                Button("Save Attachment…") { Task { await save() } }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Attachment actions for \(item.filename)")
            .accessibilityIdentifier("attachment-actions-\(item.filename)")
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.5), in: Capsule())
        .contentShape(Capsule())
        .onTapGesture(count: 2) { onPreview() }
        .onDrag { dragProvider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("attachment-\(item.filename)")
        .help("Double-click to preview. Drag to save it somewhere, or to attach it to a new message.")
    }

    private func save() async {
        guard !encrypted else {
            onError(AttachmentFiles.encryptedRefusal)
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = AttachmentFiles.safeName(item.filename)
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true
        #if DEBUG
        if let url = MockSavePanel.destination(for: panel.nameFieldStringValue) {
            await write(to: url)
            return
        }
        #endif
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await write(to: url)
    }

    private func write(to url: URL) async {
        do {
            let data = try await model.attachmentData(item)
            try data.write(to: url, options: .atomic)
            #if DEBUG
            if MockGmail.isActive {
                MockGmailServer.shared.record("SAVE attachment=\(item.filename) bytes=\(data.count) folder=\(url.deletingLastPathComponent().lastPathComponent)")
            }
            #endif
        } catch {
            onError("Could not save \(item.filename): \(error.userMessage)")
        }
    }

    /// Hands the file over only when it's dropped, so nothing is written unless the person drags it somewhere.
    private func dragProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = AttachmentFiles.safeName(item.filename)
        guard !encrypted else {
            onError(AttachmentFiles.encryptedRefusal)
            return provider
        }
        let type = UTType(mimeType: item.mimeType) ?? UTType(filenameExtension: (item.filename as NSString).pathExtension) ?? .data
        let item = self.item
        let model = self.model
        // Apps (including Aeolet's own compose window) can take the bytes; Finder takes the file.
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { completion in
            Task { @MainActor in
                do {
                    completion(try await model.attachmentData(item), nil)
                } catch {
                    completion(nil, error)
                }
            }
            return nil
        }
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            Task { @MainActor in
                do {
                    completion(try await AttachmentFiles.temporaryCopy(of: item, model: model), false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return nil
        }
        return provider
    }
}

@MainActor
enum AttachmentFiles {
    static let encryptedRefusal = "Attachments of encrypted messages can't be saved or previewed, because that would write the decrypted file to disk."

    static func safeName(_ filename: String) -> String {
        let name = (filename as NSString).lastPathComponent.replacingOccurrences(of: ":", with: "-")
        return name.isEmpty || name.hasPrefix(".") ? "attachment" + name : name
    }

    /// Writes the attachment to its own folder in the app's temporary directory.
    static func temporaryCopy(of item: MailAttachment, model: ThreadModel) async throws -> URL {
        let data = try await model.attachmentData(item)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(safeName(item.filename))
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }
}

/// Lays chips out left to right, wrapping onto new lines.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0; var y: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (index, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty && rows[rows.count - 1].width + spacing + size.width > width {
                let y = rows[rows.count - 1].y + rows[rows.count - 1].height + spacing
                rows.append(Row(y: y))
            }
            let gap = rows[rows.count - 1].indices.isEmpty ? 0 : spacing
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += gap + size.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}

#if DEBUG
/// Mock runs only: `-AeoletAutoSave` answers the Save panel without showing it, saving into the app's own
/// temporary folder, so UI tests can check saving (the mock log records what was written).
enum MockSavePanel {
    static func destination(for name: String) -> URL? {
        guard MockGmail.isActive, ProcessInfo.processInfo.arguments.contains("-AeoletAutoSave") else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Saved", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(name)
    }
}
#endif
