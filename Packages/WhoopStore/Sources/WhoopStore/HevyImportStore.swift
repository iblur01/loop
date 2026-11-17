import Foundation
import GRDB

// MARK: - Import d'un export CSV Hevy
//
// Une séance Hevy est une ligne `external_workout` ordinaire (aucune table ni colonne nouvelle) :
// le moteur, la fusion multisource (`WorkoutCanonicalization`, règle 50 % / 70 %) et le rapport
// d'entraînement la lisent comme une séance Santé « autre source ». Son origine est portée par
// `sourceBundle`, que ni l'import Santé ni la saisie manuelle n'écrivent avec cette valeur.
// Ni volume, ni exercices, ni RPE ne sont stockés : l'export n'a pas de RPE et Loop n'en invente
// jamais (aucune ligne `workout_perceived_effort`).

public enum HevyImport {
    /// Valeur de `external_workout.source` des séances importées depuis un export Hevy.
    public static let source = "hevy"
    public static let sourceName = "Hevy"
    public static let sourceBundle = "com.hevy.csv"
    /// `HKWorkoutActivityType.traditionalStrengthTraining` (musculation).
    public static let sportType = 50
    /// Une séance déjà présente dont le début est à ± cet écart est la même séance (mise à jour).
    public static let matchToleranceSeconds: Double = 60

    public static func isHevy(_ w: ExternalWorkout) -> Bool { w.sourceBundle == sourceBundle }

    /// Clé UserDefaults du fuseau d'interprétation des dates de l'export (identifiant IANA).
    public static let timeZoneDefaultsKey = "loop.hevy.importTimeZone"

    /// Fuseau des imports : celui mémorisé au premier import, sinon `deviceTimeZone`, alors
    /// mémorisé. L'export n'a pas de fuseau ; le garder fixe rend les ré-imports stables.
    public static func importTimeZone(defaults: UserDefaults, deviceTimeZone: TimeZone) -> TimeZone {
        if let id = defaults.string(forKey: timeZoneDefaultsKey), let zone = TimeZone(identifier: id) { return zone }
        defaults.set(deviceTimeZone.identifier, forKey: timeZoneDefaultsKey)
        return deviceTimeZone
    }

    /// « hevy: » + début arrondi à la minute (epoch UTC entier).
    public static func id(start: Date) -> String {
        "hevy:\(Int((start.timeIntervalSince1970 / 60).rounded()) * 60)"
    }

    public static func workout(from s: HevySession, importedAt: Date) -> ExternalWorkout {
        let start = s.start.timeIntervalSince1970, end = s.end.timeIntervalSince1970
        return ExternalWorkout(id: id(start: s.start), source: source, sportType: sportType,
                               startDate: start, endDate: end, durationSec: end - start,
                               energyKcal: nil, distanceM: nil, sourceName: sourceName,
                               importedAt: importedAt.timeIntervalSince1970, sourceBundle: sourceBundle)
    }
}

/// Bilan d'un import.
public struct HevyImportReport: Equatable, Sendable {
    /// Séances nouvellement créées.
    public var inserted = 0
    /// Séances déjà présentes dont la fin a changé (mises à jour, id conservé).
    public var updated = 0
    /// Séances déjà présentes et identiques, ou répétées dans le même fichier.
    public var duplicates = 0
    /// Lignes CSV ignorées par le parseur.
    public var skippedRows = 0

    public init(inserted: Int = 0, updated: Int = 0, duplicates: Int = 0, skippedRows: Int = 0) {
        self.inserted = inserted; self.updated = updated; self.duplicates = duplicates; self.skippedRows = skippedRows
    }
}

extension WhoopStore {
    /// Écrit les séances dans UNE transaction. Une séance Hevy déjà en base (même `sourceBundle`,
    /// début à moins de 60 s, bornes exclues) est mise à jour (fin, durée) en gardant son id ;
    /// sinon elle est insérée. Deux débuts à 12:22 et 12:23 restent deux séances. Rien n'est
    /// jamais supprimé : une séance absente du nouvel export reste en base. Un id `hevy:` déjà
    /// porté par une ligne d'une autre source fait échouer et annuler tout l'import.
    public func importHevySessions(_ sessions: [HevySession], skippedRows: Int = 0,
                                   now: Date = Date()) throws -> HevyImportReport {
        var report = HevyImportReport(skippedRows: skippedRows)
        let tol = HevyImport.matchToleranceSeconds
        try syncWrite { db in
            var seenStarts: [Double] = []
            for s in sessions {
                let w = HevyImport.workout(from: s, importedAt: now)
                if seenStarts.contains(where: { abs($0 - w.startDate) < tol }) {
                    report.duplicates += 1
                    continue
                }
                seenStarts.append(w.startDate)
                let existing = try Row.fetchOne(db, sql: """
                    SELECT id, startDate, endDate FROM external_workout
                    WHERE sourceBundle = ? AND startDate > ? AND startDate < ?
                    ORDER BY abs(startDate - ?) ASC, id ASC LIMIT 1
                    """, arguments: [HevyImport.sourceBundle, w.startDate - tol, w.startDate + tol, w.startDate])
                if let existing {
                    let id: String = existing["id"]
                    let oldEnd: Double = existing["endDate"]
                    let oldStart: Double = existing["startDate"]
                    if oldEnd == w.endDate || w.endDate <= oldStart {
                        report.duplicates += 1
                    } else {
                        // Début et id existants conservés ; durée = fin − début.
                        try db.execute(sql: """
                            UPDATE external_workout SET endDate = ?, durationSec = ? - startDate WHERE id = ?
                            """, arguments: [w.endDate, w.endDate, id])
                        report.updated += 1
                    }
                } else {
                    try db.execute(sql: """
                        INSERT INTO external_workout
                        (id, source, sportType, startDate, endDate, durationSec, energyKcal, distanceM, sourceName, importedAt,
                         sourceBundle, productType, deviceModel)
                        VALUES (?, ?, ?, ?, ?, ?, NULL, NULL, ?, ?, ?, NULL, NULL)
                        """, arguments: [w.id, w.source, w.sportType, w.startDate, w.endDate, w.durationSec,
                                         w.sourceName, w.importedAt, w.sourceBundle])
                    report.inserted += 1
                }
            }
        }
        return report
    }
}

/// Façade d'import : texte CSV -> séances -> `external_workout`.
public struct HevyImportStore: Sendable {
    private let store: WhoopStore

    public init(store: WhoopStore) { self.store = store }

    /// Analyse puis importe dans le fuseau mémorisé au premier import (`HevyImport.importTimeZone`),
    /// pour qu'un ré-import après un voyage ne décale pas les heures et ne crée pas de doublons.
    public func importCSV(_ text: String, defaults: UserDefaults, deviceTimeZone: TimeZone = .current,
                          now: Date = Date()) async throws -> HevyImportReport {
        let zone = HevyImport.importTimeZone(defaults: defaults, deviceTimeZone: deviceTimeZone)
        return try await importCSV(text, timeZone: zone, now: now)
    }

    /// Analyse puis importe. Lève `HevyCSVParser.ParseError` si le fichier n'est pas un export Hevy.
    public func importCSV(_ text: String, timeZone: TimeZone = .current, now: Date = Date()) async throws -> HevyImportReport {
        let parsed = try HevyCSVParser.parse(text, timeZone: timeZone)
        return try await store.importHevySessions(parsed.sessions, skippedRows: parsed.skippedRows, now: now)
    }
}
