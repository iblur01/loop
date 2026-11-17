import XCTest
@testable import Loop

// MARK: - OnboardingFlowTests
//
// Tests unitaires du flux d'onboarding Flowform (`OnboardingStep`, `OnboardingFlowController`) :
//   1. Progression sur les 8 étapes, règles de skip et pré-remplissage Santé / préférences.
//   2. Validation du profil minimal (FC max, âge, taille, poids), estimation Tanaka et reset.
//   3. Sélection / désélection des `preferredSports` et validation sans sport sélectionné.
//   4. Transition post-restauration `.loopbackup` (saut de `.profile` / `.goals`) et `completeOnboarding()`.
@MainActor
final class OnboardingFlowTests: XCTestCase {

    // MARK: - Snapshot & isolation de UserPreferences.shared

    private struct PreferencesSnapshot {
        let onboardingComplete: Bool
        let firstName: String
        let wakeHour: Int
        let wakeMinute: Int
        let sleepTargetMin: Double
        let unitSystem: UserPreferences.UnitSystem
        let alarmEnabled: Bool
        let alarmHour: Int
        let alarmMinute: Int
        let alarmWeekdays: Set<Int>
        let alarmMode: AlarmMode
        let alarmLeadMinutes: Int
        let manualAge: Int?
        let heightCm: Double?
        let weightKg: Double?
        let preferredSports: Set<String>
        let userMaxHeartRate: UserMaxHeartRate?

        @MainActor
        static func capture(from prefs: UserPreferences) -> PreferencesSnapshot {
            PreferencesSnapshot(
                onboardingComplete: prefs.onboardingComplete,
                firstName: prefs.firstName,
                wakeHour: prefs.wakeHour,
                wakeMinute: prefs.wakeMinute,
                sleepTargetMin: prefs.sleepTargetMin,
                unitSystem: prefs.unitSystem,
                alarmEnabled: prefs.alarmEnabled,
                alarmHour: prefs.alarmHour,
                alarmMinute: prefs.alarmMinute,
                alarmWeekdays: prefs.alarmWeekdays,
                alarmMode: prefs.alarmMode,
                alarmLeadMinutes: prefs.alarmLeadMinutes,
                manualAge: prefs.manualAge,
                heightCm: prefs.heightCm,
                weightKg: prefs.weightKg,
                preferredSports: prefs.preferredSports,
                userMaxHeartRate: prefs.userMaxHeartRate
            )
        }

        @MainActor
        func restore(to prefs: UserPreferences) {
            prefs.onboardingComplete = onboardingComplete
            prefs.firstName = firstName
            prefs.wakeHour = wakeHour
            prefs.wakeMinute = wakeMinute
            prefs.sleepTargetMin = sleepTargetMin
            prefs.unitSystem = unitSystem
            prefs.alarmEnabled = alarmEnabled
            prefs.alarmHour = alarmHour
            prefs.alarmMinute = alarmMinute
            prefs.alarmWeekdays = alarmWeekdays
            prefs.alarmMode = alarmMode
            prefs.alarmLeadMinutes = alarmLeadMinutes
            prefs.manualAge = manualAge
            prefs.heightCm = heightCm
            prefs.weightKg = weightKg
            prefs.preferredSports = preferredSports
            if let userMaxHeartRate {
                prefs.setMaxHeartRate(
                    userMaxHeartRate.bpm,
                    provenance: userMaxHeartRate.provenance,
                    age: userMaxHeartRate.age,
                    now: userMaxHeartRate.enteredAt
                )
            } else {
                prefs.clearMaxHeartRate()
            }
        }
    }

