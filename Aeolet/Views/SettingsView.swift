import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var pgp: PGPStore
    @Environment(\.dismiss) private var dismiss
    @State private var accountToRemove: String?

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
                    Toggle("Enable PGP", isOn: Binding(get: { pgp.isEnabled }, set: { pgp.setEnabled($0) }))
                    if pgp.isEnabled {
                        NavigationLink("Keys") { PGPKeysView() }
                    }
                } header: {
                    Text("End-to-end encryption")
                } footer: {
                    Text("Optional. Uses standard OpenPGP, so it works with GnuPG, Thunderbird and Proton Mail users.")
                }
                Section("Accounts") {
                    ForEach(app.accounts, id: \.self) { account in
                        Button(account, role: .destructive) { accountToRemove = account }
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
            .confirmationDialog("Sign out and revoke access?", isPresented: Binding(
                get: { accountToRemove != nil },
                set: { if !$0 { accountToRemove = nil } }
            ), titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    if let account = accountToRemove { Task { await app.signOut(account) } }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Revokes this app's access at Google and deletes the account's tokens and PGP private key from this iPhone. Back up your PGP key first.")
            }
        }
    }
}

struct LicensesView: View {
    var body: some View {
        ScrollView {
            Text("""
            Aeolet is licensed under the Apache License 2.0.

            OpenPGP.js is licensed under the GNU Lesser General Public License v3.0 or later. Source: github.com/openpgpjs/openpgpjs. You may replace the bundled library by rebuilding from PGP/js in this project's source code.
            """)
            .font(.footnote)
            .padding()
        }
        .navigationTitle("Licences")
    }
}
