import BackgroundTasks
import Foundation
import HealthKit

/// Synchro Apple Santé en arrière-plan : un `HKObserverQuery` par type + `enableBackgroundDelivery`.
/// iOS réveille l'app quand de nouvelles données arrivent ; l'observer lance la synchro ancrée du
/// type puis appelle TOUJOURS son completionHandler (sinon iOS espace puis coupe les réveils).
///
/// Pas de BGTask : la livraison d'arrière-plan HealthKit relance l'app d'elle-même. Les observers
/// doivent être recréés à chaque lancement (y compris un lancement en arrière-plan), d'où l'appel
/// à `startIfEnabled()` depuis `LoopApp.init`.
final class HealthBackgroundSync: @unchecked Sendable {
    static let shared = HealthBackgroundSync()

    /// Posé après le premier import manuel : on n'installe rien tant que l'utilisateur n'a pas
    /// demandé l'accès (évite des observers inutiles sans autorisation).
    private static let enabledKey = "healthkit.samples.backgroundEnabled"

    private let healthStore = HKHealthStore()
    private let lock = NSLock()
    private var queries: [HealthSampleKind: HKObserverQuery] = [:]
    private var workoutQuery: HKObserverQuery?

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    /// À appeler au lancement. Sans effet si l'import n'a jamais été activé.
    func startIfEnabled() {
        guard isEnabled else { return }
        start()
        Task { @MainActor in await HealthKitImporter.shared.sync(requestAccess: false) }
    }

    /// Active la synchro d'arrière-plan (persisté) et installe les observers.
    func enable() {
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        start()
    }

    private func start() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        lock.lock()
        if workoutQuery == nil {
            let type = HKObjectType.workoutType()
            let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
                guard error == nil else { completion(); return }
                Task { @MainActor in
                    await HealthKitImporter.shared.sync(requestAccess: false)
                    completion()
                }
            }
            workoutQuery = query
            healthStore.execute(query)
            healthStore.enableBackgroundDelivery(for: type, frequency: .immediate) { _, _ in }
        }
        lock.unlock()
        for kind in HealthSampleKind.allCases {
            lock.lock()
            if queries[kind] != nil { lock.unlock(); continue }
            let query = HKObserverQuery(sampleType: kind.sampleType, predicate: nil) { _, completion, error in
                if error != nil {
                    completion()
                    return
                }
                Task.detached(priority: .utility) {
                    defer { completion() }
                    _ = try? await HealthSampleSyncEngine.shared.sync(kind)
                }
            }
            queries[kind] = query
            lock.unlock()
            healthStore.execute(query)
            healthStore.enableBackgroundDelivery(for: kind.sampleType, frequency: kind.updateFrequency) { _, _ in }
        }
    }
}


// MARK: - Synchro poursuivie en arrière-plan (BGContinuedProcessingTask)

/// Logique pure (testable) de la synchro Apple Santé poursuivie par iOS après que l'utilisateur
/// quitte l'app : format d'identifiant et progression.
enum HealthContinuedSyncPlan {
    /// Doit commencer par le bundle ID de l'app (exigé par iOS pour les identifiants joker).
    static let identifierPrefix = "com.iblur01.Loop.healthsync."
    /// Forme joker déclarée dans `BGTaskSchedulerPermittedIdentifiers` et passée à `register`.
    static let wildcardIdentifier = identifierPrefix + "*"

    /// Une unité par type d'échantillon, plus une pour les séances.
    static var totalUnits: Int64 { Int64(HealthSampleKind.allCases.count + 1) }

    static func makeIdentifier(suffix: String = UUID().uuidString) -> String {
        identifierPrefix + suffix
    }

    static func isHealthSyncIdentifier(_ id: String) -> Bool {
        id.hasPrefix(identifierPrefix) && id.count > identifierPrefix.count
    }

    /// Fraction 0...1 bornée, 0 si le total est invalide.
    static func fraction(completed: Int64, total: Int64) -> Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}

