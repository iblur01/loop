import Foundation
import GRDB

// MARK: - Clé de séance

/// Clé stable d'une séance, analysée depuis `WorkoutPerceivedEffort.workoutKey` :
/// `external:<uuid HealthKit>` ou `band:<deviceId>:<startTs>`.
public enum WorkoutDetailKey: Equatable, Sendable {
    case external(id: String)
    case band(deviceId: String, startTs: Int)

    /// nil si la clé n'a aucun des deux formats. `deviceId` peut contenir ":" (on coupe au dernier).
    public init?(_ key: String) {
        if key.hasPrefix("external:") {
            let id = String(key.dropFirst("external:".count))
            guard !id.isEmpty else { return nil }
            self = .external(id: id)
        } else if key.hasPrefix("band:") {
            let rest = key.dropFirst("band:".count)
            guard let sep = rest.lastIndex(of: ":"),
                  let ts = Int(rest[rest.index(after: sep)...]) else { return nil }
            let device = String(rest[..<sep])
            guard !device.isEmpty else { return nil }
            self = .band(deviceId: device, startTs: ts)
        } else {
            return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .external(let id): return "external:\(id)"
        case .band(let deviceId, let startTs): return "band:\(deviceId):\(startTs)"
        }
    }
}

// MARK: - Modèles

/// Point GPS d'un tracé de séance (lu depuis HKWorkoutRoute). Dates en secondes epoch.
public struct WorkoutRoutePoint: Equatable, Sendable {
    public let timestamp: Double
    public let latitude: Double
    public let longitude: Double
    /// Altitude en mètres, nil si inconnue (accuracy verticale négative).
    public let altitude: Double?
    /// Précision horizontale en mètres, nil si inconnue.
    public let horizontalAccuracy: Double?

    public init(timestamp: Double, latitude: Double, longitude: Double,
                altitude: Double? = nil, horizontalAccuracy: Double? = nil) {
        self.timestamp = timestamp; self.latitude = latitude; self.longitude = longitude
        self.altitude = altitude; self.horizontalAccuracy = horizontalAccuracy
    }
}

/// Fréquence cardiaque (bpm) à l'instant `ts` (secondes epoch).
public struct WorkoutHeartRatePoint: Equatable, Sendable {
    public let ts: Double
    public let bpm: Double

    public init(ts: Double, bpm: Double) { self.ts = ts; self.bpm = bpm }
}

/// Tracé mis en cache. `sourcePointCount` = nombre de points lus dans Apple Santé avant décimation.
public struct CachedWorkoutRoute: Equatable, Sendable {
    public let workoutKey: String
    public let points: [WorkoutRoutePoint]
    public let sourcePointCount: Int
    public let fetchedAt: Double
    public var isDecimated: Bool { points.count < sourcePointCount }

    public init(workoutKey: String, points: [WorkoutRoutePoint], sourcePointCount: Int, fetchedAt: Double) {
        self.workoutKey = workoutKey; self.points = points
        self.sourcePointCount = sourcePointCount; self.fetchedAt = fetchedAt
    }
}

/// Série FC mise en cache. `sourceSampleCount` = échantillons lus avant décimation.
public struct CachedWorkoutHeartSeries: Equatable, Sendable {
    public let workoutKey: String
    public let points: [WorkoutHeartRatePoint]
    public let sourceSampleCount: Int
    public let fetchedAt: Double
    public var isDecimated: Bool { points.count < sourceSampleCount }

    public init(workoutKey: String, points: [WorkoutHeartRatePoint], sourceSampleCount: Int, fetchedAt: Double) {
        self.workoutKey = workoutKey; self.points = points
        self.sourceSampleCount = sourceSampleCount; self.fetchedAt = fetchedAt
    }
}

/// Type de donnée complémentaire d'une séance (valeur stockée dans `workout_detail_fetch.kind`).
public enum WorkoutDetailKind: String, Sendable, CaseIterable {
    case route
    case heart
}

/// Dernier résultat de lecture Apple Santé pour (séance, type). `unavailable` = rien trouvé
/// (fréquent : séance sans GPS) — mémorisé pour ne pas réinterroger Santé à chaque ouverture.
public struct WorkoutDetailFetchStatus: Equatable, Sendable {
    public enum State: String, Sendable { case loaded, unavailable }
    public let state: State
    public let fetchedAt: Double

    public init(state: State, fetchedAt: Double) { self.state = state; self.fetchedAt = fetchedAt }
}

// MARK: - Décimation (pure)

public enum WorkoutSeriesDecimation {
    public static let maxRoutePoints = 2_000
    public static let heartRateStep: Double = 5

