import Foundation
import GRDB

// MARK: - Séance saisie à la main
//
// Une séance manuelle est une ligne `external_workout` ordinaire (aucune table ni colonne
// nouvelle) : le moteur, la fusion multisource et le rapport d'entraînement la lisent comme
// n'importe quelle séance Santé. Son origine est portée par `sourceBundle`, que l'import Santé
// n'écrit jamais avec cette valeur. Le RPE vit dans `workout_perceived_effort` sous la clé
// `external:<id>`, comme pour une séance Santé.

/// Sports proposés à la saisie ; `rawValue` = code `HKWorkoutActivityType` (lu tel quel par
/// `TrainingInputsAdapter.sport(kind:sportType:)` et `WorkoutCanonicalization`).
public enum ManualWorkoutSport: Int, CaseIterable, Sendable {
    case run = 37
    case swim = 46
    case strength = 50
    /// `HKWorkoutActivityType.other` : compatible avec tout sport pour la fusion.
    case other = 3000
}

public enum ManualWorkout {
    /// Valeur de `external_workout.source` des saisies manuelles (distincte de "healthkit").
    public static let source = "manual"
    public static let sourceName = "Saisie manuelle"
    /// Seule marque d'origine fiable : la suppression manuelle n'agit que sur ces lignes.
    public static let sourceBundle = "com.iblur01.loop.manual"
    /// Durée saisissable, en minutes, par pas de `durationStepMinutes`.
    public static let durationMinutesRange = 5...300
    public static let durationStepMinutes = 5
    /// Tolérance d'horloge sur la fin : une séance doit être terminée (fin ≤ maintenant + 60 s).
    public static let futureToleranceSeconds: Double = 60

    /// Vrai si la ligne a été saisie dans Loop (et non importée d'Apple Santé).
    public static func isManual(_ w: ExternalWorkout) -> Bool {
        w.sourceBundle == sourceBundle
    }

    public static func isValidDuration(_ minutes: Int) -> Bool {
        durationMinutesRange.contains(minutes) && minutes % durationStepMinutes == 0
    }

    /// Raison du refus d'une saisie, nil si elle est acceptable : durée multiple de 5 entre 5 et
    /// 300 min, début fini, fin ≤ `now` + 60 s (donc début ≤ maintenant).
    public static func validationError(start: Date, durationMinutes: Int, now: Date) -> ManualWorkoutStore.StoreError? {
        guard isValidDuration(durationMinutes) else { return .invalidDuration }
        let startTs = start.timeIntervalSince1970
        guard startTs.isFinite else { return .invalidStart }
        let end = startTs + Double(durationMinutes * 60)
        guard end <= now.timeIntervalSince1970 + futureToleranceSeconds else { return .endsInFuture }
        return nil
    }

    /// Construit la ligne d'une saisie ; nil si `validationError` la refuse.
    public static func make(id: String = UUID().uuidString, sport: ManualWorkoutSport, start: Date,
                            durationMinutes: Int, now: Date = Date()) -> ExternalWorkout? {
        guard validationError(start: start, durationMinutes: durationMinutes, now: now) == nil else { return nil }
        let startTs = start.timeIntervalSince1970
        let duration = Double(durationMinutes * 60)
        return ExternalWorkout(id: id, source: source, sportType: sport.rawValue,
                               startDate: startTs, endDate: startTs + duration, durationSec: duration,
                               energyKcal: nil, distanceM: nil, sourceName: sourceName,
                               importedAt: now.timeIntervalSince1970, sourceBundle: sourceBundle)
    }

    /// Clé RPE de la séance (même règle que pour une séance Santé).
    public static func perceivedEffortKey(id: String) -> String {
        WorkoutPerceivedEffort.workoutKey(externalID: id, deviceId: source, startTs: 0)
    }
}

