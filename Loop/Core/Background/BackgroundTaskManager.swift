import BackgroundTasks
import UIKit

// Requests are fully configured before being handed to the submission queue and never mutated again.
private struct BackgroundRequestHandoff: @unchecked Sendable {
    let request: BGTaskRequest
}

@MainActor
final class BackgroundTaskManager {
    static let shared = BackgroundTaskManager()

    private static let refreshTaskID = "com.loop.background.refresh"
    private static let processingTaskID = "com.loop.background.processing"

    private var bleManager: BLEConnectionManager?
    private var repository: LoopDataRepository?
    private var registered = false

    private init() {}

    func configure(bleManager: BLEConnectionManager, repository: LoopDataRepository) {
        self.bleManager = bleManager
        self.repository = repository
        guard !registered else { return }
        registered = true
        registerTasks()
    }

    private func registerTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.refreshTaskID,
            using: nil
        ) { [weak self] task in
            guard let self, let refreshTask = task as? BGAppRefreshTask else { return }
            Task { @MainActor in
                await self.handleAppRefresh(task: refreshTask)
            }
        }

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.processingTaskID,
            using: nil
        ) { [weak self] task in
            guard let self, let processingTask = task as? BGProcessingTask else { return }
            Task { @MainActor in
                await self.handleBackgroundProcessing(task: processingTask)
            }
        }
    }

    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        // On battery the daytime refresh is deliberately sparse (battery); on a charger keep 15 min.
        let state = UIDevice.current.batteryState
        let charging = state == .charging || state == .full
        request.earliestBeginDate = Date(timeIntervalSinceNow: charging ? 15 * 60 : 60 * 60)

        submit(request, description: "background refresh")
    }

    func scheduleBackgroundProcessing() {
        let request = BGProcessingTaskRequest(identifier: Self.processingTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        request.requiresNetworkConnectivity = false
        // Only runs while on a charger (iOS typically picks the night): that is when we do the deep
        // catch-up of the whole backlog, so the daytime syncs can stay light.
        request.requiresExternalPower = true

        submit(request, description: "background processing")
    }

    private func submit(_ request: BGTaskRequest, description: String) {
        // The asynchronous API must not be called on the main thread.
        let handoff = BackgroundRequestHandoff(request: request)
        DispatchQueue.global(qos: .utility).async {
            BGTaskScheduler.shared.submitTaskRequest(handoff.request) { error in
                if let error {
                    print("Failed to schedule \(description): \(error)")
                }
            }
        }
    }

    private func handleAppRefresh(task: BGAppRefreshTask) async {
        scheduleBackgroundRefresh()

        let work = Task { [weak self] in
            guard let bleManager = self?.bleManager else {
                task.setTaskCompleted(success: false)
                return
            }
            let success = await bleManager.performBackgroundSync()
            task.setTaskCompleted(success: success && !Task.isCancelled)
        }
        task.expirationHandler = { work.cancel() }
    }

    private func handleBackgroundProcessing(task: BGProcessingTask) async {
        scheduleBackgroundProcessing()

        let work = Task { [weak self] in
            guard let repository = self?.repository, let bleManager = self?.bleManager else {
                task.setTaskCompleted(success: false)
                return
            }
            _ = await bleManager.performChargingSync()
            guard repository.localMetricsEngine != nil, !Task.isCancelled else {
                task.setTaskCompleted(success: false)
                return
            }
            await repository.requestBackgroundRefresh()
            task.setTaskCompleted(success: !Task.isCancelled)
        }
        task.expirationHandler = { work.cancel() }
    }
}
