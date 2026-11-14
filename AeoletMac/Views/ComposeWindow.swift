import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A compose window. Each message gets its own window, so several drafts can be open at once.
struct ComposeWindow: View {
    let request: ComposeRequest?
    @EnvironmentObject private var app: AppModel

    var body: some View {
        Group {
            if let request, app.accounts.contains(request.account) {
                MacComposeView(account: request.account, context: ComposeRegistry.take(request))
            } else {
                ContentUnavailableView("Nothing to Compose", systemImage: "square.and.pencil")
                    .frame(minWidth: 400, minHeight: 300)
            }
        }
        .lockable()
    }
}

struct MacComposeView: View {
    @StateObject private var model: ComposeModel
    @State private var showCc = false
    @State private var showImporter = false
    @State private var passphrase = ""
    @State private var isDropTarget = false
    @State private var confirmClose = false
    @State private var sent = false
    @State private var nsWindow: NSWindow?
    @State private var closeGuard: WindowCloseGuard?

    init(account: String, context: ComposeContext) {
        _model = StateObject(wrappedValue: ComposeModel(account: account, context: context))
    }

    private var title: String {
        model.subject.isEmpty ? "New Message" : model.subject
    }

    private var hasContent: Bool {
        !model.to.isEmpty || !model.cc.isEmpty || !model.bcc.isEmpty || !model.subject.isEmpty
            || !model.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.attachments.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                LabeledContent("From") { Text(model.account).foregroundStyle(.secondary) }
                TextField("To:", text: $model.to, prompt: Text("name@example.org")).accessibilityIdentifier("compose-to")
                if showCc || !model.cc.isEmpty || !model.bcc.isEmpty {
                    TextField("Cc:", text: $model.cc).accessibilityIdentifier("compose-cc")
                    TextField("Bcc:", text: $model.bcc).accessibilityIdentifier("compose-bcc")
                }
                TextField("Subject:", text: $model.subject).accessibilityIdentifier("compose-subject")
                if model.canUsePGP {
                    HStack(spacing: 20) {
                        Toggle("Encrypt", isOn: $model.encrypt).accessibilityIdentifier("compose-encrypt")
                        Toggle("Sign", isOn: $model.sign).accessibilityIdentifier("compose-sign")
                    }
                    if model.encrypt {
                        Text("The body and attachments are encrypted. The subject, sender and recipients stay visible to mail servers. Encrypted messages cannot be saved as drafts.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !model.missingKeys.isEmpty {
                        Text("No key for: \(model.missingKeys.joined(separator: ", "))").font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.columns)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            TextEditor(text: $model.body)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .accessibilityLabel("Message body")
                .accessibilityIdentifier("compose-body")

            if !model.attachments.isEmpty {
                Divider()
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(model.attachments) { item in
                            HStack(spacing: 6) {
                                Image(systemName: "paperclip")
                                Text(item.filename).lineLimit(1)
                                Text(ByteCountFormatter.string(fromByteCount: Int64(item.data.count), countStyle: .file))
                                    .foregroundStyle(.secondary)
                                Button {
                                    model.attachments.removeAll { $0.id == item.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove \(item.filename)")
                            }
                            .font(.callout)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(nsColor: .quaternaryLabelColor).opacity(0.5), in: Capsule())
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("outgoing-\(item.filename)")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.aegean, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL, .item], isTargeted: $isDropTarget) { providers in
            receiveDrop(providers)
            return true
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { attachFile() } label: { Label("Attach File", systemImage: "paperclip") }
                    .help("Attach a file (⇧⌘A), or drag files into this window")
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                if !showCc && model.cc.isEmpty && model.bcc.isEmpty {
                    Button { showCc = true } label: { Label("Cc and Bcc", systemImage: "person.2") }
                        .help("Add Cc or Bcc")
                }
                Button { Task { await saveDraftAndClose() } } label: { Label("Save Draft", systemImage: "square.and.arrow.down") }
                    .help("Save as a Gmail draft (⌘S)")
                    .keyboardShortcut("s")
                    .disabled(!model.canSaveDraft || model.isWorking)
                if model.isWorking {
                    ProgressView().controlSize(.small)
                } else {
                    Button { sendNow() } label: { Label("Send", systemImage: "paperplane.fill") }
                        .help("Send (⇧⌘D)")
                        .keyboardShortcut("d", modifiers: [.command, .shift])
                }
            }
        }
        .background(WindowAccessor { window in
            guard nsWindow !== window else { return }
            nsWindow = window
            closeGuard = WindowCloseGuard(window: window) {
                if sent || !hasContent { return true }
                confirmClose = true
                return false
            }
        })
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result { add(urls) }
        }
        .alert("Could not send", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("Key passphrase", isPresented: $model.needsPassphrase) {
            SecureField("Passphrase", text: $passphrase)
            Button("Sign and Send") {
                model.submitPassphrase(passphrase)
                passphrase = ""
                sendNow()
            }
            Button("Cancel", role: .cancel) { passphrase = "" }
        }
        .confirmationDialog("Send without encryption?", isPresented: $model.confirmPlaintextReply, titleVisibility: .visible) {
            Button("Send Unencrypted", role: .destructive) {
                model.approvePlaintextReply()
                sendNow()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This reply quotes a message that was encrypted. Sending it unencrypted exposes that text.")
        }
        .confirmationDialog("Do you want to save this message as a draft?", isPresented: $confirmClose, titleVisibility: .visible) {
            if model.canSaveDraft {
                Button("Save Draft") { Task { await saveDraftAndClose() } }
            }
            Button("Delete Draft", role: .destructive) { close() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.canSaveDraft ? "Drafts are kept in Gmail." : "Encrypted messages can't be saved as drafts, because Gmail would store them readable.")
        }
    }

    private func close() {
        sent = true
        nsWindow?.close()
    }

    private func sendNow() {
        Task {
            if await model.send() { close() }
        }
    }

    private func saveDraftAndClose() async {
        if await model.saveDraft() { close() }
    }

    private func attachFile() {
        #if DEBUG
        // Mock runs attach a fixture instead of opening the system file panel.
        if MockGmail.isActive {
            model.attachments.append(MockGmail.sampleAttachment)
            return
        }
        #endif
        showImporter = true
    }

    /// Files from Finder arrive as file URLs; attachments dragged from a message (here or in another mail app)
    /// arrive as files the sender writes on drop.
    private func receiveDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in add([url]) }
                }
                continue
            }
            guard let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .data) ?? false })
                    ?? provider.registeredTypeIdentifiers.first else { continue }
            let name = provider.suggestedName
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                // The file is only valid inside this callback, so it is read here.
                guard let url, let data = try? Data(contentsOf: url) else { return }
                let filename = name.map { ($0 as NSString).pathExtension.isEmpty ? $0 + "." + url.pathExtension : $0 } ?? url.lastPathComponent
                Task { @MainActor in addData(data, filename: filename) }
            }
        }
    }

    private func addData(_ data: Data, filename: String) {
        let type = UTType(filenameExtension: (filename as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        model.attachments.append(OutgoingAttachment(filename: filename, mimeType: type, data: data))
        #if DEBUG
        if MockGmail.isActive { MockGmailServer.shared.record("ATTACH file=\(filename) bytes=\(data.count)") }
        #endif
    }

    private func add(_ urls: [URL]) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
                model.errorMessage = "\(url.lastPathComponent) is a folder. Compress it first, then attach the archive."
                continue
            }
            guard let data = try? Data(contentsOf: url) else {
                model.errorMessage = "Could not read \(url.lastPathComponent)."
                continue
            }
            addData(data, filename: url.lastPathComponent)
        }
    }
}
