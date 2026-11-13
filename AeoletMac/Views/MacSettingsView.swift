import SwiftUI

/// Aeolet > Settings (⌘,).
struct MacSettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AccountsSettings()
                .tabItem { Label("Accounts", systemImage: "at") }
            EncryptionSettings()
                .tabItem { Label("Encryption", systemImage: "lock") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 600)
        .frame(minHeight: 420)
        .lockable()
        .accessibilityIdentifier("settings")
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var watcher = MailWatcher.shared
    @State private var openAtLogin = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Picker("Check for new mail", selection: $watcher.minutes) {
                    ForEach(MailWatcher.intervals, id: \.self) { minutes in
                        Text(minutes == 1 ? "Every minute" : "Every \(minutes) minutes").tag(minutes)
                    }
                }
                Toggle("Open at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, value in
                        do {
                            try LoginItem.set(value)
                        } catch {
                            loginError = error.localizedDescription
                            openAtLogin = LoginItem.isEnabled
                        }
                    }
            } header: {
                Text("New mail")
            } footer: {
                Text("While Aeolet is open it asks Gmail for new mail, then shows a notification and the unread count on its Dock icon. There is no Aeolet server and no push, so nothing arrives while Aeolet is closed.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Require Touch ID or password", isOn: $app.requireDeviceAuth)
            } header: {
                Text("Privacy")
            } footer: {
                Text("Locks Aeolet when you hide it, when the Mac sleeps and when the screen locks. Remote images are always blocked until you ask for them.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .alert("Open at login", isPresented: Binding(get: { loginError != nil }, set: { if !$0 { loginError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(loginError ?? "")
        }
    }
}

private struct AccountsSettings: View {
    @EnvironmentObject private var app: AppModel
    @State private var accountToRemove: String?

    var body: some View {
        Form {
            Section {
                if app.accounts.isEmpty {
                    Text("No accounts yet").foregroundStyle(.secondary)
                }
                ForEach(app.accounts, id: \.self) { account in
                    HStack {
                        Label(account, systemImage: "envelope")
                        Spacer()
                        Button("Sign Out…") { accountToRemove = account }
                    }
                }
            } header: {
                Text("Gmail accounts")
            } footer: {
                Text("Signing out revokes Aeolet's access at Google and deletes the account's token, cached mail list and PGP private key from this Mac.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Button {
                    Task { await app.signIn() }
                } label: {
                    Label("Add Gmail Account", systemImage: "plus")
                }
                .disabled(app.isSigningIn)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Sign out and revoke access?", isPresented: Binding(
            get: { accountToRemove != nil },
            set: { if !$0 { accountToRemove = nil } }
        ), titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                if let account = accountToRemove {
                    Task {
                        await app.signOut(account)
                        await MailWatcher.shared.updateBadge()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Revokes this app's access at Google and deletes the account's tokens and PGP private key from this Mac. Back up your PGP key first.")
        }
    }
}

private struct EncryptionSettings: View {
    @EnvironmentObject private var pgp: PGPStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    Toggle("Enable PGP", isOn: Binding(get: { pgp.isEnabled }, set: { pgp.setEnabled($0) }))
                } footer: {
                    Text("Optional. Uses standard OpenPGP, so it works with GnuPG, Thunderbird and Proton Mail users.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(height: 110)
            if pgp.isEnabled {
                MacPGPKeysView()
            } else {
                Spacer()
            }
        }
    }
}

private struct AboutSettings: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                LabeledContent("Published by", value: AppConfig.publisherName)
                if let url = AppConfig.publisherURL { Link("Website", destination: url) }
                if let url = AppConfig.sourceCodeURL { Link("Source code", destination: url) }
            }
            Section("Open-source licences") {
                Text("""
                Aeolet is licensed under the Apache License 2.0.

                OpenPGP.js is licensed under the GNU Lesser General Public License v3.0 or later. Source: github.com/openpgpjs/openpgpjs. You may replace the bundled library by rebuilding from PGP/js in this project's source code.
                """)
                .font(.callout)
                .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }
}
