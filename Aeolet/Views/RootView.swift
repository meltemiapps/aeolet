import SwiftUI

struct RootView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            content
            if app.isLocked || (app.requireDeviceAuth && scenePhase != .active) {
                LockView()
            }
        }
        .alert("Aeolet", isPresented: Binding(
            get: { app.errorMessage != nil },
            set: { if !$0 { app.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        if !AppConfig.isConfigured {
            SetupRequiredView()
        } else if !app.isLoaded {
            ProgressView()
        } else if let account = app.currentAccount {
            MailboxView(account: account).id(account)
        } else {
            SignInView()
        }
    }
}

struct LockView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(Theme.aegean)
            Text("Aeolet is locked").font(.headline)
            Button("Unlock") { app.unlock() }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

struct SetupRequiredView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Google client ID needed", systemImage: "key")
        } description: {
            Text("Add your own Google OAuth client ID to Config.xcconfig and rebuild. The README has the steps.")
        }
    }
}

struct SignInView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "envelope.badge.shield.half.filled")
                .font(.system(size: 64))
                .foregroundStyle(Theme.aegean)
            VStack(spacing: 8) {
                Text("Aeolet").font(.largeTitle.bold())
                Text("Open-source Gmail, private by design.").foregroundStyle(.secondary)
            }
            Spacer()
            VStack(spacing: 12) {
                Button {
                    Task { await app.signIn() }
                } label: {
                    Group {
                        if app.isSigningIn { ProgressView() } else { Text("Sign in with Google") }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(app.isSigningIn)

                Text("Your password goes only to Google. Aeolet receives a revocable token, stored in your iPhone's Keychain.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
    }
}
