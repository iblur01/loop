import Foundation
import HealthKit

/// User-configurable preferences for metric calculations and personal profile.
/// Stored in UserDefaults for persistence across app launches.
@MainActor
final class UserPreferences: ObservableObject {
    static let shared = UserPreferences()

    private let defaults = UserDefaults.standard

    // MARK: - Keys
    private enum Keys {
        static let strainDifficulty = "userPreferences.strainDifficulty"
        static let firstName = "userPreferences.firstName"
        static let wakeHour = "userPreferences.wakeHour"
        static let wakeMinute = "userPreferences.wakeMinute"
        static let sleepTargetMin = "userPreferences.sleepTargetMin"
        static let onboardingComplete = "userPreferences.onboardingComplete"
        static let unitSystem = "userPreferences.unitSystem"
        static let alarmEnabled = "userPreferences.alarmEnabled"
        static let alarmHour = "userPreferences.alarmHour"
        static let alarmMinute = "userPreferences.alarmMinute"
        static let alarmWeekdays = "userPreferences.alarmWeekdays"
        static let alarmMode = "userPreferences.alarmMode"
        static let alarmLeadMinutes = "userPreferences.alarmLeadMinutes"
        static let userMaxHeartRate = "userPreferences.userMaxHeartRate"
        static let manualAge = "userPreferences.manualAge"
        static let heightCm = "userPreferences.heightCm"
        static let weightKg = "userPreferences.weightKg"
        static let preferredSports = "userPreferences.preferredSports"
    }

    // MARK: - Onboarding gate

    /// `true` once the user has completed the first-run onboarding flow. Drives the gate in
    /// `LoopApp` that swaps `OnboardingView` for `MainTabView`.
    @Published var onboardingComplete: Bool {
        didSet { defaults.set(onboardingComplete, forKey: Keys.onboardingComplete) }
    }

    /// Marks onboarding complete and persists. Called by `OnboardingView` on the final step.
    func completeOnboarding() {
        onboardingComplete = true
    }

    /// Resets all onboarding + profile state (used by the "Refaire l'onboarding" action in
    /// AdvancedView). Does NOT touch strain difficulty or backups.
    func resetOnboarding() {
        onboardingComplete = false
        firstName = Self.defaultFirstName
        wakeHour = Self.defaultWakeHour
        wakeMinute = Self.defaultWakeMinute
        sleepTargetMin = Self.defaultSleepTargetMin
        unitSystem = .metric
        alarmEnabled = false
        alarmHour = Self.defaultAlarmHour
        alarmMinute = Self.defaultAlarmMinute
        alarmWeekdays = []
        alarmMode = .regular
        alarmLeadMinutes = Self.defaultAlarmLeadMinutes
        manualAge = nil
        heightCm = nil
        weightKg = nil
        preferredSports = []
        clearMaxHeartRate()
    }

    // MARK: - Personal profile

    /// User's first name, shown in the Today greeting and used by the coach. Empty fallback
    /// keeps the greeting polite without revealing a hard-coded name.
    @Published var firstName: String {
        didSet { defaults.set(firstName, forKey: Keys.firstName) }
    }

    private static let defaultFirstName = ""

    /// Target wake time (hour + minute) used by the sleep plan instead of the hard-coded 07:00.
    static let defaultWakeHour = 7
    static let defaultWakeMinute = 0

    @Published var wakeHour: Int {
        didSet { defaults.set(wakeHour, forKey: Keys.wakeHour) }
    }

    @Published var wakeMinute: Int {
        didSet { defaults.set(wakeMinute, forKey: Keys.wakeMinute) }
    }

    /// Convenience `Date` for the wake time on today's calendar — used by `SleepCoachModel`.
    var wakeDateToday: Date {
        Calendar.current.date(bySettingHour: wakeHour, minute: wakeMinute, second: 0, of: Date()) ?? Date()
    }

    /// Target sleep duration per night, in minutes. Replaces the engine's hard-coded 480 default
    /// when set. Stepper UI exposes 5h–10h in 15-min increments.
    static let minSleepTargetMin: Double = 300
    static let maxSleepTargetMin: Double = 600
    static let defaultSleepTargetMin: Double = 480

    @Published var sleepTargetMin: Double {
        didSet { defaults.set(sleepTargetMin, forKey: Keys.sleepTargetMin) }
    }

    // `nonisolated` : bornes lues par des fonctions pures hors MainActor (BodyProfileFormatting).
    nonisolated static let validHeightCmRange: ClosedRange<Double> = 100...250
    nonisolated static let validWeightKgRange: ClosedRange<Double> = 20...400

