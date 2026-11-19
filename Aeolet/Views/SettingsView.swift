import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var pgp: PGPStore
    @Environment(\.dismiss) private var dismiss
    @State private var accountToRemove: String?
    @AppStorage(ComposeModel.keepPhotoOriginalsKey) private var keepPhotoOriginals = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Require Face ID or passcode", isOn: $app.requireDeviceAuth)
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Locks Aeolet whenever it leaves the foreground. Remote images are always blocked until you ask for them.")
                }
                Section {
                    Toggle("Keep photo originals", isOn: $keepPhotoOriginals)
                } header: {
                    Text("Attachments")
                } footer: {
                    Text(keepPhotoOriginals
                         ? "Photos are sent exactly as they are in your library, including HEIC format and where they were taken."
                         : "Photos are sent as JPEG, with the location they were taken removed.")
                }
                Section {
                    Toggle("Enable PGP", isOn: Binding(get: { pgp.isEnabled }, set: { pgp.setEnabled($0) }))
                    if pgp.isEnabled {
                        NavigationLink("Keys") { PGPKeysView() }
                    }
                } header: {
                    Text("End-to-end encryption")
                } footer: {
                    Text("Optional. Uses standard OpenPGP, so it works with GnuPG, Thunderbird and Proton Mail users.")
                }
                Section {
                    ForEach(app.accounts, id: \.self) { account in
                        Button(account, role: .destructive) { accountToRemove = account }
                    }
                } header: {
                    Text("Accounts")
                } footer: {
                    if let note = AppConfig.googleSignInUnavailableNote {
                        Text(note).accessibilityIdentifier("settings.googleUnavailable")
                    }
                }
                Section("About") {
                    LabeledContent("Published by", value: AppConfig.publisherName)
                    if let url = AppConfig.publisherURL { Link("Website", destination: url) }
                    if let url = AppConfig.sourceCodeURL { Link("Source code", destination: url) }
                    NavigationLink("Open-source licences") { LicensesView() }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog(signOutTitle, isPresented: Binding(
                get: { accountToRemove != nil },
                set: { if !$0 { accountToRemove = nil } }
            ), titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    if let account = accountToRemove { Task { await app.signOut(account) } }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(signOutMessage)
            }
        }
    }
}

extension SettingsView {
    private var removingGoogle: Bool { accountToRemove.map(app.isGoogleAccount) ?? true }

    var signOutTitle: String { removingGoogle ? "Sign out and revoke access?" : "Remove this account?" }

    var signOutMessage: String {
        removingGoogle
            ? "Revokes this app's access at Google and deletes the account's tokens and PGP private key from this iPhone. Back up your PGP key first."
            : "Deletes the account's password, settings, cached mail list and PGP private key from this iPhone. Your mail stays on the server. Back up your PGP key first."
    }
}

struct LicensesView: View {
    var body: some View {
        ScrollView {
            Text(OpenSourceNotices.text)
            .font(.footnote)
            .padding()
        }
        .navigationTitle("Licences")
    }
}
