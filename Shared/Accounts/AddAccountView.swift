import SwiftMail
import SwiftUI

/// "Add account": Google through its own sign-in page, Gmail or Yahoo with an app password, or any mail
/// account over IMAP and SMTP.
struct AddAccountView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var path: [AccountKind] = []

    enum AccountKind: Hashable {
        case preset(MailAccount.Provider)
        case manual
    }

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section {
                    Button {
                        Task {
                            let before = app.accounts.count
                            await app.signIn()
                            if app.accounts.count > before { dismiss() }
                        }
                    } label: {
                        AccountTypeRow(title: "Google (Recommended)", detail: "For Gmail and Google Workspace. You sign in on Google's own page.",
                                       symbol: "g.circle")
                    }
                    .disabled(app.isSigningIn)
                    .accessibilityIdentifier("addAccount.google")

                    Button { path = [.preset(.gmail)] } label: {
                        AccountTypeRow(title: "Gmail with an app password", detail: "Gmail over IMAP and SMTP. Needs 2-Step Verification and an app password.",
                                       symbol: "key")
                    }
                    .accessibilityIdentifier("addAccount.gmail")

                    Button { path = [.preset(.yahoo)] } label: {
                        AccountTypeRow(title: "Yahoo Mail", detail: "Yahoo over IMAP and SMTP with an app password.",
                                       symbol: "y.circle")
                    }
                    .accessibilityIdentifier("addAccount.yahoo")

                    Button { path = [.manual] } label: {
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
            .navigationDestination(for: AccountKind.self) { kind in
                switch kind {
                case let .preset(provider): PresetAccountView(provider: provider) { dismiss() }
                case .manual: ManualAccountView { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(width: 480, height: 600)
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
                    VStack(alignment: .leading, spacing: 6) {
                        if let provider = account?.provider, provider != .manual { AppPasswordNote(provider: provider) }
                        Text("Used for both servers. Stored only in this device's Keychain and sent only to these servers, always over an encrypted connection with a verified certificate.")
                    }
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
        case let .known(provider): discoveryNote = "These are \(provider.name)'s settings."
        }
    }

    private func add() async {
        guard var account, !isWorking else { return }
        if let preset = MailAccount.preset(account.provider, email: account.email),
           preset.imap != account.imap || preset.smtp != account.smtp {
            account.provider = .manual
        }
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

/// The app-password explanation with a link to where the password is created.
private struct AppPasswordNote: View {
    let provider: MailAccount.Provider

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let note = provider.appPasswordNote { Text(note) }
            if let url = provider.appPasswordURL {
                Link(provider == .gmail ? "Create a Google app password" : "How to create a Yahoo app password", destination: url)
                    .accessibilityIdentifier("preset.appPasswordLink")
            }
        }
    }
}

/// Gmail or Yahoo with an app password: the servers are fixed, so only the address, name and app password
/// are asked for. Both servers must accept the password before the account is added.
struct PresetAccountView: View {
    @EnvironmentObject private var app: AppModel
    let provider: MailAccount.Provider
    let onAdded: () -> Void

    @State private var email = ""
    @State private var displayName = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var account: MailAccount? {
        let address = email.trimmed
        guard MailAccount.isPlausibleEmail(address), var account = MailAccount.preset(provider, email: address) else { return nil }
        account.displayName = displayName
        return account
    }

    var body: some View {
        Form {
            Section {
                TextField("Email address", text: $email, prompt: Text(provider == .gmail ? "name@gmail.com" : "name@yahoo.com"))
                    .textContentType(.emailAddress)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    #endif
                    .accessibilityIdentifier("preset.email")
                TextField("Name", text: $displayName, prompt: Text("Shown to people you write to (optional)"))
                    .textContentType(.name)
            }
            Section {
                SecureField("App password", text: $password)
                    .textContentType(.password)
                    .accessibilityIdentifier("preset.password")
            } header: {
                Text("App password")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    AppPasswordNote(provider: provider)
                    Text("Stored only in this device's Keychain and sent only to \(provider.name), always over an encrypted connection with a verified certificate.")
                }
            }
            if let preset = MailAccount.preset(provider, email: "") {
                Section("Servers") {
                    LabeledContent("Incoming (IMAP)", value: "\(preset.imap.host):\(preset.imap.port), \(preset.imap.security.label)")
                    LabeledContent("Outgoing (SMTP)", value: "\(preset.smtp.host):\(preset.smtp.port), \(preset.smtp.security.label)")
                }
                .font(.footnote)
                .accessibilityIdentifier("preset.servers")
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
                .disabled(isWorking || password.isEmpty || account == nil)
                .accessibilityIdentifier("preset.add")
            } footer: {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).accessibilityIdentifier("preset.error")
                }
            }
        }
        .formStyle(.grouped)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(provider.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
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

/// Plain words for what went wrong while adding an account. Never includes the password.
enum AccountSetupMessage {
    static func describe(_ error: Error, account: MailAccount) -> String {
        switch error {
        case IMAPError.loginFailed, IMAPError.authFailed, SMTPError.authenticationFailed:
            switch account.provider {
            case .gmail:
                return "Gmail didn't accept the address or app password. Use an app password, not your Google password, and check that 2-Step Verification is on."
            case .yahoo:
                return "Yahoo didn't accept the address or app password. Use an app password, not your Yahoo password."
            case .manual:
                return error is SMTPError
                    ? "\(account.smtp.host) didn't accept the user name or password for sending."
                    : "\(account.imap.host) didn't accept the user name or password."
            }
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
