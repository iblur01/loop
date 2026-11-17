import Foundation
import HealthKit
import WhoopStore

// MARK: - Mapping (pure)

/// Entrée simple, indépendante de HealthKit, pour tester le mapping sans `HKWorkout`.
struct HealthWorkoutInput: Equatable {
    let id: String
    let activityTypeRaw: Int
    let start: Date
    let end: Date
    let duration: TimeInterval
    let energyKcal: Double?
    let distanceM: Double?
    let sourceName: String?
    let sourceBundle: String?
    /// `sourceRevision.productType` (ex. "Watch6,1"), identité matérielle stable non localisée.
    var productType: String? = nil
    /// `device?.model` (ex. "Watch", "iPhone").
    var deviceModel: String? = nil
}

enum HealthWorkoutMapping {
    static let source = "healthkit"

    static func map(_ input: HealthWorkoutInput, importedAt: Date) -> ExternalWorkout {
        let name = input.sourceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundle = input.sourceBundle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let product = input.productType?.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = input.deviceModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ExternalWorkout(
            id: input.id,
            source: source,
            sportType: input.activityTypeRaw,
            startDate: input.start.timeIntervalSince1970,
            endDate: input.end.timeIntervalSince1970,
            durationSec: input.duration,
            energyKcal: input.energyKcal,
            distanceM: input.distanceM,
            sourceName: (name?.isEmpty ?? true) ? nil : name,
            importedAt: importedAt.timeIntervalSince1970,
            sourceBundle: (bundle?.isEmpty ?? true) ? nil : bundle,
            productType: (product?.isEmpty ?? true) ? nil : product,
            deviceModel: (model?.isEmpty ?? true) ? nil : model)
    }
}

// MARK: - Importer

/// Import en lecture seule des séances Apple Santé (HKWorkout) vers `external_workout`.
/// Sync incrémentale via `HKAnchoredObjectQuery` ; l'ancre n'est avancée que dans la même
/// transaction que l'écriture des données, donc jamais écrasée en cas d'erreur.
@MainActor
final class HealthKitImporter: ObservableObject {
    static let shared = HealthKitImporter()
    private var syncWaiters: [CheckedContinuation<Void, Never>] = []

    enum AuthorizationState: Equatable {
        case unavailable
        /// iOS n'a pas encore demandé l'accès en lecture.
        case notRequested
        /// Demande déjà faite : iOS ne révèle pas si la lecture a été accordée ou refusée.
        case requested
        case unknown
    }

    @Published private(set) var authorization: AuthorizationState = .unknown
    @Published private(set) var isSyncing = false
    @Published private(set) var workoutCount = 0
    @Published private(set) var lastImportAt: Date?
    @Published private(set) var lastImportedCount = 0
    @Published private(set) var lastError: String?

    private static let lastImportKey = "healthkit.lastImportAt"
    private let healthStore = HKHealthStore()
    private var store: WhoopStore?

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    init() {
        lastImportAt = UserDefaults.standard.object(forKey: Self.lastImportKey) as? Date
    }

    /// HealthKit does not expose individual read decisions. Request all relevant types together.
    static var allReadTypes: Set<HKObjectType> {
        requestedReadTypes.union(HealthSampleKind.allReadTypes)
            .union([HKObjectType.characteristicType(forIdentifier: .dateOfBirth)!])
    }

