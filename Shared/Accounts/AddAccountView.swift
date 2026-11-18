import SwiftMail
import SwiftUI

/// "Add account": Google through its own sign-in page, or any mail account over IMAP and SMTP.
struct AddAccountView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showManual = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        Task {
                            let before = app.accounts.count
                            await app.signIn()
                            if app.accounts.count > before { dismiss() }
                        }
                    } label: {
                        AccountTypeRow(title: "Google", detail: "Recommended for Gmail and Google Workspace. You sign in on Google's own page.",
                                       symbol: "g.circle")
                    }
                    .disabled(app.isSigningIn)
                    .accessibilityIdentifier("addAccount.google")

                    Button { showManual = true } label: {
                        AccountTypeRow(title: "Other mail account", detail: "Any provider with IMAP and SMTP. Settings are found from your address where possible.",
                                       symbol: "envelope")
                    }
                    .accessibilityIdentifier("addAccount.manual")
                } footer: {
                    Text("With Google, Aeolet never sees your password. For other accounts, your password is stored only in this device's Keychain and sent only to your mail server.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add Account")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .navigationDestination(isPresented: $showManual) {
                ManualAccountView { dismiss() }
            }
        }
        #if os(macOS)
        .frame(width: 480, height: 560)
        #endif
    }
}

private struct AccountTypeRow: View {
    let title: String
    let detail: String
    let symbol: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(Theme.aegean).frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// IMAP and SMTP settings. The address is used to look the settings up; the person checks them, types the
/// password, and the account is added only once both servers have accepted it.
struct ManualAccountView: View {
    @EnvironmentObject private var app: AppModel
    let onAdded: () -> Void

    @State private var email = ""
    @State private var account: MailAccount?
    @State private var discoveryNote = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @FocusState private var emailFocused: Bool

    var body: some View {
        Form {
            Section {
                TextField("Email address", text: $email, prompt: Text("name@example.com"))
                    .focused($emailFocused)
                    .textContentType(.emailAddress)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onSubmit { Task { await discover() } }
                    .onChange(of: email) { _, _ in
                        if account?.email != email.trimmed { account = nil; discoveryNote = "" }
                    }
                    .accessibilityIdentifier("manual.email")
                if account == nil {
                    Button {
                        Task { await discover() }
                    } label: {
                        HStack {
                            Text("Find Settings")
                            if isWorking { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(!MailAccount.isPlausibleEmail(email.trimmed) || isWorking)
                    .accessibilityIdentifier("manual.discover")
                }
            } footer: {
                if !discoveryNote.isEmpty { Text(discoveryNote).accessibilityIdentifier("manual.discoveryNote") }
            }

            if let binding = Binding($account) {
                Section("Your name") {
                    TextField("Name", text: binding.displayName, prompt: Text("Shown to people you write to (optional)"))
                        .textContentType(.name)
                }
                ServerSection(title: "Incoming mail (IMAP)", endpoint: binding.imap, identifier: "imap")
                ServerSection(title: "Outgoing mail (SMTP)", endpoint: binding.smtp, identifier: "smtp")
                Section {
                    TextField("User name", text: binding.username)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .accessibilityIdentifier("manual.username")
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .accessibilityIdentifier("manual.password")
                } header: {
                    Text("Sign-in")
                } footer: {
                    Text("Used for both servers. Stored only in this device's Keychain and sent only to these servers, always over an encrypted connection with a verified certificate.")
                }
                Section {
                    Button {
                        Task { await add() }
                    } label: {
                        HStack {
                            Text("Add Account")
                            if isWorking { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(isWorking || password.isEmpty || !(account?.isValid ?? false))
                    .accessibilityIdentifier("manual.add")
                } footer: {
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red).accessibilityIdentifier("manual.error")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Other Mail Account")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func discover() async {
        let address = email.trimmed
        guard MailAccount.isPlausibleEmail(address), !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        let result = await Autodiscovery.discover(email: address)
        guard address == email.trimmed else { return }
        account = result.account
        emailFocused = false
        switch result.source {
        case let .autoconfig(host): discoveryNote = "Settings published by \(host). Check them before you continue."
        case .dns: discoveryNote = "Settings found in your domain's DNS. Check them before you continue."
        case .guess: discoveryNote = "No published settings found, so these use your domain. Check them with your mail provider."
        }
    }

    private func add() async {
        guard let account, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        do {
            try await app.addMailAccount(account, password: password)
            password = ""
            onAdded()
        } catch {
            errorMessage = AccountSetupMessage.describe(error, account: account)
        }
    }
}

private struct ServerSection: View {
    let title: String
    @Binding var endpoint: ServerEndpoint
    let identifier: String

    var body: some View {
        Section(title) {
            TextField("Server", text: $endpoint.host, prompt: Text("mail.example.com"))
                .autocorrectionDisabled()
                #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                #endif
                .accessibilityIdentifier("\(identifier).host")
            TextField("Port", value: $endpoint.port, format: .number.grouping(.never))
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .accessibilityIdentifier("\(identifier).port")
            Picker("Security", selection: $endpoint.security) {
                ForEach(ConnectionSecurity.allCases) { Text($0.label).tag($0) }
            }
            .accessibilityIdentifier("\(identifier).security")
        }
    }
}

/// Plain words for what went wrong while adding an account. Never includes the password.
enum AccountSetupMessage {
    static func describe(_ error: Error, account: MailAccount) -> String {
        switch error {
        case IMAPError.loginFailed, IMAPError.authFailed:
            return "\(account.imap.host) didn't accept the user name or password."
        case SMTPError.authenticationFailed:
            return "\(account.smtp.host) didn't accept the user name or password for sending."
        case let error as AccountError:
            return error.localizedDescription
        default:
            break
        }
        let text = String(describing: error).lowercased()
        let isSMTP = error is SMTPError
        let endpoint = isSMTP ? account.smtp : account.imap
        if text.contains("starttls") {
            return "\(endpoint.host) doesn't offer STARTTLS on port \(endpoint.port). Try SSL/TLS."
        }
        if text.contains("certificate") || text.contains("handshake") || text.contains("ssl") || text.contains("tls") {
            return "A secure connection to \(endpoint.host):\(endpoint.port) couldn't be made. Check the server name, port and security. Aeolet only connects to servers with a valid certificate for that name."
        }
        if text.contains("connection") || text.contains("refused") || text.contains("timeout") || text.contains("timed out") || text.contains("resolve") {
            return "Can't reach \(endpoint.host) on port \(endpoint.port). Check the server name and port."
        }
        return error.userMessage
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// The IMAP form on its own, for the first-run screen where Google already has its own button.
struct ManualAccountSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ManualAccountView { dismiss() }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
        }
        #if os(macOS)
        .frame(width: 480, height: 620)
        #endif
    }
}
