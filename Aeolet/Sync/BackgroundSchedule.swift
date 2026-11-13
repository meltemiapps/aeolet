import BackgroundTasks
import Foundation

/// iOS background refresh. iOS decides when it runs; delivery is opportunistic, not instant.
extension BackgroundSync {
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: AppConfig.backgroundTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func run() async {
        schedule()
        await checkAll()
    }
}