    /// Setters validés pour l'édition après onboarding. Retournent false (rien n'est modifié) si hors bornes.
    @discardableResult
    func setManualAge(_ age: Int) -> Bool {
        guard UserMaxHeartRate.validAgeRange.contains(age) else { return false }
        manualAge = age
        return true
    }

    @discardableResult
    func setHeightCm(_ cm: Double) -> Bool {
        guard Self.validHeightCmRange.contains(cm) else { return false }
        heightCm = cm
        return true
    }

    @discardableResult
    func setWeightKg(_ kg: Double) -> Bool {
        guard Self.validWeightKgRange.contains(kg) else { return false }
        weightKg = kg
        return true
    }

    /// Âge saisi manuellement pendant l'onboarding ou dans le profil (utilisé en repli si Apple Santé
    /// ne fournit pas la date de naissance). Bornes validées via `UserMaxHeartRate.validAgeRange`.
    @Published var manualAge: Int? {
        didSet {
            if let manualAge, UserMaxHeartRate.validAgeRange.contains(manualAge) {
                defaults.set(manualAge, forKey: Keys.manualAge)
            } else {
                defaults.removeObject(forKey: Keys.manualAge)
            }
        }
    }

    /// Taille en centimètres (facultative, utilisée pour les estimations métaboliques).
    @Published var heightCm: Double? {
        didSet {
            if let heightCm { defaults.set(heightCm, forKey: Keys.heightCm) }
            else { defaults.removeObject(forKey: Keys.heightCm) }
        }
    }

    /// Poids en kilogrammes (facultatif, utilisé pour les estimations métaboliques).
    @Published var weightKg: Double? {
        didSet {
            if let weightKg { defaults.set(weightKg, forKey: Keys.weightKg) }
            else { defaults.removeObject(forKey: Keys.weightKg) }
        }
    }

    /// Identifiants bruts (`WorkoutSport.Kind.rawValue`) des sports pratiqués le plus souvent.
    @Published var preferredSports: Set<String> {
        didSet { defaults.set(Array(preferredSports).sorted(), forKey: Keys.preferredSports) }
    }

    // MARK: - Unit system

    enum UnitSystem: String, CaseIterable {
        case metric
        case imperial

        var label: String {
            switch self {
            case .metric:   return String(localized: "units.metric", table: "Core")
            case .imperial: return String(localized: "units.imperial", table: "Core")
            }
        }
    }

    @Published var unitSystem: UnitSystem {
        didSet { defaults.set(unitSystem.rawValue, forKey: Keys.unitSystem) }
    }

    // MARK: - Réveil (Smart Alarm)

    static let defaultAlarmHour = 7
    static let defaultAlarmMinute = 0
    static let defaultAlarmLeadMinutes = 15
    static let minAlarmLeadMinutes = 5
    static let maxAlarmLeadMinutes = 30

    @Published var alarmEnabled: Bool {
        didSet { defaults.set(alarmEnabled, forKey: Keys.alarmEnabled) }
    }

    @Published var alarmHour: Int {
        didSet { defaults.set(alarmHour, forKey: Keys.alarmHour) }
    }

    @Published var alarmMinute: Int {
        didSet { defaults.set(alarmMinute, forKey: Keys.alarmMinute) }
    }

    /// Jours actifs : indices `Calendar` 1...7 (1=dimanche, 7=samedi). Vide → alarme one-shot.
    @Published var alarmWeekdays: Set<Int> {
        didSet { defaults.set(Array(alarmWeekdays), forKey: Keys.alarmWeekdays) }
    }

    @Published var alarmMode: AlarmMode {
        didSet { defaults.set(alarmMode.rawValue, forKey: Keys.alarmMode) }
    }

    @Published var alarmLeadMinutes: Int {
        didSet { defaults.set(alarmLeadMinutes, forKey: Keys.alarmLeadMinutes) }
    }

    /// Résumé court des jours actifs pour les libellés.
    var alarmWeekdaysSummary: String {
        Self.weekdaysSummary(alarmWeekdays)
    }

