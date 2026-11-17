import CoreLocation
import Foundation
import HealthKit
import WhoopStore

// MARK: - HealthKit source

/// Lecture HealthKit (lecture seule) du tracé et de la FC d'UNE séance. Aucune journalisation
/// des coordonnées ni des valeurs, aucun réseau : les données vont uniquement dans le cache local.
struct HealthKitWorkoutDetailSource: WorkoutDetailSource {
    /// Plafond défensif d'échantillons FC lus pour une séance (≈ 70 h à 5 s).
    static let heartRateSampleLimit = 50_000

    private let healthStore: HKHealthStore

    init(healthStore: HKHealthStore = HKHealthStore()) { self.healthStore = healthStore }

    static func readTypes(for kind: WorkoutDetailKind) -> Set<HKObjectType> {
        switch kind {
        case .route: return [HKObjectType.workoutType(), HKSeriesType.workoutRoute()]
        case .heart: return [HKQuantityType(.heartRate)]
        }
    }

    func authorization(for kind: WorkoutDetailKind) async -> WorkoutDetailAuthorization {
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailableOnDevice }
        do {
            let status = try await healthStore.statusForAuthorizationRequest(toShare: [], read: Self.readTypes(for: kind))
            return status == .shouldRequest ? .notDetermined : .requested
        } catch {
            return .requested
        }
    }

    func routePoints(externalWorkoutID: String) async throws -> [WorkoutRoutePoint]? {
        guard let uuid = UUID(uuidString: externalWorkoutID) else { return nil }
        do {
            let workouts = try await HKSampleQueryDescriptor(
                predicates: [.workout(HKQuery.predicateForObject(with: uuid))],
                sortDescriptors: [], limit: 1).result(for: healthStore)
            guard let workout = workouts.first else { return nil }
            let routes = try await HKSampleQueryDescriptor(
                predicates: [.workoutRoute(HKQuery.predicateForObjects(from: workout))],
                sortDescriptors: [SortDescriptor(\.startDate)]).result(for: healthStore)
            guard !routes.isEmpty else { return nil }
            var points: [WorkoutRoutePoint] = []
            for route in routes {
                for try await location in HKWorkoutRouteQueryDescriptor(route).results(for: healthStore) {
                    try Task.checkCancellation()
                    points.append(Self.point(from: location))
                }
            }
            return points
        } catch {
            throw Self.mapped(error)
        }
    }

    func heartRateSamples(from: Double, to: Double) async throws -> [WorkoutHeartRatePoint] {
        let predicate = HKQuery.predicateForSamples(withStart: Date(timeIntervalSince1970: from),
                                                    end: Date(timeIntervalSince1970: to),
                                                    options: .strictStartDate)
        let unit = HKUnit.count().unitDivided(by: .minute())
        do {
            let samples = try await HKSampleQueryDescriptor(
                predicates: [.quantitySample(type: HKQuantityType(.heartRate), predicate: predicate)],
                sortDescriptors: [SortDescriptor(\.startDate)],
                limit: Self.heartRateSampleLimit).result(for: healthStore)
            return samples.map {
                WorkoutHeartRatePoint(ts: $0.startDate.timeIntervalSince1970, bpm: $0.quantity.doubleValue(for: unit))
            }
        } catch {
            throw Self.mapped(error)
        }
    }

    // MARK: - Mapping (pur)

    static func point(from location: CLLocation) -> WorkoutRoutePoint {
        WorkoutRoutePoint(
            timestamp: location.timestamp.timeIntervalSince1970,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.verticalAccuracy >= 0 ? location.altitude : nil,
            horizontalAccuracy: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil)
    }

    /// Les défauts d'autorisation signalés par HealthKit deviennent `.notAuthorized` ; le reste passe tel quel.
    static func mapped(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let hk = error as? HKError,
           hk.code == .errorAuthorizationDenied || hk.code == .errorAuthorizationNotDetermined {
            return WorkoutDetailSourceError.notAuthorized
        }
        return error
    }
}

// MARK: - Service (API pour l'UI)

