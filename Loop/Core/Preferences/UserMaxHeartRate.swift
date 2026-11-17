import Foundation

/// FC maximale personnelle et sa provenance. Donnée utilisateur uniquement : aucune valeur par défaut.
/// Quand rien n'est saisi, le moteur garde son estimation automatique.
struct UserMaxHeartRate: Codable, Equatable, Sendable {
    enum Provenance: String, Codable, CaseIterable, Sendable {
        case manual      // saisie manuelle
        case measured    // mesurée (test d'effort, effort maximal réel)
        case ageEstimate // estimée par l'âge (Tanaka)

        var label: String {
            switch self {
            case .manual:      return "Saisie manuelle"
            case .measured:    return String(localized: "heartRate.max.measured", table: "Core")
            case .ageEstimate: return String(localized: "heartRate.max.estimated", table: "Core")
            }
        }
    }

    static let validRange: ClosedRange<Int> = 120...230
    static let validAgeRange: ClosedRange<Int> = 10...100

    let bpm: Int
    let provenance: Provenance
    /// Date de saisie.
    let enteredAt: Date
    /// Âge utilisé pour l'estimation (uniquement pour `.ageEstimate`).
    let age: Int?

    /// nil si `bpm` est hors 120...230 ou si l'âge fourni est hors 10...100.
    init?(bpm: Int, provenance: Provenance, enteredAt: Date = Date(), age: Int? = nil) {
        guard Self.validRange.contains(bpm) else { return nil }
        if let age, !Self.validAgeRange.contains(age) { return nil }
        self.bpm = bpm
        self.provenance = provenance
        self.enteredAt = enteredAt
        self.age = provenance == .ageEstimate ? age : nil
    }

    /// Formule de Tanaka : 208 − 0,7 × âge. Estimation de population, imprécise individuellement.
    static func ageEstimate(age: Int) -> Int? {
        guard validAgeRange.contains(age) else { return nil }
        let v = Int((208.0 - 0.7 * Double(age)).rounded())
        return validRange.contains(v) ? v : nil
    }

    static func fromAge(_ age: Int, enteredAt: Date = Date()) -> UserMaxHeartRate? {
        guard let bpm = ageEstimate(age: age) else { return nil }
        return UserMaxHeartRate(bpm: bpm, provenance: .ageEstimate, enteredAt: enteredAt, age: age)
    }

    // Décodage défensif : une valeur persistée hors bornes est ignorée plutôt que consommée.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let bpm = try c.decode(Int.self, forKey: .bpm)
        let provenance = try c.decode(Provenance.self, forKey: .provenance)
        let enteredAt = try c.decode(Date.self, forKey: .enteredAt)
        let age = try c.decodeIfPresent(Int.self, forKey: .age)
        guard let v = UserMaxHeartRate(bpm: bpm, provenance: provenance, enteredAt: enteredAt, age: age) else {
            throw DecodingError.dataCorruptedError(forKey: .bpm, in: c, debugDescription: "FC max hors bornes")
        }
        self = v
    }
}

/// Résultat consommable par le moteur : valeur + provenance.
struct ResolvedMaxHeartRate: Equatable, Sendable {
    let bpm: Int
    let provenance: UserMaxHeartRate.Provenance
    let enteredAt: Date
}