    static func weekdaysSummary(_ weekdays: Set<Int>) -> String {
        if weekdays.isEmpty { return String(localized: "alarm.once", table: "Core") }
        if weekdays.count == 7 { return String(localized: "alarm.daily", table: "Core") }
        if weekdays == [2, 3, 4, 5, 6] { return String(localized: "alarm.weekdays", table: "Core") }
        if weekdays == [1, 7] { return String(localized: "alarm.weekend", table: "Core") }
        // 1=dim...7=sam → libellés courts, ordonnés lundi-first.
        let short = [""] + Calendar.current.shortWeekdaySymbols
        let ordered = [2, 3, 4, 5, 6, 7, 1].filter { weekdays.contains($0) }
        return ordered.map { short[$0] }.joined(separator: ", ")
    }

    // MARK: - Strain Difficulty
    /// Multiplicateur de sensibilité du strain passé tel quel au moteur (`strain(difficulty:)`).
    /// Le moteur est monotone CROISSANT : multiplicateur HAUT = strain ACCUMULÉ PLUS VITE.
    /// Côté UX on inverse donc le sens : « Difficile » = plus dur à accumuler = multiplicateur BAS.
    /// Fenêtre [0.2, 0.8] (défaut 0.45), volontairement « dure » : même « Facile » (0.8) reste
    /// sous le 1.0 « normal WHOOP ».
    /// - 0.20 = Très difficile (strain le plus bas)
    /// - 0.45 = Normal (défaut)
    /// - 0.80 = Très facile (strain le plus haut)
    static let minDifficulty: Double = 0.1
    static let maxDifficulty: Double = 0.8
    static let defaultDifficulty: Double = 0.45

    @Published var strainDifficulty: Double {
        didSet {
            defaults.set(strainDifficulty, forKey: Keys.strainDifficulty)
        }
    }

    // MARK: - FC maximale personnelle

    /// FC max saisie par l'utilisateur (JSON dans UserDefaults). nil = estimation automatique du moteur.
    /// Lue par `LoopDataRepository` via `resolvedMaxHeartRate()` et passée au moteur à chaque calcul.
    @Published private(set) var userMaxHeartRate: UserMaxHeartRate? {
        didSet {
            if let userMaxHeartRate, let data = try? JSONEncoder().encode(userMaxHeartRate) {
                defaults.set(data, forKey: Keys.userMaxHeartRate)
            } else {
                defaults.removeObject(forKey: Keys.userMaxHeartRate)
            }
        }
    }

    /// Enregistre la FC max. Retourne false (rien n'est modifié) si hors 120...230 bpm.
    @discardableResult
    func setMaxHeartRate(_ bpm: Int, provenance: UserMaxHeartRate.Provenance, age: Int? = nil, now: Date = Date()) -> Bool {
        guard let value = UserMaxHeartRate(bpm: bpm, provenance: provenance, enteredAt: now, age: age) else { return false }
        userMaxHeartRate = value
        return true
    }

    /// Efface la valeur personnelle : le moteur retombe sur son estimation automatique.
    func clearMaxHeartRate() { userMaxHeartRate = nil }

    /// API pour le moteur : valeur personnelle + provenance, ou nil (utiliser l'estimation automatique).
    func resolvedMaxHeartRate() -> ResolvedMaxHeartRate? {
        if let v = userMaxHeartRate, v.provenance != .ageEstimate {
            return ResolvedMaxHeartRate(bpm: v.bpm, provenance: v.provenance, enteredAt: v.enteredAt)
        }
        if let age = effectiveAge, let bpm = UserMaxHeartRate.ageEstimate(age: age) {
            return ResolvedMaxHeartRate(bpm: bpm, provenance: .ageEstimate, enteredAt: Date())
        }
        guard let v = userMaxHeartRate else { return nil }
        return ResolvedMaxHeartRate(bpm: v.bpm, provenance: v.provenance, enteredAt: v.enteredAt)
    }

    /// Âge effectif utilisé pour l'estimation automatique Tanaka : Apple Santé prioritaire,
    /// sinon l'âge saisi manuellement pendant l'onboarding ou dans le profil.
    var effectiveAge: Int? {
        if let age = healthAge { return age }
        return manualAge.flatMap { UserMaxHeartRate.validAgeRange.contains($0) ? $0 : nil }
    }

    /// Date of birth stays in HealthKit; age is calculated when needed and is never cached.
    var healthAge: Int? {
        guard HKHealthStore.isHealthDataAvailable(),
              let components = try? HKHealthStore().dateOfBirthComponents(),
              let birthday = Calendar.current.date(from: components) else { return nil }
        let age = Calendar.current.dateComponents([.year], from: birthday, to: Date()).year
        return age.flatMap { UserMaxHeartRate.validAgeRange.contains($0) ? $0 : nil }
    }