    func requestAllAccess() async {
        guard Self.isAvailable else { return }
        lastError = nil
        do {
            try await healthStore.requestAuthorization(toShare: [], read: Self.allReadTypes)
            await refreshState()
            await WorkoutHealthDetailService.shared.forgetUnavailable()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - State

    func refreshState() async {
        guard Self.isAvailable else { authorization = .unavailable; return }
        let readTypes: Set<HKObjectType> = [HKObjectType.workoutType()]
        do {
            let status = try await healthStore.statusForAuthorizationRequest(toShare: [], read: readTypes)
            authorization = (status == .shouldRequest) ? .notRequested : .requested
        } catch {
            authorization = .unknown
        }
        if let store = await openStore() {
            workoutCount = (try? await store.externalWorkoutCount(source: HealthWorkoutMapping.source)) ?? 0
        }
    }

    // MARK: - Import

    /// Demande l'accès si nécessaire puis synchronise. `requestAccess` = false : sync silencieuse
    /// (n'affiche jamais la feuille d'autorisation).
    func sync(requestAccess: Bool) async {
        guard Self.isAvailable else { return }
        if isSyncing {
            await withCheckedContinuation { syncWaiters.append($0) }
            await sync(requestAccess: requestAccess)
            return
        }
        isSyncing = true
        lastError = nil
        defer {
            isSyncing = false
            let waiters = syncWaiters
            syncWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }

        await refreshState()
        // L'état publié ne regarde que les séances (la synchro silencieuse continue même si le
        // tracé n'a pas encore été demandé) ; la demande explicite couvre séances + tracé GPS.
        if requestAccess, await needsReadRequest() {
            do {
                try await healthStore.requestAuthorization(toShare: [], read: Self.requestedReadTypes)
            } catch {
                lastError = error.localizedDescription
                return
            }
            await refreshState()
            await WorkoutHealthDetailService.shared.forgetUnavailable()
        } else if authorization == .notRequested {
            return
        }

        guard let store = await openStore() else {
            lastError = String(localized: "health.database.unavailable", table: "Core")
            return
        }
        do {
            let source = HealthWorkoutMapping.source
            let anchor = try await store.externalSyncAnchor(source: source).flatMap(Self.decodeAnchor)
            let descriptor = HKAnchoredObjectQueryDescriptor(predicates: [.workout()], anchor: anchor)
            let result = try await descriptor.result(for: healthStore)

            let now = Date()
            let upserts = result.addedSamples.map { HealthWorkoutMapping.map(Self.input(from: $0), importedAt: now) }
            let deleted = result.deletedObjects.map { $0.uuid.uuidString }
            let newAnchor = try Self.encodeAnchor(result.newAnchor)
            try await store.applyExternalWorkoutBatch(source: source, upserts: upserts, deletedIds: deleted,
                                                      anchor: newAnchor, updatedAt: now.timeIntervalSince1970)
            if !upserts.isEmpty || !deleted.isEmpty {
                HealthChangeNotification.inputsChanged()
            }
            lastImportedCount = upserts.count
            lastImportAt = now
            UserDefaults.standard.set(now, forKey: Self.lastImportKey)
            workoutCount = (try? await store.externalWorkoutCount(source: source)) ?? 0
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Helpers

    /// Lecture seule : séances + tracés GPS des séances (HKWorkoutRoute, lu à la demande par
    /// `WorkoutHealthDetailService`). Jamais d'écriture.
    static let requestedReadTypes: Set<HKObjectType> = [HKObjectType.workoutType(), HKSeriesType.workoutRoute()]

    private func needsReadRequest() async -> Bool {
        let status = try? await healthStore.statusForAuthorizationRequest(toShare: [], read: Self.requestedReadTypes)
        return status == .shouldRequest
    }

    private func openStore() async -> WhoopStore? {
        if let store { return store }
        guard let path = try? StorePaths.defaultDatabasePath(),
              let opened = try? await WhoopStore(path: path) else { return nil }
        store = opened
        return opened
    }

    private static func input(from w: HKWorkout) -> HealthWorkoutInput {
        let energy = w.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?
            .doubleValue(for: .kilocalorie())
        return HealthWorkoutInput(
            id: w.uuid.uuidString,
            activityTypeRaw: Int(w.workoutActivityType.rawValue),
            start: w.startDate,
            end: w.endDate,
            duration: w.duration,
            energyKcal: energy,
            distanceM: distanceMeters(w),
            sourceName: w.sourceRevision.source.name,
            sourceBundle: w.sourceRevision.source.bundleIdentifier,
            productType: w.sourceRevision.productType,
            deviceModel: w.device?.model)
    }

    private static func distanceMeters(_ w: HKWorkout) -> Double? {
        let ids: [HKQuantityTypeIdentifier] = [.distanceWalkingRunning, .distanceCycling, .distanceSwimming,
                                               .distanceWheelchair, .distanceDownhillSnowSports]
        for id in ids {
            if let q = w.statistics(for: HKQuantityType(id))?.sumQuantity() {
                return q.doubleValue(for: .meter())
            }
        }
        return nil
    }

    private static func encodeAnchor(_ anchor: HKQueryAnchor) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
    }

    private static func decodeAnchor(_ data: Data) -> HKQueryAnchor? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }
}
