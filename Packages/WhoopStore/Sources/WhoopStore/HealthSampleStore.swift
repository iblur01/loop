import Foundation
import GRDB

/// Échantillon Apple Santé générique (quantité ou catégorie). Dates en secondes epoch.
public struct HealthSample: Equatable, Sendable {
    public let uuid: String
    /// Identifiant HK court, ex. "stepCount", "sleepAnalysis".
    public let type: String
    public let startDate: Double
    public let endDate: Double
    public let value: Double?
    public let unit: String
    public let sourceName: String?
    public let sourceBundle: String?
    /// "loop" si l'échantillon a été écrit par Loop (prévu pour l'écriture ; nil sinon).
    public let metadataOrigin: String?
    public let importedAt: Double
    /// `HKSourceRevision.productType` (ex. "Watch6,1", "iPhone15,2"); nil before v15 or unknown.
    public let productType: String?
    /// `HKDevice.model` (ex. "Watch", "iPhone"); nil before v15 or unknown.
    public let deviceModel: String?

    public init(uuid: String, type: String, startDate: Double, endDate: Double, value: Double?,
                unit: String, sourceName: String?, sourceBundle: String?, metadataOrigin: String?,
                importedAt: Double, productType: String? = nil, deviceModel: String? = nil) {
        self.uuid = uuid; self.type = type
        self.startDate = startDate; self.endDate = endDate
        self.value = value; self.unit = unit
        self.sourceName = sourceName; self.sourceBundle = sourceBundle
        self.metadataOrigin = metadataOrigin; self.importedAt = importedAt
        self.productType = productType; self.deviceModel = deviceModel
    }
}

/// Résumé par type pour l'UI : nombre d'échantillons et dernier import.
public struct HealthSampleTypeSummary: Equatable, Sendable {
    public let type: String
    public let count: Int
    public let lastImportedAt: Double?

    public init(type: String, count: Int, lastImportedAt: Double?) {
        self.type = type; self.count = count; self.lastImportedAt = lastImportedAt
    }
}

/// Application qui a écrit des échantillons Santé ; un bundle ne désigne pas un appareil physique.
public struct HealthSampleProducer: Equatable, Sendable {
    public let bundle: String
    public let name: String?

    public init(bundle: String, name: String?) {
        self.bundle = bundle
        self.name = name
    }
}

extension WhoopStore {
    // MARK: - Health samples

    /// Clé d'ancre dans `external_sync_anchor` pour un type. Distincte de l'ancre séances ("healthkit").
    public nonisolated static func healthAnchorSource(type: String) -> String {
        "healthkit:\(type)"
    }

    /// Upsert en lot (une transaction), idempotent sur `uuid`.
    public func upsertHealthSamples(_ samples: [HealthSample]) throws {
        guard !samples.isEmpty else { return }
        try syncWrite { db in try Self.writeHealthSamples(samples, db) }
    }

    /// Suppression par UUID (une transaction). Les UUID inconnus sont ignorés.
    public func deleteHealthSamples(uuids: [String]) throws {
        guard !uuids.isEmpty else { return }
        try syncWrite { db in try Self.removeHealthSamples(uuids, db) }
    }