    private init() {
        // UserDefaults n'est qu'un cache rapide pour l'affichage initial ; la SOURCE DE VÉRITÉ est
        // le LoopCache (durable, inclus au backup), réinjecté par `applyRestored` au chargement.
        let stored = UserDefaults.standard.double(forKey: Keys.strainDifficulty)
        let valid = stored >= Self.minDifficulty && stored <= Self.maxDifficulty
        self.strainDifficulty = valid ? stored : Self.defaultDifficulty

        self.onboardingComplete = UserDefaults.standard.bool(forKey: Keys.onboardingComplete)
        self.firstName = UserDefaults.standard.string(forKey: Keys.firstName) ?? Self.defaultFirstName
        let storedWakeHour = UserDefaults.standard.object(forKey: Keys.wakeHour) as? Int
        self.wakeHour = storedWakeHour ?? Self.defaultWakeHour
        let storedWakeMinute = UserDefaults.standard.object(forKey: Keys.wakeMinute) as? Int
        self.wakeMinute = storedWakeMinute ?? Self.defaultWakeMinute
        let storedSleepTarget = UserDefaults.standard.object(forKey: Keys.sleepTargetMin) as? Double
        self.sleepTargetMin = storedSleepTarget ?? Self.defaultSleepTargetMin
        let storedUnits = UserDefaults.standard.string(forKey: Keys.unitSystem)
        self.unitSystem = UnitSystem(rawValue: storedUnits ?? "") ?? .metric

        self.alarmEnabled = UserDefaults.standard.bool(forKey: Keys.alarmEnabled)
        let storedAlarmHour = UserDefaults.standard.object(forKey: Keys.alarmHour) as? Int
        self.alarmHour = storedAlarmHour ?? Self.defaultAlarmHour
        let storedAlarmMinute = UserDefaults.standard.object(forKey: Keys.alarmMinute) as? Int
        self.alarmMinute = storedAlarmMinute ?? Self.defaultAlarmMinute
        let storedWeekdays = UserDefaults.standard.array(forKey: Keys.alarmWeekdays) as? [Int] ?? []
        self.alarmWeekdays = Set(storedWeekdays)
        let storedMode = UserDefaults.standard.string(forKey: Keys.alarmMode)
        self.alarmMode = AlarmMode(rawValue: storedMode ?? "") ?? .regular
        let storedLead = UserDefaults.standard.object(forKey: Keys.alarmLeadMinutes) as? Int
        self.alarmLeadMinutes = storedLead ?? Self.defaultAlarmLeadMinutes
        self.userMaxHeartRate = UserDefaults.standard.data(forKey: Keys.userMaxHeartRate)
            .flatMap { try? JSONDecoder().decode(UserMaxHeartRate.self, from: $0) }
        self.manualAge = (UserDefaults.standard.object(forKey: Keys.manualAge) as? Int)
            .flatMap { UserMaxHeartRate.validAgeRange.contains($0) ? $0 : nil }
        self.heightCm = (UserDefaults.standard.object(forKey: Keys.heightCm) as? Double)
            .flatMap { Self.validHeightCmRange.contains($0) ? $0 : nil }
        self.weightKg = (UserDefaults.standard.object(forKey: Keys.weightKg) as? Double)
            .flatMap { Self.validWeightKgRange.contains($0) ? $0 : nil }
        self.preferredSports = Set(UserDefaults.standard.stringArray(forKey: Keys.preferredSports) ?? [])
    }

    /// Réinjecte la difficulté depuis le cache durable (LoopCache) au lancement — TOUJOURS (le cache
    /// est la source de vérité, mis à jour synchroniquement à chaque réglage). Survit donc à une
    /// suppression+réinstallation+restore et ne peut plus retomber au centre.
    func applyRestored(_ value: Double?) {
        guard let value else { return }
        strainDifficulty = min(max(value, Self.minDifficulty), Self.maxDifficulty)  // didSet persiste
    }

    // MARK: - Convenience

    /// Libellé INVERSÉ : multiplicateur bas = plus difficile (strain plus dur à monter).
    var strainDifficultyLabel: String {
        switch strainDifficulty {
        case ..<0.3:  return String(localized: "difficulty.veryHard", table: "Core")
        case 0.3..<0.45: return String(localized: "difficulty.hard", table: "Core")
        case 0.45..<0.6: return String(localized: "difficulty.normal", table: "Core")
        case 0.6..<0.75: return String(localized: "difficulty.easy", table: "Core")
        default: return String(localized: "difficulty.veryEasy", table: "Core")
        }
    }
}