    /// Si `points.count > maxPoints`, garde exactement `maxPoints` points répartis régulièrement
    /// sur les indices, premier et dernier inclus. Sinon renvoie l'entrée telle quelle.
    public static func decimateRoute(_ points: [WorkoutRoutePoint],
                                     maxPoints: Int = maxRoutePoints) -> [WorkoutRoutePoint] {
        let n = points.count
        guard n > maxPoints else { return points }
        guard maxPoints >= 2 else { return Array(points.prefix(max(0, maxPoints))) }
        var out: [WorkoutRoutePoint] = []
        out.reserveCapacity(maxPoints)
        let span = Double(n - 1) / Double(maxPoints - 1)
        var last = -1
        for i in 0..<maxPoints {
            // n > maxPoints ⇒ span > 1, donc les indices arrondis sont strictement croissants.
            let idx = i == maxPoints - 1 ? n - 1 : min(n - 1, Int((Double(i) * span).rounded()))
            if idx != last { out.append(points[idx]); last = idx }
        }
        return out
    }

    /// Regroupe la série par fenêtres de `step` secondes alignées sur l'epoch (moyenne des bpm,
    /// horodatage = début de fenêtre). Trie l'entrée et ignore les valeurs non finies ou ≤ 0.
    public static func bucketHeartRate(_ samples: [WorkoutHeartRatePoint],
                                       step: Double = heartRateStep) -> [WorkoutHeartRatePoint] {
        let valid = samples.filter { $0.ts.isFinite && $0.bpm.isFinite && $0.bpm > 0 }.sorted { $0.ts < $1.ts }
        guard step > 0, !valid.isEmpty else { return valid }
        var out: [WorkoutHeartRatePoint] = []
        var bucket = (valid[0].ts / step).rounded(.down) * step
        var sum = 0.0, count = 0
        for s in valid {
            let b = (s.ts / step).rounded(.down) * step
            if b != bucket {
                out.append(WorkoutHeartRatePoint(ts: bucket, bpm: sum / Double(count)))
                bucket = b; sum = 0; count = 0
            }
            sum += s.bpm; count += 1
        }
        out.append(WorkoutHeartRatePoint(ts: bucket, bpm: sum / Double(count)))
        return out
    }
}

// MARK: - Store

