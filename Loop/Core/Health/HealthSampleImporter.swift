import Foundation
import HealthKit
import WhoopStore

// MARK: - Notifications

/// Notifications « entrées Santé changées ». Postées TOUJOURS sur le thread principal : les
/// observateurs (TodayView, LoopDataRepository) modifient de l'état SwiftUI / @Published, et les
/// émetteurs (acteurs et importeurs d'arrière-plan) ne doivent pas le faire depuis un autre thread.
enum HealthChangeNotification {
    static let inputsChangedName = Notification.Name("loop.healthInputsChanged")

    static func inputsChanged() {
        Task { @MainActor in
            NotificationCenter.default.post(name: inputsChangedName, object: nil)
        }
    }
}

// MARK: - HealthKit bridging

extension HealthSampleKind {
    var sampleType: HKSampleType {
        if let id = quantityIdentifier { return HKQuantityType(id) }
        return HKCategoryType(.sleepAnalysis)
    }

    var quantityIdentifier: HKQuantityTypeIdentifier? {
        switch self {
        case .stepCount: return .stepCount
        case .heartRate: return .heartRate
        case .restingHeartRate: return .restingHeartRate
        case .heartRateVariabilitySDNN: return .heartRateVariabilitySDNN
        case .activeEnergyBurned: return .activeEnergyBurned
        case .basalEnergyBurned: return .basalEnergyBurned
        case .distanceWalkingRunning: return .distanceWalkingRunning
        case .appleExerciseTime: return .appleExerciseTime
        case .vo2Max: return .vo2Max
        case .bodyMass: return .bodyMass
        case .sleepAnalysis: return nil
        }
    }

    /// Unité HK correspondant à `unit` (doit rester compatible avec le type, sinon HealthKit lève).
    var hkUnit: HKUnit? {
        switch self {
        case .stepCount: return .count()
        case .heartRate, .restingHeartRate: return .count().unitDivided(by: .minute())
        case .heartRateVariabilitySDNN: return .secondUnit(with: .milli)
        case .activeEnergyBurned, .basalEnergyBurned: return .kilocalorie()
        case .distanceWalkingRunning: return .meter()
        case .appleExerciseTime: return .minute()
        case .vo2Max:
            return .literUnit(with: .milli).unitDivided(by: .gramUnit(with: .kilo).unitMultiplied(by: .minute()))
        case .bodyMass: return .gramUnit(with: .kilo)
        case .sleepAnalysis: return nil
        }
    }

    var updateFrequency: HKUpdateFrequency {
        backgroundCadence == .immediate ? .immediate : .hourly
    }

    static var allReadTypes: Set<HKObjectType> {
        Set(allCases.map(\.sampleType))
    }
}

// MARK: - Sync engine

