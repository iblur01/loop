import SwiftUI

/// Présentation d'un type de séance : nom français, SF Symbol et teinte, au même endroit pour
/// toute l'app (séances du jour, journée, chronologie). Ne lit que `kind` / `sportType` déjà
/// stockés : aucune donnée n'est modifiée. Les teintes viennent des tokens (`Metric`), la teinte
/// est toujours accompagnée du nom et de l'icône.
struct WorkoutSport: Equatable {
    enum Kind: String, CaseIterable {
        case run, walk, cycling, swim, strength, core, yoga, pilates, hiit, crossfit, hike, rowing
        case elliptical, basketball, football, tennis, pickleball, boxing, martialArts, climbing
        case jumpRope, mixedCardio, detectedCardio, other
    }

    let kind: Kind

    /// Libellé brut d'origine, gardé pour une activité non reconnue.
    private let rawTitle: String?

    init(kind rawKind: String?, sportType: Int? = nil) {
        let raw = rawKind?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Le type Apple Santé (HKWorkoutActivityType) prime sur le libellé stocké.
        let source = sportType.map { HealthWorkoutCanonicalizer.kind(for: $0) } ?? raw
        let resolved = Self.kind(for: source)
        let fallback = resolved == .other ? Self.kind(for: raw) : resolved
        kind = fallback
        if fallback == .other, let raw, !raw.isEmpty, Self.normalize(raw) != Self.normalize("Séance Apple Santé") {
            rawTitle = raw.replacingOccurrences(of: "_", with: " ").capitalized
        } else {
            rawTitle = nil
        }
    }

    /// Compatibilité : libellé seul (chronologie de l'accueil).
    init(rawKind: String?) { self.init(kind: rawKind, sportType: nil) }

    var title: String {
        switch kind {
        case .run: return String(localized: "workout.sport.run", table: "Core")
        case .walk: return String(localized: "workout.sport.walk", table: "Core")
        case .cycling: return String(localized: "workout.sport.cycling", table: "Core")
        case .swim: return String(localized: "workout.sport.swim", table: "Core")
        case .strength: return String(localized: "workout.sport.strength", table: "Core")
        case .core: return String(localized: "workout.sport.core", table: "Core")
        case .yoga: return "Yoga"
        case .pilates: return "Pilates"
        case .hiit: return "HIIT"
        case .crossfit: return "CrossFit"
        case .hike: return String(localized: "workout.sport.hike", table: "Core")
        case .rowing: return String(localized: "workout.sport.rowing", table: "Core")
        case .elliptical: return String(localized: "workout.sport.elliptical", table: "Core")
        case .basketball: return String(localized: "workout.sport.basketball", table: "Core")
        case .football: return "Football"
        case .tennis: return "Tennis"
        case .pickleball: return "Pickleball"
        case .boxing: return String(localized: "workout.sport.boxing", table: "Core")
        case .martialArts: return String(localized: "workout.sport.martialArts", table: "Core")
        case .climbing: return String(localized: "workout.sport.climbing", table: "Core")
        case .jumpRope: return String(localized: "workout.sport.jumpRope", table: "Core")
        case .mixedCardio: return "Cardio"
        case .detectedCardio: return String(localized: "workout.sport.detectedCardio", table: "Core")
        case .other: return rawTitle ?? String(localized: "workout.sport.other", table: "Core")
        }
    }

    var symbol: String {
        switch kind {
        case .run: return "figure.run"
        case .walk: return "figure.walk"
        case .cycling: return "figure.outdoor.cycle"
        case .swim: return "figure.pool.swim"
        case .strength: return "figure.strengthtraining.traditional"
        case .core: return "figure.core.training"
        case .yoga: return "figure.yoga"
        case .pilates: return "figure.pilates"
        case .hiit: return "figure.highintensity.intervaltraining"
        case .crossfit: return "figure.cross.training"
        case .hike: return "figure.hiking"
        case .rowing: return "figure.rower"
        case .elliptical: return "figure.elliptical"
        case .basketball: return "figure.basketball"
        case .football: return "figure.soccer"
        case .tennis: return "figure.tennis"
        case .pickleball: return "figure.pickleball"
        case .boxing: return "figure.boxing"
        case .martialArts: return "figure.martial.arts"
        case .climbing: return "figure.climbing"
        case .jumpRope: return "figure.jumprope"
        case .mixedCardio: return "figure.mixed.cardio"
        case .detectedCardio: return "bolt.heart.fill"
        case .other: return "figure.arms.open"
        }
    }

    /// Teinte du type, tirée des tokens existants.
    var token: TokenColor {
        switch kind {
        case .run: return Metric.energy.token
        case .walk, .hike: return Metric.steps.token
        case .cycling, .elliptical: return Metric.spo2.token
        case .swim, .rowing: return Metric.hrv.token
        case .strength, .core: return Metric.stress.token
        case .yoga, .pilates: return Metric.sleep.token
        case .hiit, .crossfit, .boxing, .martialArts, .jumpRope, .mixedCardio: return Metric.cardio.token
        case .basketball, .football, .tennis, .pickleball, .climbing: return Metric.temp.token
        case .detectedCardio: return Metric.strain.token
        case .other: return HealthState.neutral.token
        }
    }

    var tint: Color { token.color }

    // MARK: - Classification

    private static func normalize(_ s: String) -> String {
        s.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    private static func kind(for raw: String?) -> Kind {
        guard let raw, !raw.isEmpty else { return .other }
        switch normalize(raw) {
        case "running", "run", "jogging", "treadmill", "course", "courseapied": return .run
        case "walking", "walk", "marche": return .walk
        case "cycling", "biking", "bike", "roadcycling", "mountainbiking", "spin", "spinning", "velo": return .cycling
        case "swimming", "swim", "natation": return .swim
        case "strength", "strengthtraining", "weightlifting", "weighttraining", "functionalfitness",
             "traditionalstrengthtraining", "functionalstrengthtraining", "renforcement", "musculation": return .strength
        case "coretraining", "core", "gainage": return .core
        case "yoga": return .yoga
        case "pilates", "barre": return .pilates
        case "hiit", "intervaltraining", "highintensityintervaltraining": return .hiit
        case "crossfit", "crosstraining": return .crossfit
        case "hiking", "hike", "randonnee": return .hike
        case "rowing", "row", "rameur": return .rowing
        case "elliptical", "elliptique": return .elliptical
        case "basketball", "basket": return .basketball
        case "football", "soccer": return .football
        case "tennis": return .tennis
        case "pickleball": return .pickleball
        case "boxing", "boxe": return .boxing
        case "martialarts", "artsmartiaux": return .martialArts
        case "climbing", "escalade": return .climbing
        case "jumprope", "cordeasauter": return .jumpRope
        case "mixedcardio", "cardio": return .mixedCardio
        case "detectedcardio": return .detectedCardio
        default: return .other
        }
    }
}
