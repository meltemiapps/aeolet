import SwiftUI

@main
struct AeoletApp: App {
    @StateObject private var app = AppModel()
    @StateObject private var pgp = PGPStore.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .environmentObject(pgp)
                .tint(Theme.aegean)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                app.didEnterBackground()
                pgp.forgetPassphrases()
                BackgroundSync.schedule()
            case .active:
                app.didBecomeActive()
            default:
                break
            }
        }
        .backgroundTask(.appRefresh(AppConfig.backgroundTaskID)) {
            await BackgroundSync.run()
        }
    }
}
