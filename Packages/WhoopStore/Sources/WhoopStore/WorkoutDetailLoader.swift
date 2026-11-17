import Foundation

// MARK: - Résultat typé

/// Résultat d'une lecture à la demande. `unavailable` (pas de tracé, pas de FC sur la fenêtre)
/// n'est PAS une erreur : c'est le cas normal d'une séance sans GPS.
public enum WorkoutDetailResult<Value> {
    case loaded(Value)
    /// Accès jamais demandé (ou refus explicitement signalé par HealthKit).
    case notAuthorized
    /// Rien pour cette séance (ou séance non issue d'Apple Santé pour le tracé).
    case unavailable
    case failed(Error)

    public var value: Value? {
        if case .loaded(let v) = self { return v }
        return nil
    }
}

extension WorkoutDetailResult: @unchecked Sendable where Value: Sendable {}

// MARK: - Source (abstraite, implémentée par HealthKit dans l'app)

public enum WorkoutDetailAuthorization: Equatable, Sendable {
    /// La feuille d'autorisation n'a jamais été montrée pour ce type.
    case notDetermined
    /// Demande déjà faite : iOS ne dit pas si la lecture est accordée ou refusée.
    case requested
    /// Apple Santé indisponible sur l'appareil.
    case unavailableOnDevice
}

public enum WorkoutDetailSourceError: Error, Equatable {
    /// HealthKit a explicitement signalé un défaut d'autorisation.
    case notAuthorized
}

/// Lecture brute des données complémentaires. Implémentation réelle : HealthKit (app).
public protocol WorkoutDetailSource: Sendable {
    func authorization(for kind: WorkoutDetailKind) async -> WorkoutDetailAuthorization
    /// Points du tracé de la séance HealthKit `externalWorkoutID`, nil si aucun tracé / séance introuvable.
    /// Lève `WorkoutDetailSourceError.notAuthorized` si HealthKit signale un défaut d'accès.
    func routePoints(externalWorkoutID: String) async throws -> [WorkoutRoutePoint]?
    /// Échantillons FC (bpm) dont le début est dans [from, to] (secondes epoch).
    func heartRateSamples(from: Double, to: Double) async throws -> [WorkoutHeartRatePoint]
}

// MARK: - Loader (cache + politique)