extension WhoopStore {
    /// Remplace le tracé mis en cache de la séance et marque son statut `loaded`, en une transaction.
    public func replaceWorkoutRoute(_ route: CachedWorkoutRoute) throws {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM workout_route_point WHERE workoutKey = ?", arguments: [route.workoutKey])
            for (idx, p) in route.points.enumerated() {
                try db.execute(sql: """
                    INSERT INTO workout_route_point
                    (workoutKey, idx, timestamp, latitude, longitude, altitude, horizontalAccuracy)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [route.workoutKey, idx, p.timestamp, p.latitude, p.longitude,
                                     p.altitude, p.horizontalAccuracy])
            }
            try Self.writeFetchStatus(db, key: route.workoutKey, kind: .route, state: .loaded,
                                      sourceCount: route.sourcePointCount, fetchedAt: route.fetchedAt)
        }
    }

    public func workoutRoute(workoutKey: String) throws -> CachedWorkoutRoute? {
        try syncRead { db in
            guard let meta = try Self.fetchStatusRow(db, key: workoutKey, kind: .route),
                  meta["state"] as String == WorkoutDetailFetchStatus.State.loaded.rawValue else { return nil }
            let points = try Row.fetchAll(db, sql: """
                SELECT * FROM workout_route_point WHERE workoutKey = ? ORDER BY idx
                """, arguments: [workoutKey]).map {
                    WorkoutRoutePoint(timestamp: $0["timestamp"], latitude: $0["latitude"], longitude: $0["longitude"],
                                      altitude: $0["altitude"], horizontalAccuracy: $0["horizontalAccuracy"])
                }
            return CachedWorkoutRoute(workoutKey: workoutKey, points: points,
                                sourcePointCount: meta["sourceCount"], fetchedAt: meta["fetchedAt"])
        }
    }

    /// Remplace la série FC mise en cache de la séance et marque son statut `loaded`.
    public func replaceWorkoutHeartSeries(_ series: CachedWorkoutHeartSeries) throws {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM workout_heart_series WHERE workoutKey = ?", arguments: [series.workoutKey])
            for p in series.points {
                try db.execute(sql: "INSERT OR REPLACE INTO workout_heart_series (workoutKey, ts, bpm) VALUES (?, ?, ?)",
                               arguments: [series.workoutKey, p.ts, p.bpm])
            }
            try Self.writeFetchStatus(db, key: series.workoutKey, kind: .heart, state: .loaded,
                                      sourceCount: series.sourceSampleCount, fetchedAt: series.fetchedAt)
        }
    }

    public func workoutHeartSeries(workoutKey: String) throws -> CachedWorkoutHeartSeries? {
        try syncRead { db in
            guard let meta = try Self.fetchStatusRow(db, key: workoutKey, kind: .heart),
                  meta["state"] as String == WorkoutDetailFetchStatus.State.loaded.rawValue else { return nil }
            let points = try Row.fetchAll(db, sql: """
                SELECT ts, bpm FROM workout_heart_series WHERE workoutKey = ? ORDER BY ts
                """, arguments: [workoutKey]).map { WorkoutHeartRatePoint(ts: $0["ts"], bpm: $0["bpm"]) }
            return CachedWorkoutHeartSeries(workoutKey: workoutKey, points: points,
                                      sourceSampleCount: meta["sourceCount"], fetchedAt: meta["fetchedAt"])
        }
    }

    /// Mémorise « rien dans Apple Santé » pour (séance, type) et purge les points éventuels.
    public func markWorkoutDetailUnavailable(workoutKey: String, kind: WorkoutDetailKind, fetchedAt: Double) throws {
        try syncWrite { db in
            try Self.deletePoints(db, key: workoutKey, kind: kind)
            try Self.writeFetchStatus(db, key: workoutKey, kind: kind, state: .unavailable,
                                      sourceCount: 0, fetchedAt: fetchedAt)
        }
    }

    public func workoutDetailFetchStatus(workoutKey: String, kind: WorkoutDetailKind) throws -> WorkoutDetailFetchStatus? {
        try syncRead { db in
            guard let row = try Self.fetchStatusRow(db, key: workoutKey, kind: kind),
                  let state = WorkoutDetailFetchStatus.State(rawValue: row["state"]) else { return nil }
            return WorkoutDetailFetchStatus(state: state, fetchedAt: row["fetchedAt"])
        }
    }

    /// Supprime tout le cache (tracé + FC + statuts) d'une séance.
    public func deleteWorkoutDetailCache(workoutKey: String) throws {
        try syncWrite { db in
            for kind in WorkoutDetailKind.allCases { try Self.deletePoints(db, key: workoutKey, kind: kind) }
            try db.execute(sql: "DELETE FROM workout_detail_fetch WHERE workoutKey = ?", arguments: [workoutKey])
        }
    }

    /// Supprime tout le cache de données complémentaires (toutes séances).
    public func deleteAllWorkoutDetailCache() throws {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM workout_route_point")
            try db.execute(sql: "DELETE FROM workout_heart_series")
            try db.execute(sql: "DELETE FROM workout_detail_fetch")
        }
    }

    /// Oublie les statuts « unavailable » (ex. après une nouvelle demande d'autorisation : iOS ne
    /// distinguant pas refus et absence, un « rien trouvé » mémorisé peut venir d'un ancien refus).
    public func forgetUnavailableWorkoutDetails() throws {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM workout_detail_fetch WHERE state = ?",
                           arguments: [WorkoutDetailFetchStatus.State.unavailable.rawValue])
        }
    }

    /// Séance HealthKit importée (lookup par UUID), pour la fenêtre FC.
    public func externalWorkout(id: String) throws -> ExternalWorkout? {
        try syncRead { db in
            try Row.fetchOne(db, sql: "SELECT * FROM external_workout WHERE id = ?", arguments: [id]).map {
                ExternalWorkout(id: $0["id"], source: $0["source"], sportType: $0["sportType"],
                                startDate: $0["startDate"], endDate: $0["endDate"], durationSec: $0["durationSec"],
                                energyKcal: $0["energyKcal"], distanceM: $0["distanceM"],
                                sourceName: $0["sourceName"], importedAt: $0["importedAt"],
                                sourceBundle: $0["sourceBundle"], productType: $0["productType"],
                                deviceModel: $0["deviceModel"])
            }
        }
    }

    private static func deletePoints(_ db: Database, key: String, kind: WorkoutDetailKind) throws {
        let table = kind == .route ? "workout_route_point" : "workout_heart_series"
        try db.execute(sql: "DELETE FROM \(table) WHERE workoutKey = ?", arguments: [key])
    }

    private static func fetchStatusRow(_ db: Database, key: String, kind: WorkoutDetailKind) throws -> Row? {
        try Row.fetchOne(db, sql: "SELECT * FROM workout_detail_fetch WHERE workoutKey = ? AND kind = ?",
                         arguments: [key, kind.rawValue])
    }

    private static func writeFetchStatus(_ db: Database, key: String, kind: WorkoutDetailKind,
                                         state: WorkoutDetailFetchStatus.State, sourceCount: Int,
                                         fetchedAt: Double) throws {
        try db.execute(sql: """
            INSERT OR REPLACE INTO workout_detail_fetch (workoutKey, kind, state, sourceCount, fetchedAt)
            VALUES (?, ?, ?, ?, ?)
            """, arguments: [key, kind.rawValue, state.rawValue, sourceCount, fetchedAt])
    }
}
