import SwiftUI
import UIKit

@main
struct LoopApp: App {
    @StateObject private var repository: LoopDataRepository
    @StateObject private var connection: DeviceConnectionViewModel
    @StateObject private var backup: BackupCoordinator
    @StateObject private var alarmController = SmartAlarmController()
    @StateObject private var router = AppRouter()
    @StateObject private var syncToast = SyncToastCoordinator()
    @ObservedObject private var prefs = UserPreferences.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let repo = LoopDataRepository()
        let conn = DeviceConnectionViewModel()
        _repository = StateObject(wrappedValue: repo)
        _connection = StateObject(wrappedValue: conn)
        conn.bleManager.onDataIngested = { [weak repo] in
            if UIApplication.shared.applicationState == .active {
                repo?.requestExpressRefresh()
                repo?.requestRefresh()
            } else {
                Task { await repo?.requestBackgroundRefresh() }
            }
        }
        conn.bleManager.onEngineChanged = { [weak repo] engine in
            repo?.attach(engine: engine)
            if engine != nil, UIApplication.shared.applicationState == .active {
                repo?.requestRefresh()
            }
        }
        BackgroundTaskManager.shared.configure(bleManager: conn.bleManager, repository: repo)
        // Observers Apple Santé recréés à chaque lancement (y compris réveil en arrière-plan par HealthKit).
        HealthBackgroundSync.shared.startIfEnabled()
        HealthContinuedSync.shared.register()
        // Backup fichier (.loopbackup) manuel : closures faiblement capturées, jamais une dépendance runtime.
        _backup = StateObject(wrappedValue: BackupCoordinator(
            deviceId: LocalDeviceID.current,
            store: { [weak ble = conn.bleManager] in ble?.currentStore },
            suspend: { [weak ble = conn.bleManager, weak repo] in
                // Stoppe tout recalcul en cours : il retient le LocalMetricsEngine, donc le store.
                await MainActor.run { repo?.cancelRefresh() }
                await ble?.suspendForRestore()
            },
            resume: { [weak ble = conn.bleManager] in await ble?.resumeAfterRestore() },
            reloadCache: { [weak repo] in await repo?.reloadCacheFromDisk() }
        ))
    }

    var body: some Scene {
        WindowGroup {
            if prefs.onboardingComplete {
                MainTabView(repository: repository)
                    .environmentObject(connection)
                    .environmentObject(connection.bleManager.syncCoordinator)
                    .environmentObject(backup)
                    .environmentObject(alarmController)
                    .environmentObject(router)
                    .environmentObject(syncToast)
                    .onOpenURL { router.handle($0) }
                    .task { syncToast.observe(connection.bleManager.syncCoordinator) }
                    .task {
                        alarmController.rearmIfNeeded(using: connection)
                    }
                    .onChange(of: repository.refreshIsFull) { _, isFull in
                        connection.bleManager.setOffloadPaused(isFull)
                    }
                    // Bracelet (re)connecté : ré-arme l'alarme firmware perdue à un reboot du strap.
                    .onChange(of: connection.phase) { _, phase in
                        if phase == .connected { alarmController.rearmIfNeeded(using: connection) }
                    }
            } else {
                OnboardingView(
                    repository: repository,
                    connection: connection,
                    backup: backup
                )
                .environmentObject(connection)
                .environmentObject(connection.bleManager.syncCoordinator)
                .environmentObject(backup)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .inactive:
                repository.isStale = true
            case .background:
                connection.onEnterBackground()
                BackgroundTaskManager.shared.scheduleBackgroundRefresh()
                BackgroundTaskManager.shared.scheduleBackgroundProcessing()
            case .active:
                connection.enterForeground()
                alarmController.rearmIfNeeded(using: connection)
                repository.isStale = false
                repository.requestExpressRefresh()
            @unknown default:
                break
            }
        }
    }
}