/// Point d'entrée de la page de détail d'une séance pour les données Apple Santé complémentaires.
/// Les lectures se font à la demande (à l'ouverture), uniquement pour la séance concernée, et sont
/// mises en cache dans `whoop.sqlite` (donc incluses dans le `.loopbackup`). Jamais d'écriture
/// HealthKit, jamais de réseau, aucune journalisation.
///
/// Usage UI : `await WorkoutHealthDetailService.shared.loadWorkoutRoute(for: session.perceivedEffortKey)`
/// dans un `.task` (annulé automatiquement à la fermeture). `.notAuthorized` → afficher
/// « Tracé non autorisé » discret ; `.unavailable` → ne rien afficher.
actor WorkoutHealthDetailService {
    static let shared = WorkoutHealthDetailService()

    private let source: HealthKitWorkoutDetailSource
    private let healthStore: HKHealthStore
    private var loader: WorkoutDetailLoader?

    init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
        self.source = HealthKitWorkoutDetailSource(healthStore: healthStore)
    }

    /// Tracé GPS (HKWorkoutRoute) d'une séance importée d'Apple Santé. Séance bracelet → `.unavailable`.
    func loadWorkoutRoute(for workoutKey: String, forceRefresh: Bool = false) async -> WorkoutDetailResult<CachedWorkoutRoute> {
        guard let loader = await openLoader() else { return .failed(ServiceError.storeUnavailable) }
        return await loader.loadWorkoutRoute(for: workoutKey, forceRefresh: forceRefresh)
    }

    /// Série FC Apple Santé (pas de 5 s) sur la fenêtre de la séance. Pour une séance Santé la
    /// fenêtre est lue dans `external_workout` ; pour une séance bracelet, passer `start`/`end`.
    func loadWorkoutHeartRateSeries(for workoutKey: String, start: Date? = nil, end: Date? = nil,
                                    forceRefresh: Bool = false) async -> WorkoutDetailResult<CachedWorkoutHeartSeries> {
        guard let loader = await openLoader() else { return .failed(ServiceError.storeUnavailable) }
        var window: ClosedRange<Double>?
        if let start, let end, end >= start { window = start.timeIntervalSince1970...end.timeIntervalSince1970 }
        return await loader.loadWorkoutHeartRateSeries(for: workoutKey, window: window, forceRefresh: forceRefresh)
    }

    /// Lecture seule : état d'autorisation de la donnée (sans afficher de feuille).
    func authorization(for kind: WorkoutDetailKind) async -> WorkoutDetailAuthorization {
        await source.authorization(for: kind)
    }

    /// Demande explicite (bouton « Autoriser ») : lecture seule du tracé et de la FC. Si iOS a
    /// déjà posé la question, la feuille ne réapparaît pas : l'utilisateur doit passer par
    /// Réglages › Santé › Accès aux données et appareils › Loop. Oublie ensuite les « rien trouvé »
    /// mémorisés pour relire Santé à la prochaine ouverture.
    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let types = HealthKitWorkoutDetailSource.readTypes(for: .route)
            .union(HealthKitWorkoutDetailSource.readTypes(for: .heart))
        try await healthStore.requestAuthorization(toShare: [], read: types)
        await forgetUnavailable()
    }

    /// Oublie les « rien trouvé » mémorisés (appelé après toute demande d'autorisation).
    func forgetUnavailable() async {
        await openLoader()?.forgetUnavailable()
    }

    /// Vide le cache tracé/FC (toutes séances).
    func clearCache() async throws {
        guard let store = await openStore() else { return }
        try await store.deleteAllWorkoutDetailCache()
    }

    enum ServiceError: LocalizedError {
        case storeUnavailable
        var errorDescription: String? { String(localized: "health.database.unavailable", table: "Core") }
    }

    // MARK: - Helpers

    private var store: WhoopStore?

    private func openStore() async -> WhoopStore? {
        if let store { return store }
        guard let path = try? StorePaths.defaultDatabasePath(),
              let opened = try? await WhoopStore(path: path) else { return nil }
        store = opened
        return opened
    }

    private func openLoader() async -> WorkoutDetailLoader? {
        if let loader { return loader }
        guard let store = await openStore() else { return nil }
        let made = WorkoutDetailLoader(store: store, source: source)
        loader = made
        return made
    }
}

// MARK: - Raccourcis par séance

extension WorkoutHealthDetailService {
    func loadWorkoutRoute(for session: WorkoutSession, forceRefresh: Bool = false) async -> WorkoutDetailResult<CachedWorkoutRoute> {
        await loadWorkoutRoute(for: session.perceivedEffortKey, forceRefresh: forceRefresh)
    }

    /// Fenêtre = [startTs, endTs] de la séance (bracelet ou Santé).
    func loadWorkoutHeartRateSeries(for session: WorkoutSession,
                                    forceRefresh: Bool = false) async -> WorkoutDetailResult<CachedWorkoutHeartSeries> {
        await loadWorkoutHeartRateSeries(for: session.perceivedEffortKey,
                                         start: Date(timeIntervalSince1970: TimeInterval(session.startTs)),
                                         end: Date(timeIntervalSince1970: TimeInterval(session.endTs)),
                                         forceRefresh: forceRefresh)
    }
}
