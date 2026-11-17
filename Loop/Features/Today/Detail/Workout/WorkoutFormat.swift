import Foundation
import LoopStrapEngine
import WhoopStore

/// Libellés et formats d'une séance (pur, sans vue). Une mesure absente ou non physiologique
/// ne produit aucune tuile : jamais de 0 ni de valeur estimée à la place d'une donnée manquante.
enum WorkoutFormat {
    /// Nom français du type, depuis le mapping unique `WorkoutSport` (jamais de libellé brut).
    static func title(_ s: WorkoutSession) -> String { sport(s).title }

    /// Symbole SF du type, depuis `WorkoutSport`.
    static func symbol(_ s: WorkoutSession) -> String { sport(s).symbol }

    static func sport(_ s: WorkoutSession) -> WorkoutSport { WorkoutSport(kind: s.kind, sportType: s.sportType) }

    /// Durée en secondes : durée déclarée par la source, sinon bornes de la séance. nil si ≤ 0.
    static func durationSeconds(_ s: WorkoutSession) -> Int? {
        let seconds = s.durationS ?? (s.endTs - s.startTs)
        return seconds > 0 ? seconds : nil
    }

    static func duration(_ s: WorkoutSession) -> String? {
        guard let seconds = durationSeconds(s) else { return nil }
        let minutes = Int((Double(seconds) / 60).rounded())
        return minutes >= 60 ? "\(minutes / 60) h \(String(format: "%02d", minutes % 60))" : "\(minutes) min"
    }

    static func timeRange(_ s: WorkoutSession) -> String {
        let start = Date(timeIntervalSince1970: Double(s.startTs))
        let end = Date(timeIntervalSince1970: Double(s.endTs))
        let day = start.formatted(.dateTime.weekday(.wide).day().month(.wide))
        let from = start.formatted(.dateTime.hour().minute())
        let to = end.formatted(.dateTime.hour().minute())
        return "\(day) · \(from)–\(to)"
    }

    // MARK: - Tuiles

    /// Tuiles de la grille, dans l'ordre d'affichage. Seules les mesures présentes apparaissent.
    static func metrics(_ s: WorkoutSession) -> [WorkoutMetric] {
        var out: [WorkoutMetric] = []
        let seconds = durationSeconds(s)
        let distance = s.distanceM.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }

        if let distance {
            let km = decimal(distance / 1000, digits: 2)
            out.append(WorkoutMetric(id: "distance", label: "Distance", value: km, unit: "km",
                                     spokenUnit: TodayL.text("today.final.workout.kilometers")))
        }
        // Allure : course uniquement, dérivée de deux mesures (distance et durée), jamais estimée.
        if TrainingInputsAdapter.sport(kind: s.kind, sportType: s.sportType) == .run,
           let distance, let seconds, distance >= 100,
           let pace = pace(secondsPerKm: Double(seconds) / (distance / 1000)) {
            out.append(WorkoutMetric(id: "pace", label: "Allure", value: pace.text, unit: "min/km",
                                     spokenValue: pace.spoken, spokenUnit: TodayL.text("today.final.workout.per.kilometer")))
        }
        if let seconds {
            let minutes = Int((Double(seconds) / 60).rounded())
            if minutes >= 60 {
                out.append(WorkoutMetric(id: "duration", label: String(localized: "today.duree", table: "Today"),
                                         value: "\(minutes / 60) h \(String(format: "%02d", minutes % 60))", unit: nil,
                                         spokenValue: "\(minutes / 60) heures \(minutes % 60) minutes"))
            } else {
                out.append(WorkoutMetric(id: "duration", label: String(localized: "today.duree", table: "Today"), value: "\(minutes)", unit: "min",
                                         spokenUnit: "minutes"))
            }
        }
        if let kcal = s.caloriesKcal, kcal.isFinite, kcal > 0 {
            out.append(WorkoutMetric(id: "energy", label: String(localized: "today.energie", table: "Today"), value: "\(Int(kcal.rounded()))", unit: "kcal",
                                     spokenUnit: "kilocalories"))
        }
        if let hr = s.avgHr, hr.isFinite, hr > 0 {
            out.append(WorkoutMetric(id: "avgHr", label: String(localized: "today.fc.moyenne", table: "Today"), value: "\(Int(hr.rounded()))", unit: "bpm",
                                     spokenUnit: "battements par minute"))
        }
        if let peak = s.peakHr, peak > 0 {
            out.append(WorkoutMetric(id: "peakHr", label: "FC max", value: "\(peak)", unit: "bpm",
                                     spokenUnit: "battements par minute"))
        }
        if let strain = s.strain, strain.isFinite, strain >= 0 {
            out.append(WorkoutMetric(id: "strain", label: String(localized: "today.charge.cardio", table: "Today"), value: decimal(strain, digits: 1),
                                     unit: "/ 21", spokenUnit: TodayL.text("today.remaining.score.out.of.21")))
        }
        return out
    }

    /// Source déclarée de la séance : app ou appareil Santé, sinon détection par le bracelet.
    static func source(_ s: WorkoutSession) -> String {
        if s.externalID != nil {
            // `WorkoutSession` ne porte pas `sourceBundle` : la saisie manuelle est reconnue à son
            // nom stocké, constant et jamais écrit par l'import Santé. Affichage seulement ; la
            // suppression, elle, vérifie le bundle sur la ligne stockée.
            if s.sourceName == ManualWorkout.sourceName { return ManualWorkoutL.text("manualWorkout.source") }
            if let name = s.sourceName?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
            return String(localized: "today.apple.sante", table: "Today")
        }
        return String(localized: "today.detectee.par.le.bracelet", table: "Today")
    }

    // MARK: - Helpers

    static func decimal(_ value: Double, digits: Int) -> String {
        String(format: "%.\(digits)f", value).replacingOccurrences(of: ".", with: ",")
    }

    /// Allure m:ss par km ; nil hors plage plausible (2 à 30 min/km) pour ne rien afficher d'absurde.
    static func pace(secondsPerKm: Double) -> (text: String, spoken: String)? {
        guard secondsPerKm.isFinite, (120...1800).contains(secondsPerKm) else { return nil }
        let total = Int(secondsPerKm.rounded())
        let m = total / 60, sec = total % 60
        return ("\(m):\(String(format: "%02d", sec))", "\(m) minutes \(sec) secondes")
    }
}

/// Une tuile de mesure : valeur affichée, unité visuelle et énoncé VoiceOver (valeur + unité).
struct WorkoutMetric: Identifiable, Equatable {
    let id: String
    let label: String
    let value: String
    let unit: String?
    var spokenValue: String? = nil
    var spokenUnit: String? = nil

    var accessibilityValue: String {
        [spokenValue ?? value, spokenUnit].compactMap { $0 }.joined(separator: " ")
    }
}
