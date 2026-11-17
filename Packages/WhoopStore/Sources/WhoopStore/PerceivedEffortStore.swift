import Foundation
import GRDB

/// RPE (perception d'effort, échelle 1-10) saisi par l'utilisateur pour une séance.
/// Stockage et lecture uniquement : aucun calcul de charge ici.
public struct WorkoutPerceivedEffort: Equatable, Sendable {
    public static let rpeRange = 1...10
    public static let maxNoteLength = 140

    /// Identifiant stable de la séance (ex. "external:<uuid>").
    public let workoutId: String
    public let rpe: Int
    /// Date de saisie, en secondes epoch.
    public let recordedAt: Double
    public let note: String?

    /// Retourne nil si l'identifiant est vide ou si le RPE est hors 1...10.
    /// La note est nettoyée (espaces) et tronquée à `maxNoteLength` ; une note vide devient nil.
    public init?(workoutId: String, rpe: Int, recordedAt: Double, note: String? = nil) {
        guard !workoutId.isEmpty, Self.rpeRange.contains(rpe) else { return nil }
        self.workoutId = workoutId
        self.rpe = rpe
        self.recordedAt = recordedAt
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.note = trimmed.isEmpty ? nil : String(trimmed.prefix(Self.maxNoteLength))
    }
}

extension WhoopStore {
    /// Insère ou remplace le RPE de la séance (une seule valeur par séance).
    public func upsertPerceivedEffort(_ e: WorkoutPerceivedEffort) throws {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO workout_perceived_effort (workoutId, rpe, recordedAt, note)
                VALUES (?, ?, ?, ?)
                """, arguments: [e.workoutId, e.rpe, e.recordedAt, e.note])
        }
    }

    public func perceivedEffort(workoutId: String) throws -> WorkoutPerceivedEffort? {
        try syncRead { db in
            try Row.fetchOne(db, sql: "SELECT * FROM workout_perceived_effort WHERE workoutId = ?",
                             arguments: [workoutId]).flatMap(Self.perceivedEffort(from:))
        }
    }

    /// Lecture en lot (clés absentes = pas de RPE saisi).
    public func perceivedEfforts(workoutIds: [String]) throws -> [String: WorkoutPerceivedEffort] {
        guard !workoutIds.isEmpty else { return [:] }
        return try syncRead { db in
            var out: [String: WorkoutPerceivedEffort] = [:]
            // Découpe pour rester sous la limite de variables SQLite.
            for chunk in stride(from: 0, to: workoutIds.count, by: 500).map({ Array(workoutIds[$0..<min($0 + 500, workoutIds.count)]) }) {
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let rows = try Row.fetchAll(db, sql: "SELECT * FROM workout_perceived_effort WHERE workoutId IN (\(marks))",
                                            arguments: StatementArguments(chunk))
                for r in rows { if let e = Self.perceivedEffort(from: r) { out[e.workoutId] = e } }
            }
            return out
        }
    }

    /// Saisies dont `recordedAt` est dans [from, to], les plus récentes d'abord.
    public func perceivedEfforts(recordedFrom from: Double, to: Double) throws -> [WorkoutPerceivedEffort] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM workout_perceived_effort WHERE recordedAt >= ? AND recordedAt <= ?
                ORDER BY recordedAt DESC
                """, arguments: [from, to]).compactMap(Self.perceivedEffort(from:))
        }
    }

    public func deletePerceivedEffort(workoutId: String) throws {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM workout_perceived_effort WHERE workoutId = ?", arguments: [workoutId])
        }
    }

    private static func perceivedEffort(from r: Row) -> WorkoutPerceivedEffort? {
        WorkoutPerceivedEffort(workoutId: r["workoutId"], rpe: r["rpe"], recordedAt: r["recordedAt"], note: r["note"])
    }
}

/// Façade dédiée au RPE par séance. La table vit dans `whoop.sqlite` : elle est donc incluse
/// telle quelle dans le snapshot `.loopbackup` (BackupCoordinator copie la base entière).
public struct PerceivedEffortStore: Sendable {
    private let store: WhoopStore

    public init(store: WhoopStore) { self.store = store }

    /// Enregistre (ou remplace) le RPE. Lève `invalidRPE` hors 1...10.
    @discardableResult
    public func save(workoutId: String, rpe: Int, note: String? = nil, now: Date = Date()) async throws -> WorkoutPerceivedEffort {
        guard let e = WorkoutPerceivedEffort(workoutId: workoutId, rpe: rpe,
                                             recordedAt: now.timeIntervalSince1970, note: note) else {
            throw StoreError.invalidRPE
        }
        try await store.upsertPerceivedEffort(e)
        return e
    }

    public func get(workoutId: String) async throws -> WorkoutPerceivedEffort? {
        try await store.perceivedEffort(workoutId: workoutId)
    }

    public func get(workoutIds: [String]) async throws -> [String: WorkoutPerceivedEffort] {
        try await store.perceivedEfforts(workoutIds: workoutIds)
    }

    public func list(recordedFrom: Double, to: Double) async throws -> [WorkoutPerceivedEffort] {
        try await store.perceivedEfforts(recordedFrom: recordedFrom, to: to)
    }

    public func delete(workoutId: String) async throws {
        try await store.deletePerceivedEffort(workoutId: workoutId)
    }

    public enum StoreError: Error, Equatable { case invalidRPE }
}