    private var savedPreferences: PreferencesSnapshot?

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            let prefs = UserPreferences.shared
            savedPreferences = PreferencesSnapshot.capture(from: prefs)
            prefs.resetOnboarding()
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            savedPreferences?.restore(to: UserPreferences.shared)
            savedPreferences = nil
        }
        try await super.tearDown()
    }

    // MARK: - 1. Progression à travers les 8 étapes

    func testStepSequenceAndSkipRules() {
        XCTAssertEqual(
            OnboardingStep.allCases,
            [.welcome, .manifesto, .healthKit, .band, .profile, .goals, .sync, .ready]
        )
        XCTAssertEqual(OnboardingStep.totalSteps, 8)
        XCTAssertEqual(OnboardingStep.allCases.map(\.stepNumber), Array(1...8))

        // Règles canSkip
        XCTAssertFalse(OnboardingStep.welcome.canSkip)
        XCTAssertFalse(OnboardingStep.manifesto.canSkip)
        XCTAssertTrue(OnboardingStep.healthKit.canSkip)
        XCTAssertTrue(OnboardingStep.band.canSkip)
        XCTAssertTrue(OnboardingStep.profile.canSkip)
        XCTAssertTrue(OnboardingStep.goals.canSkip)
        XCTAssertFalse(OnboardingStep.sync.canSkip)
        XCTAssertFalse(OnboardingStep.ready.canSkip)

        let controller = OnboardingFlowController()
        XCTAssertEqual(controller.step, .welcome)

        // Retour arrière impossible sur .welcome et skip sans effet sur les étapes non passables
        controller.goBack()
        XCTAssertEqual(controller.step, .welcome)
        controller.skipCurrentStep()
        XCTAssertEqual(controller.step, .welcome)

        controller.advance()
        XCTAssertEqual(controller.step, .manifesto)
        XCTAssertTrue(controller.forward)
        controller.skipCurrentStep()
        XCTAssertEqual(controller.step, .manifesto)

        controller.advance()
        XCTAssertEqual(controller.step, .healthKit)

        // Skip autorisé sur .healthKit, .band, .profile (efface profileError), .goals
        controller.skipCurrentStep()
        XCTAssertEqual(controller.step, .band)

        controller.skipCurrentStep()
        XCTAssertEqual(controller.step, .profile)

        controller.profileError = .invalidMaxHR
        controller.skipCurrentStep()
        XCTAssertNil(controller.profileError)
        XCTAssertEqual(controller.step, .goals)

        controller.skipCurrentStep()
        XCTAssertEqual(controller.step, .sync)

        // Skip sans effet sur .sync et .ready ; advance() borné à .ready
        controller.skipCurrentStep()
        XCTAssertEqual(controller.step, .sync)

        controller.advance()
        XCTAssertEqual(controller.step, .ready)
        controller.skipCurrentStep()
        XCTAssertEqual(controller.step, .ready)
        controller.advance()
        XCTAssertEqual(controller.step, .ready)

        // Descente complète avec goBack()
        let expectedReverse: [OnboardingStep] = [.sync, .goals, .profile, .band, .healthKit, .manifesto, .welcome]
        for expected in expectedReverse {
            controller.goBack()
            XCTAssertEqual(controller.step, expected)
            XCTAssertFalse(controller.forward)
        }
    }

    func testPreloadFromHealthAndPreferences() {
        let prefs = UserPreferences.shared
        prefs.manualAge = 35
        prefs.heightCm = 181
        prefs.weightKg = 80
        prefs.preferredSports = ["run", "cycling"]
        prefs.setMaxHeartRate(192, provenance: .manual)

        let controller = OnboardingFlowController(prefs: prefs)

        // Santé prioritaire sur les valeurs locales
        controller.preloadFromPreferencesAndHealth(healthAge: 28, latestHealthWeightKg: 74.5)
        XCTAssertEqual(controller.ageText, "28")
        XCTAssertTrue(controller.ageFromHealth)
        XCTAssertEqual(controller.heightText, "181")
        XCTAssertEqual(controller.weightText, "74.5")
        XCTAssertTrue(controller.weightFromHealth)
        XCTAssertEqual(controller.maxHRText, "192")
        XCTAssertEqual(controller.selectedSports, ["run", "cycling"])

        // Fallback sur UserPreferences quand Santé est absent
        controller.preloadFromPreferencesAndHealth(healthAge: nil, latestHealthWeightKg: nil)
        XCTAssertEqual(controller.ageText, "35")
        XCTAssertFalse(controller.ageFromHealth)
        XCTAssertEqual(controller.heightText, "181")
        XCTAssertEqual(controller.weightText, "80")
        XCTAssertFalse(controller.weightFromHealth)
        XCTAssertEqual(controller.maxHRText, "192")

        // Une FC max avec provenance .ageEstimate ne pré-remplit pas maxHRText
        prefs.setMaxHeartRate(184, provenance: .ageEstimate, age: 35)
        controller.preloadFromPreferencesAndHealth(healthAge: nil, latestHealthWeightKg: nil)
        XCTAssertEqual(controller.maxHRText, "")
    }

    // MARK: - 2. Validation du profil minimal & persistance

    func testProfileValidationAndPersistence() {
        let prefs = UserPreferences.shared
        let controller = OnboardingFlowController(prefs: prefs)

        // FC max hors bornes : bloque la validation et n'avance pas
        for invalidMaxHR in ["119", "231", "abc"] {
            controller.step = .profile
            controller.maxHRText = invalidMaxHR
            XCTAssertFalse(controller.validateAndSaveProfile(), "FC max '\(invalidMaxHR)' devrait échouer")
            XCTAssertEqual(controller.profileError, .invalidMaxHR)
            XCTAssertEqual(controller.step, .profile)
        }

        // FC max aux bornes (120 et 230) : acceptée et persistée
        for boundaryMaxHR in [120, 230] {
            controller.step = .profile
            controller.maxHRText = "\(boundaryMaxHR)"
            XCTAssertTrue(controller.validateAndSaveProfile())
            XCTAssertNil(controller.profileError)
            XCTAssertEqual(prefs.userMaxHeartRate?.bpm, boundaryMaxHR)
            XCTAssertEqual(prefs.userMaxHeartRate?.provenance, .manual)
            XCTAssertEqual(controller.step, .goals)
        }

        // Âge hors bornes (9, 101)
        controller.maxHRText = ""
        for invalidAge in ["9", "101"] {
            controller.step = .profile
            controller.ageText = invalidAge
            XCTAssertFalse(controller.validateAndSaveProfile())
            XCTAssertEqual(controller.profileError, .invalidAge)
            XCTAssertEqual(controller.step, .profile)
        }

        // Taille hors bornes (99, 251)
        controller.ageText = "29"
        for invalidHeight in ["99", "251"] {
            controller.step = .profile
            controller.heightText = invalidHeight
            XCTAssertFalse(controller.validateAndSaveProfile())
            XCTAssertEqual(controller.profileError, .invalidHeight)
            XCTAssertEqual(controller.step, .profile)
        }

        // Poids hors bornes (19, 401)
        controller.heightText = "178"
        for invalidWeight in ["19", "401"] {
            controller.step = .profile
            controller.weightText = invalidWeight
            XCTAssertFalse(controller.validateAndSaveProfile())
            XCTAssertEqual(controller.profileError, .invalidWeight)
            XCTAssertEqual(controller.step, .profile)
        }

        // Profil valide avec maxHRText vide et ageText = "29" -> Tanaka 208 - 0.7 * 29 = 187.7 -> 188
        XCTAssertNotNil(prefs.userMaxHeartRate) // Hérité de la borne 230 ci-dessus : doit être effacé
        controller.step = .profile
        controller.maxHRText = ""
        controller.ageText = "29"
        controller.heightText = "178"
        controller.weightText = "72"

        XCTAssertTrue(controller.validateAndSaveProfile())
        XCTAssertNil(controller.profileError)
        XCTAssertEqual(controller.step, .goals)
        XCTAssertNil(prefs.userMaxHeartRate)
        XCTAssertEqual(prefs.manualAge, 29)
        XCTAssertEqual(prefs.heightCm, 178)
        XCTAssertEqual(prefs.weightKg, 72)
        XCTAssertEqual(controller.estimatedMaxHRFromAge, 188)

        let resolved = prefs.resolvedMaxHeartRate()
        XCTAssertEqual(resolved?.bpm, 188)
        XCTAssertEqual(resolved?.provenance, .ageEstimate)

        // Virgule décimale acceptée pour le poids ("72,5" -> 72.5)
        controller.step = .profile
        controller.weightText = "72,5"
        XCTAssertTrue(controller.validateAndSaveProfile())
        XCTAssertEqual(prefs.weightKg ?? 0, 72.5, accuracy: 0.001)
        XCTAssertEqual(controller.step, .goals)

        // resetMaxHRToAuto() vide le champ, efface l'erreur et efface userMaxHeartRate
        prefs.setMaxHeartRate(195, provenance: .manual)
        controller.maxHRText = "195"
        controller.profileError = .invalidMaxHR
        controller.resetMaxHRToAuto()
        XCTAssertEqual(controller.maxHRText, "")
        XCTAssertNil(controller.profileError)
        XCTAssertNil(prefs.userMaxHeartRate)
    }

    func testResetOnboardingClearsProfileAndSports() {
        let prefs = UserPreferences.shared
        prefs.completeOnboarding()
        prefs.firstName = "Théo"
        prefs.manualAge = 29
        prefs.heightCm = 178
        prefs.weightKg = 72.5
        prefs.preferredSports = ["run", "strength"]
        prefs.setMaxHeartRate(192, provenance: .manual)

        XCTAssertTrue(prefs.onboardingComplete)

        prefs.resetOnboarding()

        XCTAssertFalse(prefs.onboardingComplete)
        XCTAssertNil(prefs.manualAge)
        XCTAssertNil(prefs.heightCm)
        XCTAssertNil(prefs.weightKg)
        XCTAssertEqual(prefs.preferredSports, [])
        XCTAssertNil(prefs.userMaxHeartRate)
    }

    // MARK: - 3. Sélection / désélection des preferredSports

    func testPreferredSportsSelectionAndEmptyState() {
        XCTAssertEqual(
            OnboardingSportOption.allCases,
            [.run, .strength, .swim, .walk, .cycling, .hiit]
        )
        for option in OnboardingSportOption.allCases {
            XCTAssertEqual(option.workoutKind.rawValue, option.rawValue)
            XCTAssertFalse(option.symbol.isEmpty)
            XCTAssertEqual(option.symbol, WorkoutSport(kind: option.workoutKind.rawValue).symbol)
        }

        let prefs = UserPreferences.shared
        let controller = OnboardingFlowController(prefs: prefs)
        XCTAssertTrue(controller.selectedSports.isEmpty)

        controller.toggleSport("run")
        XCTAssertEqual(controller.selectedSports, ["run"])
        XCTAssertEqual(prefs.preferredSports, ["run"])

        controller.toggleSport("strength")
        XCTAssertEqual(controller.selectedSports, ["run", "strength"])
        XCTAssertEqual(prefs.preferredSports, ["run", "strength"])

        controller.toggleSport("swim")
        XCTAssertEqual(controller.selectedSports, ["run", "strength", "swim"])
        XCTAssertEqual(prefs.preferredSports, ["run", "strength", "swim"])

        controller.toggleSport("strength")
        XCTAssertEqual(controller.selectedSports, ["run", "swim"])
        XCTAssertEqual(prefs.preferredSports, ["run", "swim"])

        controller.toggleSport("run")
        controller.toggleSport("swim")
        XCTAssertTrue(controller.selectedSports.isEmpty)
        XCTAssertTrue(prefs.preferredSports.isEmpty)

        // Validation avec 0 sport sélectionné
        controller.step = .goals
        controller.saveGoalsAndAdvance()
        XCTAssertEqual(prefs.preferredSports, Set<String>())
        XCTAssertEqual(controller.step, .sync)
        XCTAssertTrue(controller.forward)
    }

    // MARK: - 4. Transition post-restauration .loopbackup et complétion

    func testBackupRestoreTransitionAndCompletion() {
        let prefs = UserPreferences.shared
        let controller = OnboardingFlowController(prefs: prefs)

        // Échec de restauration : reste sur .welcome avec message d'erreur
        controller.handleBackupRestoreResult(status: .error("Corrompu"))
        XCTAssertEqual(controller.step, .welcome)
        XCTAssertFalse(controller.restoredFromBackup)
        XCTAssertEqual(controller.backupErrorMessage, "Corrompu")
        XCTAssertFalse(prefs.onboardingComplete)

        // Restauration réussie : saute à .healthKit, puis .band -> .sync (saute .profile et .goals)
        controller.handleBackupRestoreResult(status: .idle)
        XCTAssertTrue(controller.restoredFromBackup)
        XCTAssertNil(controller.backupErrorMessage)
        XCTAssertEqual(controller.step, .healthKit)
        XCTAssertTrue(controller.forward)

        controller.advance()
        XCTAssertEqual(controller.step, .band)

        controller.advance()
        XCTAssertEqual(controller.step, .sync)

        // Retour arrière depuis .sync revient directement à .band
        controller.goBack()
        XCTAssertEqual(controller.step, .band)
        XCTAssertFalse(controller.forward)

        controller.advance()
        XCTAssertEqual(controller.step, .sync)

        controller.advance()
        XCTAssertEqual(controller.step, .ready)

        XCTAssertFalse(prefs.onboardingComplete)
        controller.finishOnboarding()
        XCTAssertTrue(prefs.onboardingComplete)
    }
}