/// Lit à la demande le tracé et la série FC d'une séance, avec cache local dans `whoop.sqlite`.
/// - Cache `loaded` : renvoyé sans réinterroger la source (sauf `forceRefresh`).
/// - Cache `unavailable` : renvoyé tant qu'il a moins de `unavailableRetryInterval` (un tracé
///   Apple Watch peut arriver en retard dans Santé).
/// - Annulation : une tâche annulée renvoie `.failed(CancellationError())` et n'écrit rien.
/// Aucune journalisation, aucun réseau.
public actor WorkoutDetailLoader {
    private let store: WhoopStore
    private let source: WorkoutDetailSource
    private let unavailableRetryInterval: Double
    private let now: @Sendable () -> Date

    public init(store: WhoopStore, source: WorkoutDetailSource,
                unavailableRetryInterval: Double = 6 * 3_600,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.source = source
        self.unavailableRetryInterval = unavailableRetryInterval
        self.now = now
    }

    public func loadWorkoutRoute(for workoutKey: String, forceRefresh: Bool = false) async -> WorkoutDetailResult<CachedWorkoutRoute> {
        // Seules les séances importées d'Apple Santé peuvent avoir un HKWorkoutRoute.
        guard case .external(let externalID)? = WorkoutDetailKey(workoutKey) else { return .unavailable }
        let cached = try? await store.workoutRoute(workoutKey: workoutKey)
        if !forceRefresh {
            if let cached { return .loaded(cached) }
            if await isFreshUnavailable(workoutKey, .route) { return .unavailable }
        }
        switch await source.authorization(for: .route) {
        case .unavailableOnDevice: return cached.map { .loaded($0) } ?? .unavailable
        case .notDetermined: return cached.map { .loaded($0) } ?? .notAuthorized
        case .requested: break
        }
        do {
            try Task.checkCancellation()
            let raw = try await source.routePoints(externalWorkoutID: externalID) ?? []
            try Task.checkCancellation()
            let fetchedAt = now().timeIntervalSince1970
            guard !raw.isEmpty else {
                try await store.markWorkoutDetailUnavailable(workoutKey: workoutKey, kind: .route, fetchedAt: fetchedAt)
                return .unavailable
            }
            let sorted = raw.sorted { $0.timestamp < $1.timestamp }
            let route = CachedWorkoutRoute(workoutKey: workoutKey, points: WorkoutSeriesDecimation.decimateRoute(sorted),
                                     sourcePointCount: sorted.count, fetchedAt: fetchedAt)
            try await store.replaceWorkoutRoute(route)
            return .loaded(route)
        } catch WorkoutDetailSourceError.notAuthorized {
            return cached.map { .loaded($0) } ?? .notAuthorized
        } catch is CancellationError {
            return .failed(CancellationError())
        } catch {
            return cached.map { .loaded($0) } ?? .failed(error)
        }
    }

    /// `window` (secondes epoch) : obligatoire pour une séance bracelet ; pour une séance Santé,
    /// déduite de `external_workout` si absente.
    public func loadWorkoutHeartRateSeries(for workoutKey: String, window: ClosedRange<Double>? = nil,
                                           forceRefresh: Bool = false) async -> WorkoutDetailResult<CachedWorkoutHeartSeries> {
        guard let key = WorkoutDetailKey(workoutKey) else { return .unavailable }
        let cached = try? await store.workoutHeartSeries(workoutKey: workoutKey)
        if !forceRefresh {
            if let cached { return .loaded(cached) }
            if await isFreshUnavailable(workoutKey, .heart) { return .unavailable }
        }
        var range = window
        if range == nil, case .external(let id) = key,
           let w = try? await store.externalWorkout(id: id), w.endDate >= w.startDate {
            range = w.startDate...w.endDate
        }
        guard let range else { return cached.map { .loaded($0) } ?? .unavailable }

        switch await source.authorization(for: .heart) {
        case .unavailableOnDevice: return cached.map { .loaded($0) } ?? .unavailable
        case .notDetermined: return cached.map { .loaded($0) } ?? .notAuthorized
        case .requested: break
        }
        do {
            try Task.checkCancellation()
            let raw = try await source.heartRateSamples(from: range.lowerBound, to: range.upperBound)
            try Task.checkCancellation()
            let fetchedAt = now().timeIntervalSince1970
            // Séance en cours : on ne fige rien en cache.
            let finished = range.upperBound <= fetchedAt
            let points = WorkoutSeriesDecimation.bucketHeartRate(raw)
            guard !points.isEmpty else {
                if finished {
                    try await store.markWorkoutDetailUnavailable(workoutKey: workoutKey, kind: .heart, fetchedAt: fetchedAt)
                }
                return .unavailable
            }
            let series = CachedWorkoutHeartSeries(workoutKey: workoutKey, points: points,
                                            sourceSampleCount: raw.count, fetchedAt: fetchedAt)
            if finished { try await store.replaceWorkoutHeartSeries(series) }
            return .loaded(series)
        } catch WorkoutDetailSourceError.notAuthorized {
            return cached.map { .loaded($0) } ?? .notAuthorized
        } catch is CancellationError {
            return .failed(CancellationError())
        } catch {
            return cached.map { .loaded($0) } ?? .failed(error)
        }
    }

    /// À appeler après une (nouvelle) demande d'autorisation : les « rien trouvé » mémorisés
    /// peuvent venir d'un refus, on les relira.
    public func forgetUnavailable() async {
        try? await store.forgetUnavailableWorkoutDetails()
    }

    private func isFreshUnavailable(_ key: String, _ kind: WorkoutDetailKind) async -> Bool {
        guard let status = try? await store.workoutDetailFetchStatus(workoutKey: key, kind: kind),
              status.state == .unavailable else { return false }
        return now().timeIntervalSince1970 - status.fetchedAt < unavailableRetryInterval
    }
}