// Relecture par id : `externalWorkout(id:)` (WorkoutDetailCache.swift).
extension WhoopStore {
    /// Écrit la séance et son RPE dans UNE transaction : le recalcul déclenché par l'insertion
    /// (trigger `input_revision`) trouve toujours le RPE déjà présent, et un échec n'écrit rien.
    /// INSERT simple : un id déjà présent (ligne Santé, montre ou autre saisie) fait échouer la
    /// transaction au lieu de l'écraser.
    public func saveManualWorkout(_ w: ExternalWorkout, effort: WorkoutPerceivedEffort?) throws {
        guard ManualWorkout.isManual(w) else { throw ManualWorkoutStore.StoreError.notManual }
        if let effort, effort.workoutId != ManualWorkout.perceivedEffortKey(id: w.id) {
            throw ManualWorkoutStore.StoreError.invalidRPE
        }
        try syncWrite { db in
            if let effort {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO workout_perceived_effort (workoutId, rpe, recordedAt, note)
                    VALUES (?, ?, ?, ?)
                    """, arguments: [effort.workoutId, effort.rpe, effort.recordedAt, effort.note])
            }
            try db.execute(sql: """
                INSERT INTO external_workout
                (id, source, sportType, startDate, endDate, durationSec, energyKcal, distanceM, sourceName, importedAt,
                 sourceBundle, productType, deviceModel)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL)
                """, arguments: [w.id, w.source, w.sportType, w.startDate, w.endDate, w.durationSec,
                                 w.energyKcal, w.distanceM, w.sourceName, w.importedAt, w.sourceBundle])
        }
    }

    /// Supprime une séance saisie à la main et son RPE. Une ligne importée (autre `sourceBundle`)
    /// n'est jamais touchée. Retourne false si aucune séance manuelle ne porte cet id.
    @discardableResult
    public func deleteManualWorkout(id: String) throws -> Bool {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM external_workout WHERE id = ? AND sourceBundle = ?",
                           arguments: [id, ManualWorkout.sourceBundle])
            guard db.changesCount > 0 else { return false }
            try db.execute(sql: "DELETE FROM workout_perceived_effort WHERE workoutId = ?",
                           arguments: [ManualWorkout.perceivedEffortKey(id: id)])
            return true
        }
    }
}

/// Façade de saisie manuelle, sur le modèle de `PerceivedEffortStore`.
public struct ManualWorkoutStore: Sendable {
    private let store: WhoopStore

    public init(store: WhoopStore) { self.store = store }

    /// Enregistre une séance et son RPE (1...10, note facultative tronquée à 140 caractères).
    /// Tout est validé avant l'écriture ; l'écriture elle-même est atomique.
    @discardableResult
    public func save(sport: ManualWorkoutSport, start: Date, durationMinutes: Int, rpe: Int,
                     note: String? = nil, id: String = UUID().uuidString, now: Date = Date()) async throws -> ExternalWorkout {
        if let error = ManualWorkout.validationError(start: start, durationMinutes: durationMinutes, now: now) {
            throw error
        }
        guard let w = ManualWorkout.make(id: id, sport: sport, start: start, durationMinutes: durationMinutes, now: now)
        else { throw StoreError.invalidDuration }
        guard let effort = WorkoutPerceivedEffort(workoutId: ManualWorkout.perceivedEffortKey(id: w.id), rpe: rpe,
                                                  recordedAt: now.timeIntervalSince1970, note: note)
        else { throw StoreError.invalidRPE }
        try await store.saveManualWorkout(w, effort: effort)
        return w
    }

    public func get(id: String) async throws -> ExternalWorkout? {
        try await store.externalWorkout(id: id)
    }

    /// Vrai seulement pour une séance saisie dans Loop.
    public func isManual(id: String) async -> Bool {
        guard let w = try? await store.externalWorkout(id: id) else { return false }
        return ManualWorkout.isManual(w)
    }

    @discardableResult
    public func delete(id: String) async throws -> Bool {
        try await store.deleteManualWorkout(id: id)
    }

    public enum StoreError: Error, Equatable { case invalidDuration, invalidStart, endsInFuture, invalidRPE, notManual }
}
