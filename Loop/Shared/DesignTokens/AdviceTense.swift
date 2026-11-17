import Foundation

/// Temps verbal des textes de conseil : aujourd'hui (présent, recommandations possibles) ou jour
/// passé (bilan au passé, jamais d'impératif ni de « demain »). Seule source de cette décision
/// pour l'app : StrainCoachModel, page Strain, conseils de l'accueil, lectures d'entraînement.
enum AdviceTense: Equatable {
    case today
    case past

    /// Jour local "yyyy-MM-dd". Un jour absent ou illisible est traité comme aujourd'hui.
    static func of(day: String?, now: Date = Date(), timeZone: TimeZone = .autoupdatingCurrent) -> AdviceTense {
        guard let day else { return .today }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return day < f.string(from: now) ? .past : .today
    }

    /// Choisit la forme du texte selon le temps.
    func pick(_ today: String, past: String) -> String {
        self == .today ? today : past
    }
}
