import SwiftUI
import UniformTypeIdentifiers

struct ComposeView: View {
    @StateObject private var model: ComposeModel
    @Environment(\.dismiss) private var dismiss
    @State private var showCc = false
    @State private var showImporter = false
    @State private var passphrase = ""

    init(account: String, context: ComposeContext) {
        _model = StateObject(wrappedValue: ComposeModel(account: account, context: context))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("To", text: $model.to).addressField()
                    if showCc || !model.cc.isEmpty || !model.bcc.isEmpty {
                        TextField("Cc", text: $model.cc).addressField()
                        TextField("Bcc", text: $model.bcc).addressField()
                    } else {
                        Button("Add Cc or Bcc") { showCc = true }.font(.footnote)
                    }
                    TextField("Subject", text: $model.subject)
                }
                if model.canUsePGP { encryptionSection }
                Section {
                    TextEditor(text: $model.body).frame(minHeight: 260)
                }
                Section {
                    ForEach(model.attachments) { item in
                        Label(item.filename, systemImage: "paperclip")
                    }
                    .onDelete { model.attachments.remove(atOffsets: $0) }
                    Button("Attach file", systemImage: "paperclip") { showImporter = true }
                }
            }
            .navigationTitle("New message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Menu("Close") {
                        Button("Discard", role: .destructive) { dismiss() }
                        if model.canSaveDraft {
                            Button("Save draft") {
                                Task { if await model.saveDraft() { dismiss() } }
                            }
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isWorking {
                        ProgressView()
                    } else {
                        Button("Send", systemImage: "paperplane.fill") { sendNow() }
                    }
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                importFiles(result)
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
                Button("Sign and send") {
                    model.submitPassphrase(passphrase)
                    passphrase = ""
                    sendNow()
                }
                Button("Cancel", role: .cancel) { passphrase = "" }
            }
            .confirmationDialog("Send without encryption?", isPresented: $model.confirmPlaintextReply, titleVisibility: .visible) {
                Button("Send unencrypted", role: .destructive) {
                    model.approvePlaintextReply()
                    sendNow()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This reply quotes a message that was encrypted. Sending it unencrypted exposes that text.")
            }
        }
    }

    private var encryptionSection: some View {
        Section {
            Toggle("Encrypt", isOn: $model.encrypt)
            Toggle("Sign", isOn: $model.sign)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if model.encrypt {
                    Text("The body and attachments are encrypted. The subject, sender and recipients stay visible to mail servers. Encrypted messages cannot be saved as drafts.")
                }
                if !model.missingKeys.isEmpty {
                    Text("No key for: \(model.missingKeys.joined(separator: ", "))").foregroundStyle(.red)
                }
            }
        }
    }

    private func sendNow() {
        Task { if await model.send() { dismiss() } }
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result else { return }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                model.errorMessage = "Could not read \(url.lastPathComponent)."
                continue
            }
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            model.attachments.append(OutgoingAttachment(filename: url.lastPathComponent, mimeType: type, data: data))
        }
    }
}

private extension View {
    func addressField() -> some View {
        textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.emailAddress)
    }
}
