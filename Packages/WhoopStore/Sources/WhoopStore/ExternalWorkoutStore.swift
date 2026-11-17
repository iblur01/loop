import Foundation
import GRDB

/// Séance importée d'une source externe (v1 : Apple Santé). Dates en secondes epoch.
public struct ExternalWorkout: Equatable, Sendable {
    public let id: String
    public let source: String
    public let sportType: Int
    public let startDate: Double
    public let endDate: Double
    public let durationSec: Double
    public let energyKcal: Double?
    public let distanceM: Double?
    public let sourceName: String?
    public let importedAt: Double
    /// Bundle of the producing HealthKit app; nil for records imported before v14.
    public let sourceBundle: String?
    /// `HKSourceRevision.productType` (ex. "Watch6,1"); nil for records imported before v15.
    public let productType: String?
    /// `HKDevice.model` (ex. "Watch"); nil for records imported before v15 or unknown device.
    public let deviceModel: String?

    public init(id: String, source: String, sportType: Int, startDate: Double, endDate: Double,
                durationSec: Double, energyKcal: Double?, distanceM: Double?,
                sourceName: String?, importedAt: Double, sourceBundle: String? = nil,
                productType: String? = nil, deviceModel: String? = nil) {
        self.id = id; self.source = source; self.sportType = sportType
        self.startDate = startDate; self.endDate = endDate; self.durationSec = durationSec
        self.energyKcal = energyKcal; self.distanceM = distanceM
        self.sourceName = sourceName; self.importedAt = importedAt; self.sourceBundle = sourceBundle
        self.productType = productType; self.deviceModel = deviceModel
    }
}

extension WhoopStore {
    /// Anchors written before this version (v15: device identity columns) are ignored once, so the
    /// next HealthKit sync re-reads the full history and fills `productType` / `deviceModel`.
    /// The stored anchor row is kept; it is simply overwritten by the next successful sync.
    static let anchorIdentityVersion = 1

    // MARK: - External workouts

    /// Upsert en lot, idempotent sur `id`.
    public func upsertExternalWorkouts(_ workouts: [ExternalWorkout]) throws {
        guard !workouts.isEmpty else { return }
        try syncWrite { db in
            for w in workouts {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO external_workout
                    (id, source, sportType, startDate, endDate, durationSec, energyKcal, distanceM, sourceName, importedAt, sourceBundle,
                     productType, deviceModel)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, COALESCE(?, (SELECT sourceBundle FROM external_workout WHERE id = ?)),
                            COALESCE(?, (SELECT productType FROM external_workout WHERE id = ?)),
                            COALESCE(?, (SELECT deviceModel FROM external_workout WHERE id = ?)))
                    """,
                    arguments: [w.id, w.source, w.sportType, w.startDate, w.endDate, w.durationSec,
                                w.energyKcal, w.distanceM, w.sourceName, w.importedAt, w.sourceBundle, w.id,
                                w.productType, w.id, w.deviceModel, w.id])
            }
        }
    }

    public func deleteExternalWorkouts(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try syncWrite { db in
            for id in ids {
                try db.execute(sql: "DELETE FROM external_workout WHERE id = ?", arguments: [id])
            }
        }
    }

    /// Séances dont `startDate` est dans [from, to], les plus récentes d'abord.
    public func externalWorkouts(from: Double, to: Double, source: String? = nil) throws -> [ExternalWorkout] {
        try syncRead { db in
            var sql = "SELECT * FROM external_workout WHERE startDate >= ? AND startDate <= ?"
            var args: [DatabaseValueConvertible?] = [from, to]
            if let source { sql += " AND source = ?"; args.append(source) }
            sql += " ORDER BY startDate DESC"
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map(Self.externalWorkout(from:))
        }
    }

    /// Séances qui RECOUPENT [from, to] (fin ≥ from et début ≤ to), les plus récentes d'abord.
    /// Une séance à cheval sur minuit local est ainsi vue par les deux jours. `maxDuration`
    /// borne la recherche indexée sur `startDate` (séances plus longues ignorées).
    public func externalWorkouts(overlapping from: Double, to: Double,
                                 maxDuration: Double = 2 * 86_400) throws -> [ExternalWorkout] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM external_workout
                WHERE startDate >= ? AND startDate <= ? AND endDate >= ?
                ORDER BY startDate DESC
                """, arguments: [from - maxDuration, to, from]).map(Self.externalWorkout(from:))
        }
    }

    public func externalWorkoutCount(source: String? = nil) throws -> Int {
        try syncRead { db in
            if let source {
                return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM external_workout WHERE source = ?",
                                        arguments: [source]) ?? 0
            }
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM external_workout") ?? 0
        }
    }

    // MARK: - Sync anchor

    public func externalSyncAnchor(source: String) throws -> Data? {
        try syncRead { db in
            try Data.fetchOne(db, sql: """
                SELECT anchorData FROM external_sync_anchor
                WHERE source = ? AND identityVersion >= \(Self.anchorIdentityVersion)
                """,
                              arguments: [source])
        }
    }

    public func setExternalSyncAnchor(source: String, data: Data, updatedAt: Double) throws {
        try syncWrite { db in
            try db.execute(sql: "INSERT OR REPLACE INTO external_sync_anchor (source, anchorData, updatedAt, identityVersion) VALUES (?, ?, ?, \(Self.anchorIdentityVersion))",
                           arguments: [source, data, updatedAt])
        }
    }

    /// Applique un lot (upserts + suppressions) et avance l'ancre dans UNE transaction :
    /// en cas d'échec rien n'est écrit, l'ancre n'est donc jamais en avance sur les données.
    public func applyExternalWorkoutBatch(source: String, upserts: [ExternalWorkout], deletedIds: [String],
                                          anchor: Data, updatedAt: Double) throws {
        try syncWrite { db in
            for w in upserts {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO external_workout
                    (id, source, sportType, startDate, endDate, durationSec, energyKcal, distanceM, sourceName, importedAt, sourceBundle,
                     productType, deviceModel)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, COALESCE(?, (SELECT sourceBundle FROM external_workout WHERE id = ?)),
                            COALESCE(?, (SELECT productType FROM external_workout WHERE id = ?)),
                            COALESCE(?, (SELECT deviceModel FROM external_workout WHERE id = ?)))
                    """,
                    arguments: [w.id, w.source, w.sportType, w.startDate, w.endDate, w.durationSec,
                                w.energyKcal, w.distanceM, w.sourceName, w.importedAt, w.sourceBundle, w.id,
                                w.productType, w.id, w.deviceModel, w.id])
            }
            for id in deletedIds {
                try db.execute(sql: "DELETE FROM external_workout WHERE id = ?", arguments: [id])
            }
            try db.execute(sql: "INSERT OR REPLACE INTO external_sync_anchor (source, anchorData, updatedAt, identityVersion) VALUES (?, ?, ?, \(Self.anchorIdentityVersion))",
                           arguments: [source, anchor, updatedAt])
        }
    }

    private static func externalWorkout(from r: Row) -> ExternalWorkout {
        ExternalWorkout(id: r["id"], source: r["source"], sportType: r["sportType"],
                        startDate: r["startDate"], endDate: r["endDate"], durationSec: r["durationSec"],
                        energyKcal: r["energyKcal"], distanceM: r["distanceM"],
                        sourceName: r["sourceName"], importedAt: r["importedAt"], sourceBundle: r["sourceBundle"],
                        productType: r["productType"], deviceModel: r["deviceModel"])
    }
}
