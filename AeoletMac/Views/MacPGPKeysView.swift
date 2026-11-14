import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings > Encryption: your keys per account and your contacts' public keys.
struct MacPGPKeysView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var pgp: PGPStore
    @State private var generateFor: GenerateTarget?
    @State private var importMode: PGPImportMode?
    @State private var lookupEmail = ""
    @State private var isBusy = false
    @State private var message: String?
    @State private var keyToDelete: String?
    @State private var keyToExport: String?

    struct GenerateTarget: Identifiable { let id: String }

    var body: some View {
        Form {
            ForEach(app.accounts, id: \.self) { account in
                Section(account) {
                    if let key = pgp.ownKey(for: account) {
                        MacFingerprintText(fingerprint: key.fingerprint)
                        HStack {
                            ShareLink("Share Public Key", item: key.publicKey)
                            Button("Export Private Key…") { keyToExport = account }
                            Spacer()
                            Button("Remove Private Key…", role: .destructive) { keyToDelete = account }
                        }
                    } else {
                        HStack {
                            Button("Generate a New Key…") { generateFor = GenerateTarget(id: account) }
                            Button("Import Existing Private Key…") { importMode = .privateKey(account) }
                        }
                    }
                }
            }

            Section {
                HStack {
                    TextField("Find a key by email", text: $lookupEmail, prompt: Text("name@example.org"))
                    Button("Find") { Task { await lookup() } }
                        .disabled(lookupEmail.isEmpty || isBusy)
                }
                Button("Paste a Public Key…") { importMode = .contact }
            } header: {
                Text("Add a contact's key")
            } footer: {
                Text("Find asks keys.openpgp.org, which sees the address you search. Confirm a fingerprint with the person before relying on a key.")
                    .foregroundStyle(.secondary)
            }

            Section("Contact keys") {
                if pgp.contacts.isEmpty {
                    Text("None yet").foregroundStyle(.secondary)
                }
                ForEach(pgp.contacts) { contact in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(contact.email).font(.headline)
                            Spacer()
                            Button("Remove", role: .destructive) { pgp.removeContact(contact) }
                                .buttonStyle(.borderless)
                        }
                        MacFingerprintText(fingerprint: contact.fingerprint)
                        Toggle("Fingerprint confirmed with this person", isOn: Binding(
                            get: { contact.isVerified },
                            set: { pgp.setVerified(contact, $0) }
                        ))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $generateFor) { target in
            MacGenerateKeyView(account: target.id).lockable()
        }
        .sheet(item: $importMode) { mode in
            MacPasteKeyView(mode: mode).lockable()
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
            Button("Remove Key", role: .destructive) {
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
            Button("Export…") { Task { await export(account) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This file is your private key. It stays locked with your passphrase, but anyone who has the file and your passphrase can read your encrypted mail and sign as you. Keep it in a private backup and never email or post it.")
        }
    }

    /// Saves the key, still locked with its passphrase, to a place the person chooses.
    private func export(_ account: String) async {
        do {
            let temporary = try await pgp.exportPrivateKey(account: account)
            defer { try? FileManager.default.removeItem(at: temporary.deletingLastPathComponent()) }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = temporary.lastPathComponent
            panel.allowedContentTypes = [UTType(filenameExtension: "asc") ?? .data]
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try Data(contentsOf: temporary).write(to: url, options: .atomic)
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

enum PGPImportMode: Identifiable {
    case privateKey(String), contact
    var id: String {
        switch self {
        case let .privateKey(account): return "private-\(account)"
        case .contact: return "contact"
        }
    }
}

struct MacFingerprintText: View {
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
        Text(grouped).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
    }
}

struct MacGenerateKeyView: View {
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
        VStack(alignment: .leading, spacing: 16) {
            Text("New PGP Key").font(.title2.bold())
            Form {
                LabeledContent("Email", value: account)
                TextField("Your name", text: $name)
                    .accessibilityIdentifier("pgp-name")
                SecureField("Passphrase", text: $passphrase, prompt: Text("12 characters or more"))
                    .textContentType(.oneTimeCode)
                    .accessibilityIdentifier("pgp-passphrase")
                SecureField("Repeat passphrase", text: $confirmation)
                    .textContentType(.oneTimeCode)
                    .accessibilityIdentifier("pgp-repeat")
            }
            Text("There is no reset. If you forget the passphrase, mail encrypted to this key is unreadable.")
                .font(.callout).foregroundStyle(.secondary)
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Create") { Task { await create() } }
                        .accessibilityIdentifier("pgp-create")
                        .keyboardShortcut(.defaultAction)
                        .disabled(!isValid)
                }
            }
        }
        .padding(24)
        .frame(width: 480)
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

struct MacPasteKeyView: View {
    let mode: PGPImportMode
    @EnvironmentObject private var pgp: PGPStore
    @Environment(\.dismiss) private var dismiss
    @State private var armored = ""
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var showImporter = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Key").font(.title2.bold())
            Text("Paste the whole block, from -----BEGIN to -----END, or open an .asc file.")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $armored)
                .font(.callout.monospaced())
                .frame(minHeight: 260)
                .border(Color(nsColor: .separatorColor))
                .accessibilityLabel("Key")
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
            HStack {
                Button("Open File…") { showImporter = true }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Import") { Task { await save() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(armored.isEmpty)
                }
            }
        }
        .padding(24)
        .frame(width: 560)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [UTType(filenameExtension: "asc") ?? .text, .text, .data]) { result in
            guard case let .success(url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let text = try? String(contentsOf: url, encoding: .utf8) { armored = text } else { errorMessage = "That file isn't a text key." }
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
