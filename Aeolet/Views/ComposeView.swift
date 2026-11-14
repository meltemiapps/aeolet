import SwiftUI

struct ComposeView: View {
    @StateObject private var model: ComposeModel
    @Environment(\.dismiss) private var dismiss
    @State private var showCc = false
    @State private var showAttachChoices = false
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false
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
                attachmentsSection
            }
            .scrollDismissesKeyboard(.immediately)
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
                // The body is multi-line, so Return can't put the keyboard away.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Hide keyboard", systemImage: "keyboard.chevron.compact.down") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
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
            .sheet(isPresented: $showPhotoPicker) {
                PhotoPicker { providers in Task { await model.addPhotos(providers) } }
                    .ignoresSafeArea()
            }
            .sheet(isPresented: $showFilePicker) {
                DocumentPicker { urls in addFiles(urls) }
                    .ignoresSafeArea()
            }
            .alert("Attachments", isPresented: Binding(
                get: { model.attachmentNotice != nil },
                set: { if !$0 { model.attachmentNotice = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.attachmentNotice ?? "")
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

    private var attachmentsSection: some View {
        Section {
            ForEach(model.attachments) { item in
                HStack {
                    Label(item.filename, systemImage: "paperclip").lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(AttachmentLimit.format(item.data.count)).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
            .onDelete { model.attachments.remove(atOffsets: $0) }
            if model.isAddingPhotos {
                HStack { ProgressView(); Text("Adding photos…").foregroundStyle(.secondary) }
            }
            // An action sheet rather than a Menu: a Menu inside a Form row doesn't open on current iOS.
            Button("Attach", systemImage: "paperclip") { showAttachChoices = true }
                .confirmationDialog("Attach", isPresented: $showAttachChoices) {
                    Button("Photo Library") { attachPhotos() }
                    Button("Files") { attachFiles() }
                    Button("Cancel", role: .cancel) {}
                }
        } footer: {
            if !model.attachments.isEmpty {
                Text("\(AttachmentLimit.format(model.attachmentsTotal)) of \(AttachmentLimit.format(AttachmentLimit.maxTotalBytes))")
                    .foregroundStyle(model.isOverAttachmentLimit ? .red : .secondary)
                    .accessibilityLabel("Attachments total \(AttachmentLimit.format(model.attachmentsTotal)) of \(AttachmentLimit.format(AttachmentLimit.maxTotalBytes))")
            }
        }
    }

    private func attachPhotos() {
        #if DEBUG
        // Mock runs pick fixture photos, through the same conversion, instead of opening the system picker.
        if MockGmail.usesPickerFixtures {
            Task { await model.addPhotos(MockGmail.pickedPhotos()) }
            return
        }
        #endif
        showPhotoPicker = true
    }

    private func attachFiles() {
        #if DEBUG
        if MockGmail.usesPickerFixtures {
            addFiles(MockGmail.pickedFiles())
            return
        }
        #endif
        showFilePicker = true
    }

    /// The picker hands over copies in Aeolet's temporary folder; they are deleted once read into the message.
    private func addFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        model.addFiles(urls)
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    private func sendNow() {
        Task { if await model.send() { dismiss() } }
    }
}

private extension View {
    func addressField() -> some View {
        textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.emailAddress)
    }
}