    /// Échantillons d'un type dont `startDate` est dans [from, to], ordre chronologique.
    public func healthSamples(type: String, from: Double, to: Double) throws -> [HealthSample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM health_sample WHERE type = ? AND startDate >= ? AND startDate <= ?
                ORDER BY startDate ASC
                """, arguments: [type, from, to]).map(Self.healthSample(from:))
        }
    }

    /// Échantillons dont l'intervalle chevauche [from, to), ou points situés dans cette plage.
    public func healthSamplesOverlapping(type: String, from: Double, to: Double) throws -> [HealthSample] {
        guard from.isFinite, to.isFinite, from < to else { return [] }
        return try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM health_sample
                WHERE type = ? AND startDate < ?
                  AND (endDate > ? OR (startDate = endDate AND startDate >= ?))
                ORDER BY startDate ASC
                """, arguments: [type, to, from, from]).map(Self.healthSample(from:))
        }
    }

    public func healthSampleCount(type: String) throws -> Int {
        try syncRead { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM health_sample WHERE type = ?", arguments: [type]) ?? 0
        }
    }

    /// Producteurs identifiés par bundle sur tout l'historique importé pour une métrique.
    /// Le nom seul ne constitue pas une identité stable et les écritures Loop sont exclues.
    public func healthSampleProducers(type: String) throws -> [HealthSampleProducer] {
        try syncRead { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT lower(trim(sourceBundle)) AS bundle, sourceName, MAX(importedAt) AS lastImport
                FROM health_sample
                WHERE type = ? AND sourceBundle IS NOT NULL AND trim(sourceBundle) != ''
                  AND (metadataOrigin IS NULL OR metadataOrigin != 'loop')
                GROUP BY lower(trim(sourceBundle)), sourceName
                ORDER BY bundle, lastImport DESC, sourceName
                """, arguments: [type])
            var seen = Set<String>()
            return rows.compactMap { row in
                let bundle: String = row["bundle"]
                guard !bundle.contains(where: { $0.isWhitespace }), seen.insert(bundle).inserted else { return nil }
                let rawName: String? = row["sourceName"]
                let name = rawName?.trimmingCharacters(in: .whitespacesAndNewlines)
                return HealthSampleProducer(bundle: bundle, name: name?.isEmpty == false ? name : nil)
            }
        }
    }

    /// Nombre d'échantillons des `types` dont `startDate` est dans [from, to] (index type+startDate).
    /// Sert d'empreinte : un import Santé sur un jour marque ce jour à recalculer.
    public func healthSampleCount(types: [String], from: Double, to: Double) throws -> Int {
        guard !types.isEmpty else { return 0 }
        return try syncRead { db in
            var total = 0
            for type in types {
                total += try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM health_sample WHERE type = ? AND startDate >= ? AND startDate <= ?
                    """, arguments: [type, from, to]) ?? 0
            }
            return total
        }
    }

    /// Nombre d'échantillons et dernier `importedAt` par type présent en base.
    public func healthSampleSummaries() throws -> [HealthSampleTypeSummary] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT type, COUNT(*) AS n, MAX(importedAt) AS last FROM health_sample GROUP BY type
                """).map { HealthSampleTypeSummary(type: $0["type"], count: $0["n"], lastImportedAt: $0["last"]) }
        }
    }

    // MARK: - Per-type anchor

    public func healthSyncAnchor(type: String) throws -> Data? {
        try externalSyncAnchor(source: Self.healthAnchorSource(type: type))
    }

    /// Date de dernière synchro réussie par type (`updatedAt` de l'ancre), clé = type court.
    /// Avance à chaque synchro, même sans nouvel échantillon.
    public func healthSyncUpdatedAt() throws -> [String: Double] {
        try syncRead { db in
            let prefix = Self.healthAnchorSource(type: "")
            let rows = try Row.fetchAll(db, sql: "SELECT source, updatedAt FROM external_sync_anchor WHERE source LIKE ?",
                                        arguments: [prefix + "%"])
            var out: [String: Double] = [:]
            for r in rows {
                let source: String = r["source"]
                out[String(source.dropFirst(prefix.count))] = r["updatedAt"]
            }
            return out
        }
    }

    public func setHealthSyncAnchor(type: String, data: Data, updatedAt: Double) throws {
        try setExternalSyncAnchor(source: Self.healthAnchorSource(type: type), data: data, updatedAt: updatedAt)
    }

    /// Applique un lot (upserts + suppressions) et avance l'ancre du type dans UNE transaction :
    /// en cas d'échec rien n'est écrit, l'ancre n'est jamais en avance sur les données.
    public func applyHealthSampleBatch(type: String, upserts: [HealthSample], deletedUUIDs: [String],
                                       anchor: Data, updatedAt: Double) throws {
        try syncWrite { db in
            try Self.writeHealthSamples(upserts, db)
            try Self.removeHealthSamples(deletedUUIDs, db)
            try db.execute(sql: "INSERT OR REPLACE INTO external_sync_anchor (source, anchorData, updatedAt, identityVersion) VALUES (?, ?, ?, \(Self.anchorIdentityVersion))",
                           arguments: [Self.healthAnchorSource(type: type), anchor, updatedAt])
        }
    }

    // MARK: - Helpers

    private static func writeHealthSamples(_ samples: [HealthSample], _ db: Database) throws {
        guard !samples.isEmpty else { return }
        let stmt = try db.cachedStatement(sql: """
            INSERT OR REPLACE INTO health_sample
            (uuid, type, startDate, endDate, value, unit, sourceName, sourceBundle, metadataOrigin, importedAt,
             productType, deviceModel)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                    COALESCE(?, (SELECT productType FROM health_sample WHERE uuid = ?)),
                    COALESCE(?, (SELECT deviceModel FROM health_sample WHERE uuid = ?)))
            """)
        for s in samples {
            try stmt.execute(arguments: [s.uuid, s.type, s.startDate, s.endDate, s.value, s.unit,
                                         s.sourceName, s.sourceBundle, s.metadataOrigin, s.importedAt,
                                         s.productType, s.uuid, s.deviceModel, s.uuid])
        }
    }

    private static func removeHealthSamples(_ uuids: [String], _ db: Database) throws {
        guard !uuids.isEmpty else { return }
        let stmt = try db.cachedStatement(sql: "DELETE FROM health_sample WHERE uuid = ?")
        for id in uuids { try stmt.execute(arguments: [id]) }
    }

    private static func healthSample(from r: Row) -> HealthSample {
        HealthSample(uuid: r["uuid"], type: r["type"], startDate: r["startDate"], endDate: r["endDate"],
                     value: r["value"], unit: r["unit"], sourceName: r["sourceName"],
                     sourceBundle: r["sourceBundle"], metadataOrigin: r["metadataOrigin"],
                     importedAt: r["importedAt"], productType: r["productType"],
                     deviceModel: r["deviceModel"])
    }
}