/// Soumet et exécute la synchro Apple Santé comme `BGContinuedProcessingTask` : iOS la poursuit
/// après verrouillage ou changement d'app et affiche la progression. Soumission possible
/// UNIQUEMENT depuis une action au premier plan (bouton). Même pipeline que l'import manuel :
/// `HealthSampleSyncEngine` puis séances (`HealthKitImporter`).
@MainActor
final class HealthContinuedSync: ObservableObject {
    static let shared = HealthContinuedSync()

    @Published private(set) var isRunning = false
    @Published private(set) var completedUnits: Int64 = 0
    @Published private(set) var lastError: String?
    /// Incrémenté à chaque fin de tâche : l'écran s'en sert pour recharger ses compteurs.
    @Published private(set) var finishedCount = 0

    var fraction: Double { HealthContinuedSyncPlan.fraction(completed: completedUnits, total: HealthContinuedSyncPlan.totalUnits) }

    private var registered = false

    private init() {}

    /// À appeler depuis `LoopApp.init`, une seule fois (un second enregistrement tue l'app).
    func register() {
        guard !registered else { return }
        registered = true
        let ok = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: HealthContinuedSyncPlan.wildcardIdentifier,
            using: nil
        ) { [weak self] task in
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                guard let self else { task.setTaskCompleted(success: false); return }
                self.run(task)
            }
        }
        if !ok { lastError = String(localized: "health.sync.unavailable", table: "Core") }
    }

    /// Soumet la tâche. À n'appeler que depuis le premier plan. Les erreurs de soumission sont
    /// exposées dans `lastError`, jamais propagées.
    func submit() async {
        guard !isRunning else { return }
        lastError = nil
        let request = BGContinuedProcessingTaskRequest(
            identifier: HealthContinuedSyncPlan.makeIdentifier(),
            title: String(localized: "health.sync.title", table: "Core"),
            subtitle: String(localized: "health.sync.subtitle", table: "Core"))
        request.strategy = .fail
        isRunning = true
        completedUnits = 0
        do {
            try await BGTaskScheduler.shared.submitTaskRequest(request)
        } catch {
            isRunning = false
            lastError = Self.message(for: error)
        }
    }

    private func run(_ task: BGContinuedProcessingTask) {
        isRunning = true
        completedUnits = 0
        let progress = task.progress
        progress.totalUnitCount = HealthContinuedSyncPlan.totalUnits
        progress.completedUnitCount = 0

        let work = Task { @MainActor [weak self] in
            var failures = 0
            for kind in HealthSampleKind.allCases {
                if Task.isCancelled { break }
                do { try await HealthSampleSyncEngine.shared.sync(kind) } catch is CancellationError { break } catch { failures += 1 }
                progress.completedUnitCount += 1
                self?.completedUnits = progress.completedUnitCount
            }
            if !Task.isCancelled {
                let workouts = HealthKitImporter.shared
                await workouts.sync(requestAccess: false)
                if workouts.lastError != nil { failures += 1 }
                progress.completedUnitCount += 1
                self?.completedUnits = progress.completedUnitCount
            }
            let cancelled = Task.isCancelled
            if cancelled {
                self?.lastError = String(localized: "health.sync.interrupted", table: "Core")
            } else if failures > 0 {
                self?.lastError = failures == 1 ? String(format: String(localized: "health.sync.incomplete.one", table: "Core"), failures) : String(format: String(localized: "health.sync.incomplete.other", table: "Core"), failures)
            } else {
                HealthBackgroundSync.shared.enable()
            }
            self?.isRunning = false
            self?.finishedCount += 1
            task.setTaskCompleted(success: failures == 0 && !cancelled)
        }
        task.expirationHandler = { work.cancel() }
    }

    private static func message(for error: Error) -> String {
        switch (error as? BGTaskScheduler.Error)?.code {
        case .notPermitted:
            return String(localized: "health.sync.denied", table: "Core")
        case .immediateRunIneligible:
            return String(localized: "health.sync.retry", table: "Core")
        case .tooManyPendingTaskRequests:
            return String(localized: "health.sync.pending", table: "Core")
        case .unavailable:
            return String(localized: "health.sync.disabled", table: "Core")
        default:
            return error.localizedDescription
        }
    }
}
