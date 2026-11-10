import SwiftUI

struct RootView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.scenePhase) private var scenePhase

    private var isCovered: Bool { app.isLocked || (app.requireDeviceAuth && scenePhase != .active) }

    var body: some View {
        ZStack {
            content
            #if DEBUG
            if MockGmail.isActive { MockGmailProbe() }
            #endif
        }
        // The lock screen gets its own window above everything, so it also covers open sheets
        // (a draft in Compose, Settings, PGP keys), and the windows behind it are hidden from VoiceOver.
        .onChange(of: isCovered, initial: true) { _, covered in
            LockOverlay.shared.update(covered: covered, app: app)
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
        .tint(Theme.aegean)
    }
}

/// Shows LockView in a window above every other window of the scene, including presented sheets.
@MainActor
final class LockOverlay {
    static let shared = LockOverlay()
    private var window: UIWindow?

    func update(covered: Bool, app: AppModel) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        if covered, window == nil {
            let overlay = UIWindow(windowScene: scene)
            overlay.windowLevel = .alert + 1
            let host = UIHostingController(rootView: LockView().environmentObject(app))
            host.view.accessibilityViewIsModal = true
            overlay.rootViewController = host
            overlay.isHidden = false
            window = overlay
        } else if !covered, let overlay = window {
            overlay.isHidden = true
            window = nil
        }
        for other in scene.windows where other !== window {
            other.accessibilityElementsHidden = covered
        }
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

                Text("Your password goes only to Google. Aeolet receives a revocable token, stored in this device's Keychain.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
    }
}