/// Synchro incrémentale Apple Santé → `health_sample`, une `HKAnchoredObjectQuery` par type.
/// Actor : tout le travail HealthKit/SQLite tourne hors du thread principal, et il est partagé
/// entre l'UI et les observers d'arrière-plan. Première passe sans ancre = historique complet,
/// paginé par lots ; chaque lot est écrit avec son ancre dans UNE transaction, donc une erreur
/// laisse l'ancre précédente intacte.
actor HealthSampleSyncEngine {
    static let shared = HealthSampleSyncEngine()

    /// Taille d'un lot (ajouts + suppressions). Borne la mémoire au premier import (FC = gros volume).
    static let batchLimit = 5_000

    private let healthStore = HKHealthStore()
    private var running: Set<HealthSampleKind> = []
    private var pending: Set<HealthSampleKind> = []

    /// Synchronise un type. Si une synchro du même type est déjà en cours, la marque à refaire
    /// à la fin de celle-ci (pour ne pas rater ce qui vient d'arriver) et rend 0.
    /// - Returns: nombre d'échantillons ajoutés ou mis à jour.
    @discardableResult
    func sync(_ kind: HealthSampleKind) async throws -> Int {
        guard HKHealthStore.isHealthDataAvailable() else { return 0 }
        if running.contains(kind) {
            pending.insert(kind)
            return 0
        }
        running.insert(kind)
        defer { running.remove(kind) }

        // Handle ouvert le temps de la synchro seulement : ne retient pas le fichier SQLite
        // (restauration de sauvegarde) entre deux réveils d'arrière-plan.
        guard let path = try? StorePaths.defaultDatabasePath() else { throw SyncError.storeUnavailable }
        let store = try await WhoopStore(path: path)

        var total = 0
        repeat {
            pending.remove(kind)
            total += try await drain(kind, store: store)
        } while pending.contains(kind)
        return total
    }

    /// Synchronise tous les types ; une erreur sur un type n'arrête pas les autres.
    func syncAll() async -> [HealthSampleKind: Error] {
        var errors: [HealthSampleKind: Error] = [:]
        for kind in HealthSampleKind.allCases {
            do { try await sync(kind) } catch { errors[kind] = error }
        }
        return errors
    }

    private func drain(_ kind: HealthSampleKind, store: WhoopStore) async throws -> Int {
        let ownBundle = Bundle.main.bundleIdentifier
        var total = 0
        var modified = false
        defer {
            if modified { HealthChangeNotification.inputsChanged() }
        }
        while true {
            try Task.checkCancellation()
            let anchor = try await store.healthSyncAnchor(type: kind.rawValue).flatMap(Self.decodeAnchor)
            let page = try await fetch(kind, anchor: anchor)
            let now = Date()
            let upserts = page.added.compactMap {
                HealthSampleMapping.map(Self.input(from: $0, kind: kind), importedAt: now, ownBundleId: ownBundle)
            }
            let deleted = page.deleted.map { $0.uuid.uuidString }
            let anchorData = try Self.encodeAnchor(page.newAnchor)
            try await store.applyHealthSampleBatch(type: kind.rawValue, upserts: upserts, deletedUUIDs: deleted,
                                                   anchor: anchorData, updatedAt: now.timeIntervalSince1970)
            if !upserts.isEmpty || !deleted.isEmpty { modified = true }
            total += upserts.count
            if page.added.count + page.deleted.count < Self.batchLimit { return total }
        }
    }

    private struct Page {
        let added: [HKSample]
        let deleted: [HKDeletedObject]
        let newAnchor: HKQueryAnchor
    }

    private func fetch(_ kind: HealthSampleKind, anchor: HKQueryAnchor?) async throws -> Page {
        if let id = kind.quantityIdentifier {
            let d = HKAnchoredObjectQueryDescriptor(predicates: [.quantitySample(type: HKQuantityType(id))],
                                                    anchor: anchor, limit: Self.batchLimit)
            let r = try await d.result(for: healthStore)
            return Page(added: r.addedSamples, deleted: r.deletedObjects, newAnchor: r.newAnchor)
        }
        let d = HKAnchoredObjectQueryDescriptor(predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis))],
                                                anchor: anchor, limit: Self.batchLimit)
        let r = try await d.result(for: healthStore)
        return Page(added: r.addedSamples, deleted: r.deletedObjects, newAnchor: r.newAnchor)
    }

    // MARK: - Helpers

    enum SyncError: LocalizedError {
        case storeUnavailable
        var errorDescription: String? { "Base locale indisponible." }
    }

    static func input(from sample: HKSample, kind: HealthSampleKind) -> HealthSampleInput {
        var value: Double?
        if let q = sample as? HKQuantitySample, let unit = kind.hkUnit, q.quantity.is(compatibleWith: unit) {
            value = q.quantity.doubleValue(for: unit)
        } else if let c = sample as? HKCategorySample {
            value = Double(c.value)
        }
        let source = sample.sourceRevision.source
        return HealthSampleInput(
            uuid: sample.uuid.uuidString,
            kind: kind,
            start: sample.startDate,
            end: sample.endDate,
            value: value,
            sourceName: source.name,
            sourceBundle: source.bundleIdentifier,
            originMarker: sample.metadata?[HealthSampleMapping.originMetadataKey] as? String,
            productType: sample.sourceRevision.productType,
            deviceModel: sample.device?.model)
    }

    private static func encodeAnchor(_ anchor: HKQueryAnchor) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
    }

    private static func decodeAnchor(_ data: Data) -> HKQueryAnchor? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }
}

// MARK: - UI state

/// État de l'import des échantillons Apple Santé pour `HealthImportView`.
@MainActor
final class HealthSampleImporter: ObservableObject {
    struct TypeState: Equatable {
        var count = 0
        var lastSyncAt: Date?
        var error: String?
    }

    @Published private(set) var authorization: HealthKitImporter.AuthorizationState = .unknown
    @Published private(set) var isSyncing = false
    @Published private(set) var states: [HealthSampleKind: TypeState] = [:]
    @Published private(set) var lastError: String?

    private let healthStore = HKHealthStore()

    func refreshState() async {
        guard HealthKitImporter.isAvailable else { authorization = .unavailable; return }
        do {
            let status = try await healthStore.statusForAuthorizationRequest(toShare: [], read: HealthSampleKind.allReadTypes)
            authorization = (status == .shouldRequest) ? .notRequested : .requested
        } catch {
            authorization = .unknown
        }
        await reloadCounts()
    }

    /// Demande l'accès si nécessaire (si `requestAccess`), importe tous les types, puis active
    /// la synchro d'arrière-plan.
    func importAll(requestAccess: Bool) async {
        guard HealthKitImporter.isAvailable, !isSyncing else { return }
        isSyncing = true
        lastError = nil
        defer { isSyncing = false }

        await refreshState()
        if authorization == .notRequested {
            guard requestAccess else { return }
            do {
                try await healthStore.requestAuthorization(toShare: [], read: HealthSampleKind.allReadTypes)
            } catch {
                lastError = error.localizedDescription
                return
            }
            await refreshState()
        }

        let errors = await HealthSampleSyncEngine.shared.syncAll()
        await reloadCounts()
        for (kind, error) in errors {
            states[kind, default: TypeState()].error = error.localizedDescription
        }
        if !errors.isEmpty { lastError = "Import incomplet : \(errors.count) type(s) en erreur." }
        HealthBackgroundSync.shared.enable()
    }

    private func reloadCounts() async {
        guard let path = try? StorePaths.defaultDatabasePath(),
              let store = try? await WhoopStore(path: path) else { return }
        let summaries = (try? await store.healthSampleSummaries()) ?? []
        let synced = (try? await store.healthSyncUpdatedAt()) ?? [:]
        var next: [HealthSampleKind: TypeState] = [:]
        for kind in HealthSampleKind.allCases {
            let count = summaries.first { $0.type == kind.rawValue }?.count ?? 0
            let at = synced[kind.rawValue].map { Date(timeIntervalSince1970: $0) }
            next[kind] = TypeState(count: count, lastSyncAt: at, error: nil)
        }
        states = next
    }
}
