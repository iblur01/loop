import Foundation

/// Conversions, validation et libellés du profil corporel. Fonctions pures, sans UI ni état.
/// Les bornes viennent de `UserPreferences` / `UserMaxHeartRate` (aucune valeur dupliquée).
enum BodyProfileFormatting {
    typealias UnitSystem = UserPreferences.UnitSystem

    static let ageRange = UserMaxHeartRate.validAgeRange
    static let heightCmRange = UserPreferences.validHeightCmRange
    static let weightKgRange = UserPreferences.validWeightKgRange

    private static let cmPerInch = 2.54
    private static let lbPerKg = 2.20462262185

    // MARK: - Conversions

    static func cmToInches(_ cm: Double) -> Double { cm / cmPerInch }
    static func inchesToCm(_ inches: Double) -> Double { inches * cmPerInch }
    static func kgToLb(_ kg: Double) -> Double { kg * lbPerKg }
    static func lbToKg(_ lb: Double) -> Double { lb / lbPerKg }

    /// Pieds + pouces arrondis au pouce le plus proche (retenue 12 pouces → 1 pied).
    static func feetAndInches(fromCm cm: Double) -> (feet: Int, inches: Int) {
        let total = Int(cmToInches(cm).rounded())
        return (total / 12, total % 12)
    }

    static func cm(feet: Int, inches: Double) -> Double {
        inchesToCm(Double(feet) * 12 + inches)
    }

    // MARK: - Validation

    static func validatedAge(_ age: Int) -> Int? {
        ageRange.contains(age) ? age : nil
    }

    /// `value` est en cm (metric) ou en pouces totaux (imperial). Retourne des cm, ou nil si hors bornes.
    static func validatedHeightCm(_ value: Double, units: UnitSystem) -> Double? {
        let cm = units == .metric ? value : inchesToCm(value)
        return heightCmRange.contains(cm) ? cm : nil
    }

    /// `value` est en kg (metric) ou en lb (imperial). Retourne des kg, ou nil si hors bornes.
    static func validatedWeightKg(_ value: Double, units: UnitSystem) -> Double? {
        let kg = units == .metric ? value : lbToKg(value)
        return weightKgRange.contains(kg) ? kg : nil
    }

    // MARK: - Affichage

    static func heightText(cm: Double, units: UnitSystem, locale: Locale = .current) -> String {
        switch units {
        case .metric:
            return "\(number(cm, maxFraction: 0, locale: locale)) cm"
        case .imperial:
            let (f, i) = feetAndInches(fromCm: cm)
            return "\(f)′\(i)″"
        }
    }

    static func weightText(kg: Double, units: UnitSystem, locale: Locale = .current) -> String {
        switch units {
        case .metric:   return "\(number(kg, maxFraction: 1, locale: locale)) kg"
        case .imperial: return "\(number(kgToLb(kg), maxFraction: 1, locale: locale)) lb"
        }
    }

    private static func number(_ v: Double, maxFraction: Int, locale: Locale) -> String {
        v.formatted(.number.precision(.fractionLength(0...maxFraction)).locale(locale))
    }

    // MARK: - FC max

    /// « Auto ≈ X bpm » pour l'estimation par l'âge, « Manuelle X bpm » / « Mesurée X bpm » sinon.
    static func maxHeartRateLabel(bpm: Int, provenance: UserMaxHeartRate.Provenance) -> String {
        switch provenance {
        case .ageEstimate: return String(format: NSLocalizedString("format.maxhr.auto", tableName: "Base", comment: ""), bpm)
        case .manual:      return String(format: NSLocalizedString("format.maxhr.manual", tableName: "Base", comment: ""), bpm)
        case .measured:    return String(format: NSLocalizedString("format.maxhr.measured", tableName: "Base", comment: ""), bpm)
        }
    }

    static func maxHeartRateLabel(_ resolved: ResolvedMaxHeartRate) -> String {
        maxHeartRateLabel(bpm: resolved.bpm, provenance: resolved.provenance)
    }

    /// Formule affichée uniquement pour la provenance auto ; nil sinon.
    static func maxHeartRateFormula(provenance: UserMaxHeartRate.Provenance, age: Int?) -> String? {
        guard provenance == .ageEstimate else { return nil }
        let a = age.map(String.init) ?? NSLocalizedString("format.maxhr.ageWord", tableName: "Base", comment: "")
        return String(format: NSLocalizedString("format.maxhr.formula", tableName: "Base", comment: ""), a)
    }
}
