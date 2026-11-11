import SwiftUI
import UniformTypeIdentifiers

struct PGPKeysView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var pgp: PGPStore
    @State private var generateFor: GenerateTarget?
    @State private var importMode: ImportMode?
    @State private var lookupEmail = ""
    @State private var isBusy = false
    @State private var message: String?
    @State private var keyToDelete: String?
    @State private var keyToExport: String?
    @State private var exportedFile: ExportedFile?

    struct ExportedFile: Identifiable {
        let url: URL
        var id: URL { url }
    }

    struct GenerateTarget: Identifiable {
        let id: String
    }

    enum ImportMode: Identifiable {
        case privateKey(String), contact
        var id: String {
            switch self {
            case let .privateKey(account): return "private-\(account)"
            case .contact: return "contact"
            }
        }
    }

    var body: some View {
        List {
            ForEach(app.accounts, id: \.self) { account in
                Section(account) {
                    if let key = pgp.ownKey(for: account) {
                        FingerprintText(fingerprint: key.fingerprint)
                        ShareLink("Share public key", item: key.publicKey)
                        Button("Export private key") { keyToExport = account }
                        Button("Remove private key", role: .destructive) { keyToDelete = account }
                    } else {
                        Button("Generate a new key") { generateFor = GenerateTarget(id: account) }
                        Button("Import existing private key") { importMode = .privateKey(account) }
                    }
                }
            }

            Section {
                HStack {
                    TextField("name@example.org", text: $lookupEmail)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                    Button("Find") { Task { await lookup() } }
                        .disabled(lookupEmail.isEmpty || isBusy)
                }
                Button("Paste a public key") { importMode = .contact }
            } header: {
                Text("Add a contact's key")
            } footer: {
                Text("Find asks keys.openpgp.org, which sees the address you search. Confirm a fingerprint with the person before relying on a key.")
            }

            Section("Contact keys") {
                if pgp.contacts.isEmpty {
                    Text("None yet").foregroundStyle(.secondary)
                }
                ForEach(pgp.contacts) { contact in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(contact.email).font(.subheadline.weight(.medium))
                        FingerprintText(fingerprint: contact.fingerprint)
                        Toggle("Fingerprint confirmed with this person", isOn: Binding(
                            get: { contact.isVerified },
                            set: { pgp.setVerified(contact, $0) }
                        ))
                        .font(.footnote)
                    }
                    .swipeActions {
                        Button("Remove", role: .destructive) { pgp.removeContact(contact) }
                    }
                }
            }
        }
        .navigationTitle("PGP keys")
        .sheet(item: $generateFor) { target in
            GenerateKeyView(account: target.id)
        }
        .sheet(item: $importMode) { mode in
            PasteKeyView(mode: mode)
        }
        .alert("PGP", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
        .confirmationDialog("Remove this private key?", isPresented: Binding(
            get: { keyToDelete != nil },
            set: { if !$0 { keyToDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Remove key", role: .destructive) {
                if let account = keyToDelete { pgp.deleteOwnKey(account: account) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Mail encrypted to this key cannot be read here without it. There is no recovery unless you hold a backup.")
        }
        .alert("Export your private key?", isPresented: Binding(
            get: { keyToExport != nil },
            set: { if !$0 { keyToExport = nil } }
        ), presenting: keyToExport) { account in
            Button("Export") { Task { await export(account) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This file is your private key. It stays locked with your passphrase, but anyone who has the file and your passphrase can read your encrypted mail and sign as you. Keep it in a private backup and never email or post it.")
        }
        .sheet(item: $exportedFile) { file in
            ShareSheet(items: [file.url]) {
                exportedFile = nil
            }
            .ignoresSafeArea()
        }
        .onChange(of: exportedFile?.id) { old, _ in
            // Remove the temporary copy once the share sheet is gone.
            if let old { try? FileManager.default.removeItem(at: old.deletingLastPathComponent()) }
        }
    }

    private func export(_ account: String) async {
        do {
            exportedFile = ExportedFile(url: try await pgp.exportPrivateKey(account: account))
        } catch {
            message = error.userMessage
        }
    }

    private func lookup() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let added = try await pgp.fetchFromKeyServer(email: lookupEmail)
            message = "Added a key for \(added.joined(separator: ", ")). Confirm the fingerprint before relying on it."
            lookupEmail = ""
        } catch {
            message = error.userMessage
        }
    }
}

/// The system share sheet, for files a ShareLink can't hand over until they exist.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in onFinish() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct FingerprintText: View {
    let fingerprint: String

    private var grouped: String {
        stride(from: 0, to: fingerprint.count, by: 4).map { offset in
            let start = fingerprint.index(fingerprint.startIndex, offsetBy: offset)
            let end = fingerprint.index(start, offsetBy: 4, limitedBy: fingerprint.endIndex) ?? fingerprint.endIndex
            return String(fingerprint[start..<end])
        }
        .joined(separator: " ")
    }

    var body: some View {
        Text(grouped).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
    }
}

struct GenerateKeyView: View {
    let account: String
    @EnvironmentObject private var pgp: PGPStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var isBusy = false
    @State private var errorMessage: String?

    private var isValid: Bool { !name.isEmpty && passphrase.count >= 12 && passphrase == confirmation }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Email", value: account)
                    TextField("Your name", text: $name)
                }
                // Kept out of password AutoFill: iOS would otherwise offer a generated "strong password"
                // that the person never sees or remembers, and a PGP passphrase has no reset.
                Section {
                    SecureField("Passphrase, 12 characters or more", text: $passphrase)
                        .textContentType(.oneTimeCode)
                    SecureField("Repeat passphrase", text: $confirmation)
                        .textContentType(.oneTimeCode)
                } footer: {
                    Text("There is no reset. If you forget it, mail encrypted to this key is unreadable.")
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle("New PGP key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if isBusy {
                        ProgressView()
                    } else {
                        Button("Create") { Task { await create() } }.disabled(!isValid)
                    }
                }
            }
        }
    }

    private func create() async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await pgp.generateKey(account: account, name: name, passphrase: passphrase)
            dismiss()
        } catch {
            errorMessage = error.userMessage
        }
    }
}

struct PasteKeyView: View {
    let mode: PGPKeysView.ImportMode
    @EnvironmentObject private var pgp: PGPStore
    @Environment(\.dismiss) private var dismiss
    @State private var armored = ""
    @State private var isBusy = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $armored)
                        .font(.caption.monospaced())
                        .frame(minHeight: 280)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Paste the whole block, from -----BEGIN to -----END.")
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle("Import key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if isBusy {
                        ProgressView()
                    } else {
                        Button("Import") { Task { await save() } }.disabled(armored.isEmpty)
                    }
                }
            }
        }
    }

    private func save() async {
        isBusy = true
        defer { isBusy = false }
        do {
            switch mode {
            case let .privateKey(account):
                try await pgp.importPrivateKey(account: account, armored: armored)
            case .contact:
                _ = try await pgp.addContact(armored: armored, verified: false)
            }
            dismiss()
        } catch {
            errorMessage = error.userMessage
        }
    }
}
