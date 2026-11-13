import SwiftUI

/// Covers a window (and its sheets) while Aeolet is locked. The content stays alive underneath, so an open
/// draft survives, but it is hidden from view and from VoiceOver until Touch ID or the password unlocks it.
struct LockCover: ViewModifier {
    @EnvironmentObject private var app: AppModel

    func body(content: Content) -> some View {
        ZStack {
            content
                .opacity(app.isLocked ? 0 : 1)
                .accessibilityHidden(app.isLocked)
                .allowsHitTesting(!app.isLocked)
            if app.isLocked {
                VStack(spacing: 16) {
                    Image(systemName: "lock.fill").font(.system(size: 40)).foregroundStyle(Theme.aegean)
                    Text("Aeolet is locked").font(.headline)
                    Button("Unlock") { app.unlock() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
            }
        }
    }
}

extension View {
    func lockable() -> some View { modifier(LockCover()) }
}
