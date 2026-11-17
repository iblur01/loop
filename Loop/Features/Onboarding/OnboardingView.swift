import SwiftUI
import CoreBluetooth
import HealthKit
import WhoopStore
import LoopStrapEngine

// MARK: - Enums & Model (Testable via @testable import Loop)

/// Étapes du flux d'onboarding Flowform (8 étapes).
enum OnboardingStep: Int, CaseIterable, Identifiable, Sendable {
    case welcome = 0
    case manifesto
    case healthKit
    case band
    case profile
    case goals
    case sync
    case ready

    var id: Int { rawValue }
    var stepNumber: Int { rawValue + 1 }
    static let totalSteps = 8

    var canSkip: Bool {
        switch self {
        case .healthKit, .band, .profile, .goals:
            return true
        case .welcome, .manifesto, .sync, .ready:
            return false
        }
    }

    var title: String {
        switch self {
        case .welcome:
            return NSLocalizedString("onboarding.welcome.title", tableName: "Base", comment: "")
        case .manifesto:
            return NSLocalizedString("onboarding.manifesto.title", tableName: "Base", comment: "")
        case .healthKit:
            return NSLocalizedString("onboarding.health.step_title", tableName: "Base", comment: "")
        case .band:
            return NSLocalizedString("onboarding.band.title", tableName: "Base", comment: "")
        case .profile:
            return NSLocalizedString("onboarding.profile.title", tableName: "Base", comment: "")
        case .goals:
            return NSLocalizedString("onboarding.goals.title", tableName: "Base", comment: "")
        case .sync:
            return NSLocalizedString("onboarding.sync.title", tableName: "Base", comment: "")
        case .ready:
            return NSLocalizedString("onboarding.ready.title", tableName: "Base", comment: "")
        }
    }

    var subtitle: String {
        switch self {
        case .welcome:
            return ""
        case .manifesto:
            return NSLocalizedString("onboarding.manifesto.subtitle", tableName: "Base", comment: "")
        case .healthKit:
            return NSLocalizedString("onboarding.health.step_subtitle", tableName: "Base", comment: "")
        case .band:
            return NSLocalizedString("onboarding.band.subtitle", tableName: "Base", comment: "")
        case .profile:
            return NSLocalizedString("onboarding.profile.subtitle", tableName: "Base", comment: "")
        case .goals:
            return NSLocalizedString("onboarding.goals.subtitle", tableName: "Base", comment: "")
        case .sync:
            return NSLocalizedString("onboarding.sync.subtitle", tableName: "Base", comment: "")
        case .ready:
            return ""
        }
    }
}

/// Options de sports proposées sur l'écran d'objectifs sportifs.
enum OnboardingSportOption: String, CaseIterable, Identifiable, Sendable {
    case run
    case strength
    case swim
    case walk
    case cycling
    case hiit

    var id: String { rawValue }

    var workoutKind: WorkoutSport.Kind {
        switch self {
        case .run: return .run
        case .strength: return .strength
        case .swim: return .swim
        case .walk: return .walk
        case .cycling: return .cycling
        case .hiit: return .hiit
        }
    }

    var symbol: String {
        WorkoutSport(kind: workoutKind.rawValue).symbol
    }

    var title: String {
        NSLocalizedString("onboarding.goals.sport.\(rawValue)", tableName: "Base", comment: "")
    }
}

/// Erreurs de validation du profil minimal.
enum OnboardingProfileError: Equatable, Sendable {
    case invalidMaxHR
    case invalidAge
    case invalidHeight
    case invalidWeight
}

/// Contrôleur d'état principal du flux d'onboarding Flowform.
@MainActor
final class OnboardingFlowController: ObservableObject {
    @Published var step: OnboardingStep = .welcome
    @Published var forward: Bool = true
    @Published var restoredFromBackup: Bool = false
    @Published var backupErrorMessage: String?
    @Published var ageText: String = ""
    @Published var heightText: String = ""
    @Published var weightText: String = ""
    @Published var maxHRText: String = ""
    @Published var ageFromHealth: Bool = false
    @Published var weightFromHealth: Bool = false
    @Published var profileError: OnboardingProfileError?
    @Published var selectedSports: Set<String> = []

    let prefs: UserPreferences

    init(prefs: UserPreferences? = nil) {
        let p = prefs ?? UserPreferences.shared
        self.prefs = p
        self.selectedSports = p.preferredSports
    }

    func preloadFromPreferencesAndHealth(healthAge: Int?, latestHealthWeightKg: Double?) {
        if let healthAge {
            ageText = "\(healthAge)"
            ageFromHealth = true
        } else if let manualAge = prefs.manualAge {
            ageText = "\(manualAge)"
            ageFromHealth = false
        } else {
            ageText = ""
            ageFromHealth = false
        }

        if let h = prefs.heightCm {
            heightText = h.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(h))" : String(format: "%.1f", h)
        } else {
            heightText = ""
        }

        if let latestHealthWeightKg {
            weightText = latestHealthWeightKg.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(latestHealthWeightKg))" : String(format: "%.1f", latestHealthWeightKg)
            weightFromHealth = true
        } else if let w = prefs.weightKg {
            weightText = w.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(w))" : String(format: "%.1f", w)
            weightFromHealth = false
        } else {
            weightText = ""
            weightFromHealth = false
        }

        if let maxHR = prefs.userMaxHeartRate, maxHR.provenance != .ageEstimate {
            maxHRText = "\(maxHR.bpm)"
        } else {
            maxHRText = ""
        }

        selectedSports = prefs.preferredSports
    }

    var estimatedMaxHRFromAge: Int? {
        let trimmed = ageText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let age = Int(trimmed), UserMaxHeartRate.validAgeRange.contains(age) {
            return UserMaxHeartRate.ageEstimate(age: age)
        }
        if let effAge = prefs.effectiveAge {
            return UserMaxHeartRate.ageEstimate(age: effAge)
        }
        return nil
    }

    func nextStep(after current: OnboardingStep) -> OnboardingStep {
        if restoredFromBackup && current == .band {
            return .sync
        }
        return OnboardingStep(rawValue: current.rawValue + 1) ?? .ready
    }

    func previousStep(before current: OnboardingStep) -> OnboardingStep {
        if restoredFromBackup && current == .sync {
            return .band
        }
        return OnboardingStep(rawValue: max(0, current.rawValue - 1)) ?? .welcome
    }

    func advance() {
        guard step != .ready else { return }
        forward = true
        step = nextStep(after: step)
    }

    func goBack() {
        guard step != .welcome else { return }
        forward = false
        step = previousStep(before: step)
    }

    func skipCurrentStep() {
        guard step.canSkip else { return }
        if step == .profile {
            profileError = nil
        }
        advance()
    }

    func handleBackupRestoreResult(status: BackupCoordinator.Status) {
        switch status {
        case .idle:
            backupErrorMessage = nil
            restoredFromBackup = true
            preloadFromPreferencesAndHealth(healthAge: prefs.healthAge, latestHealthWeightKg: nil)
            forward = true
            step = .healthKit
        case .error(let message):
            restoredFromBackup = false
            backupErrorMessage = message
            step = .welcome
        case .preparing, .restoring:
            break
        }
    }

    func validateAndSaveProfile() -> Bool {
        let cleanMaxHR = maxHRText.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanAge = ageText.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanHeight = heightText.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        let cleanWeight = weightText.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")

        var parsedMaxHR: Int? = nil
        if !cleanMaxHR.isEmpty {
            guard let v = Int(cleanMaxHR), UserMaxHeartRate.validRange.contains(v) else {
                profileError = .invalidMaxHR
                return false
            }
            parsedMaxHR = v
        }

        var parsedAge: Int? = nil
        if !cleanAge.isEmpty {
            guard let v = Int(cleanAge), UserMaxHeartRate.validAgeRange.contains(v) else {
                profileError = .invalidAge
                return false
            }
            parsedAge = v
        }

        var parsedHeight: Double? = nil
        if !cleanHeight.isEmpty {
            guard let v = Double(cleanHeight), UserPreferences.validHeightCmRange.contains(v) else {
                profileError = .invalidHeight
                return false
            }
            parsedHeight = v
        }

        var parsedWeight: Double? = nil
        if !cleanWeight.isEmpty {
            guard let v = Double(cleanWeight), UserPreferences.validWeightKgRange.contains(v) else {
                profileError = .invalidWeight
                return false
            }
            parsedWeight = v
        }

        profileError = nil

        if let parsedAge {
            prefs.manualAge = parsedAge
        } else if cleanAge.isEmpty && !ageFromHealth {
            prefs.manualAge = nil
        }

        prefs.heightCm = parsedHeight
        prefs.weightKg = parsedWeight

        if let parsedMaxHR {
            prefs.setMaxHeartRate(parsedMaxHR, provenance: .manual)
        } else if cleanMaxHR.isEmpty {
            prefs.clearMaxHeartRate()
        }

        advance()
        return true
    }

    func resetMaxHRToAuto() {
        maxHRText = ""
        profileError = nil
        prefs.clearMaxHeartRate()
    }

    func toggleSport(_ kindRawValue: String) {
        if selectedSports.contains(kindRawValue) {
            selectedSports.remove(kindRawValue)
        } else {
            selectedSports.insert(kindRawValue)
        }
        prefs.preferredSports = selectedSports
    }

    func saveGoalsAndAdvance() {
        prefs.preferredSports = selectedSports
        advance()
    }

    func finishOnboarding() {
        prefs.completeOnboarding()
    }
}

// MARK: - Onboarding Typography

/// Échelle typographique de l'onboarding : styles de texte système uniquement (Dynamic Type),
/// un cran au-dessus des écrans de données pour un flux lisible d'un coup d'œil.
private enum OnboardingType {
    /// Titre de page dominant (Large Title).
    static let pageTitle = Font.largeTitle.bold()
    /// Sous-titre de page (Body).
    static let pageSubtitle = LoopType.body
    /// Titre de ligne de carte (Title 3).
    static let rowTitle = Font.title3.weight(.semibold)
    /// Sous-texte de ligne (Body).
    static let rowDetail = LoopType.body
    /// Icône de ligne (≈ 28 pt via Title 2).
    static let rowIcon = Font.title2.weight(.semibold)
    /// Badge d'état (Subheadline).
    static let badge = LoopType.label.weight(.semibold)
    /// Valeur de roulette ou de cercle (Title arrondi).
    static let value = LoopType.tileValue
}

// MARK: - Loop Mark

/// Logo de Loop : la marque de l'icône d'app (`Loop/LogoLoop.icon`), importée en image vectorielle
/// template dans `Assets.xcassets/LoopLogo`, teintée en couleur de texte primaire pour rester sobre.
struct LoopMark: View {
    @ScaledMetric(relativeTo: .title) private var size: CGFloat = 72

    var body: some View {
        Image("LoopLogo")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(LoopColor.textPrimary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "Loop"))
    }
}

// MARK: - Onboarding View

/// Vue d'onboarding Flowform 8 étapes de Loop.
/// Chaque écran tient sans défilement sur un iPhone standard : titre dominant, un élément visuel
/// principal, peu de texte, le tout centré entre la barre de navigation et le dock d'actions.
/// Le `ScrollView` n'est qu'un repli pour les tailles Dynamic Type d'accessibilité.
@MainActor
struct OnboardingView: View {
    @ObservedObject var repository: LoopDataRepository
    @ObservedObject var connection: DeviceConnectionViewModel
    @ObservedObject private var syncCoordinator: SyncCoordinator
    let backup: BackupCoordinator?

    @StateObject private var controller: OnboardingFlowController
    @ObservedObject private var healthImporter = HealthKitImporter.shared
    @StateObject private var sampleImporter = HealthSampleImporter()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AccessibilityFocusState private var isTitleFocused: Bool

    @State private var showBackupImporter = false
    @State private var isRestoringBackup = false
    @State private var isRequestingHealth = false
    @State private var healthRequested = false
    @State private var bandScanTimedOut = false
    @State private var bondingFailed = false
    @State private var previousPhase: DeviceConnectionViewModel.ConnectionPhase? = nil
    @State private var scanTimerTask: Task<Void, Never>? = nil
    @State private var isLedPulsing = false
    @State private var ringProgress: Double = 0

    // Plages des roulettes du profil.
    private static let ageRange = 14...99
    private static let heightRange = 120...220
    private static let weightRange = 30...200
    private static let maxHRRange = 120...220

    init(
        repository: LoopDataRepository? = nil,
        connection: DeviceConnectionViewModel,
        backup: BackupCoordinator? = nil
    ) {
        self.repository = repository ?? LoopDataRepository()
        self.connection = connection
        self._syncCoordinator = ObservedObject(wrappedValue: connection.bleManager.syncCoordinator)
        self.backup = backup
        _controller = StateObject(wrappedValue: OnboardingFlowController(prefs: .shared))
    }

    var body: some View {
        VStack(spacing: 0) {
            topNavigationBar
                .padding(.bottom, 4)

            stepContainer

            bottomActionDock
        }
        .appBackground()
        .task {
            let latestWeight = await loadLatestHealthWeightKg()
            controller.preloadFromPreferencesAndHealth(
                healthAge: UserPreferences.shared.healthAge,
                latestHealthWeightKg: latestWeight
            )
            await sampleImporter.refreshState()
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isTitleFocused = true
            }
        }
        .onChange(of: controller.step) { _, newStep in
            if newStep == .profile {
                Task {
                    let latestWeight = await loadLatestHealthWeightKg()
                    if let latestWeight, controller.weightText.isEmpty {
                        controller.weightText = latestWeight.truncatingRemainder(dividingBy: 1) == 0
                            ? "\(Int(latestWeight))"
                            : String(format: "%.1f", latestWeight)
                        controller.weightFromHealth = true
                    }
                    if let healthAge = UserPreferences.shared.healthAge, controller.ageText.isEmpty {
                        controller.ageText = "\(healthAge)"
                        controller.ageFromHealth = true
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isTitleFocused = true
            }
        }
        .sheet(isPresented: $showBackupImporter) {
            BackupImporter(
                onPick: { url in
                    showBackupImporter = false
                    guard let backup else { return }
                    isRestoringBackup = true
                    Task {
                        await backup.importBackup(from: url)
                        isRestoringBackup = false
                        controller.handleBackupRestoreResult(status: backup.status)
                    }
                },
                onCancel: {
                    showBackupImporter = false
                }
            )
        }
    }

    // MARK: - Navigation Bar

    private var topNavigationBar: some View {
        GlassEffectContainer(spacing: 10) {
            HStack {
                Button {
                    controller.goBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(LoopType.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .disabled(controller.step == .welcome)
                .opacity(controller.step == .welcome ? 0 : 1)
                .accessibilityHidden(controller.step == .welcome)
                .accessibilityLabel(NSLocalizedString("onboarding.nav.back", tableName: "Base", comment: ""))

                Spacer()

                // Pilule centrale de progression (le texte « Étape x sur y » reste pour VoiceOver).
                HStack(spacing: 4) {
                    ForEach(0..<OnboardingStep.totalSteps, id: \.self) { idx in
                        Capsule()
                            .fill(idx <= controller.step.rawValue ? Metric.strain.tint : LoopColor.trackEmpty)
                            .frame(width: 12, height: 5)
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 36)
                .glassEffect(.regular, in: .capsule)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(format: NSLocalizedString("onboarding.nav.step_of", tableName: "Base", comment: ""), controller.step.stepNumber, OnboardingStep.totalSteps))

                Spacer()

                if controller.step.canSkip {
                    Button(NSLocalizedString("onboarding.nav.skip", tableName: "Base", comment: "")) {
                        controller.skipCurrentStep()
                    }
                    .font(LoopType.body.weight(.medium))
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                } else {
                    Color.clear
                        .frame(width: 44, height: 44)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.horizontal, LoopMeasure.screenGutter)
        .padding(.top, 8)
    }

    // MARK: - Step Container

    /// Hauteur fixe par défaut (aucun défilement), contenu centré verticalement ;
    /// `ScrollView` de repli en tailles d'accessibilité.
    @ViewBuilder
    private var stepContainer: some View {
        let page = ZStack {
            stepPage
                .id(controller.step)
                .transition(slideTransition)
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.18) : .spring(response: 0.38, dampingFraction: 0.86), value: controller.step)

        if dynamicTypeSize.isAccessibilitySize {
            ScrollView {
                page
            }
        } else {
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var stepPage: some View {
        Group {
            if controller.step == .welcome {
                welcomeStepView
            } else {
                VStack(alignment: .leading, spacing: 28) {
                    headerView
                    stepContentView
                }
            }
        }
        .padding(.horizontal, LoopMeasure.screenGutter)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var slideTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .asymmetric(
            insertion: .move(edge: controller.forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: controller.forward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(controller.step.title)
                .font(OnboardingType.pageTitle)
                .foregroundStyle(LoopColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($isTitleFocused)

            if !controller.step.subtitle.isEmpty {
                Text(controller.step.subtitle)
                    .font(OnboardingType.pageSubtitle)
                    .foregroundStyle(LoopColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Step Router

    @ViewBuilder
    private var stepContentView: some View {
        switch controller.step {
        case .welcome:
            EmptyView()
        case .manifesto:
            manifestoStepView
        case .healthKit:
            healthKitStepView
        case .band:
            bandStepView
        case .profile:
            profileStepView
        case .goals:
            goalsStepView
        case .sync:
            syncStepView
        case .ready:
            readyStepView
        }
    }

    // MARK: - 01 Welcome

    private var welcomeStepView: some View {
        VStack(spacing: 32) {
            if isRestoringBackup {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(NSLocalizedString("onboarding.welcome.restoring", tableName: "Base", comment: ""))
                        .font(LoopType.body.weight(.medium))
                        .foregroundStyle(LoopColor.textPrimary)
                    Spacer(minLength: 0)
                }
                .padding(LoopMeasure.cardPadding)
                .loopCard(.card)
            }

            if let error = controller.backupErrorMessage {
                let desc = NSLocalizedString("onboarding.welcome.error.desc", tableName: "Base", comment: "")
                statusBanner(
                    title: NSLocalizedString("onboarding.welcome.error.title", tableName: "Base", comment: ""),
                    message: error.isEmpty ? desc : "\(desc) (\(error))",
                    state: .poor
                )
            }

            LoopMark()

            Text(controller.step.title)
                .font(OnboardingType.pageTitle)
                .foregroundStyle(LoopColor.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($isTitleFocused)

            welcomeCircles
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            if reduceMotion {
                ringProgress = 1
            } else {
                ringProgress = 0
                withAnimation(.easeOut(duration: 0.9).delay(0.2)) {
                    ringProgress = 1
                }
            }
        }
    }

    /// Trois cercles côte à côte, dans l'ordre et les teintes de l'accueil (Sommeil · Récupération · Strain),
    /// avec une valeur d'exemple dans chacun. Purement illustratif.
    private var welcomeCircles: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                welcomeCircle(color: TodayRingModel.sleepColor, fraction: 0.86, maxValue: 1, value: "86", unit: "%")
                welcomeCircle(color: TodayRingModel.recoveryColor(score: 72), fraction: 0.72, maxValue: 1, value: "72", unit: "%")
                welcomeCircle(color: TodayRingModel.strainColor, fraction: 11.4, maxValue: 21, value: Double(11.4).formatted(.number.precision(.fractionLength(1))), unit: nil)
            }

            badge(
                text: NSLocalizedString("onboarding.welcome.preview.badge", tableName: "Base", comment: ""),
                state: .neutral
            )
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(NSLocalizedString("onboarding.welcome.rings.a11y", tableName: "Base", comment: ""))
    }

    private func welcomeCircle(color: Color, fraction: Double, maxValue: Double, value: String, unit: String?) -> some View {
        ZStack {
            RingView(
                color: color,
                current: fraction * ringProgress,
                maxValue: maxValue,
                targetMin: 0,
                targetMax: 0,
                lineWidth: 10
            )
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value)
                    .font(OnboardingType.value)
                    .foregroundStyle(LoopColor.textPrimary)
                if let unit {
                    Text(unit)
                        .font(LoopType.label.weight(.semibold))
                        .foregroundStyle(LoopColor.textSecondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 14)
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 112)
    }

    // MARK: - 02 Manifesto

    private var manifestoStepView: some View {
        VStack(alignment: .leading, spacing: 18) {
            iconRow(
                symbol: "checkmark.circle.fill",
                tint: HealthState.good.color,
                title: NSLocalizedString("onboarding.manifesto.calibrated.title", tableName: "Base", comment: "")
            )
            divider
            iconRow(
                symbol: "lock.shield.fill",
                tint: Metric.strain.tint,
                title: NSLocalizedString("onboarding.manifesto.local.title", tableName: "Base", comment: "")
            )
            divider
            iconRow(
                symbol: "info.circle.fill",
                tint: HealthState.neutral.color,
                title: NSLocalizedString("onboarding.manifesto.estimates.title", tableName: "Base", comment: "")
            )
        }
        .padding(.horizontal, LoopMeasure.cardPadding + 4)
        .padding(.vertical, 22)
        .loopCard(.card)
    }

    // MARK: - 03 HealthKit

    private var healthKitStepView: some View {
        VStack(spacing: 16) {
            if !HealthKitImporter.isAvailable {
                statusBanner(
                    title: NSLocalizedString("onboarding.health.unavailable.title", tableName: "Base", comment: ""),
                    state: .fair
                )
            } else if healthRequested {
                statusBanner(
                    title: NSLocalizedString("onboarding.health.privacy.title", tableName: "Base", comment: ""),
                    state: .good
                )
            }

            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(NSLocalizedString("onboarding.health.card.header", tableName: "Base", comment: ""))
                        .font(OnboardingType.rowTitle)
                        .foregroundStyle(LoopColor.textPrimary)
                    Spacer()
                    badge(
                        text: NSLocalizedString("onboarding.health.badge.readonly", tableName: "Base", comment: ""),
                        state: .good
                    )
                }

                iconRow(
                    symbol: "figure.run",
                    tint: Metric.energy.tint,
                    title: NSLocalizedString("onboarding.health.item.workouts.title", tableName: "Base", comment: ""),
                    detail: NSLocalizedString("onboarding.health.item.workouts.desc", tableName: "Base", comment: "")
                )
                divider
                iconRow(
                    symbol: "waveform.path.ecg",
                    tint: Metric.hrv.tint,
                    title: NSLocalizedString("onboarding.health.item.biometrics.title", tableName: "Base", comment: ""),
                    detail: NSLocalizedString("onboarding.health.item.biometrics.desc", tableName: "Base", comment: "")
                )
                divider
                iconRow(
                    symbol: "heart.text.square.fill",
                    tint: Metric.cardio.tint,
                    title: NSLocalizedString("onboarding.health.item.profile.title", tableName: "Base", comment: ""),
                    detail: NSLocalizedString("onboarding.health.item.profile.desc", tableName: "Base", comment: "")
                )
            }
            .padding(.horizontal, LoopMeasure.cardPadding + 4)
            .padding(.vertical, 20)
            .loopCard(.card)
        }
    }

    // MARK: - 04 Band

    private var isBluetoothOff: Bool {
        if CBCentralManager.authorization == .denied || CBCentralManager.authorization == .restricted {
            return true
        }
        return connection.state.log.last?.contains("Bluetooth not powered on") == true
    }

    /// Échec visible (Bluetooth coupé, délai de recherche dépassé, association refusée),
    /// sauf si un bracelet a entre-temps été détecté ou connecté.
    private var bandHasFailed: Bool {
        switch connection.phase {
        case .connected, .detected:
            return false
        default:
            return isBluetoothOff || bandScanTimedOut || bondingFailed
        }
    }

    private var bandStepView: some View {
        VStack(spacing: 24) {
            bandLedVisual

            bandStatusLine

            if bandHasFailed {
                troubleshootingCard
            }
        }
        .frame(maxWidth: .infinity)
        .task {
            await connection.bootstrap()
            if !reduceMotion {
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    isLedPulsing = true
                }
            }
        }
        .onChange(of: connection.phase) { oldPhase, newPhase in
            previousPhase = oldPhase
            if oldPhase == .bonding && newPhase == .noSensor {
                bondingFailed = true
            }
            if newPhase == .scanning {
                bandScanTimedOut = false
                bondingFailed = false
                startScanTimeout()
            } else {
                scanTimerTask?.cancel()
            }
        }
    }

    private var bandVisualTint: Color {
        if bandHasFailed { return HealthState.fair.color }
        if connection.phase == .connected { return HealthState.good.color }
        return Metric.strain.tint
    }

    /// La LED ne clignote qu'en attente / recherche / association, jamais en Reduce Motion.
    private var bandLedIsLit: Bool {
        guard !reduceMotion, !bandHasFailed, connection.phase != .connected else { return true }
        return isLedPulsing
    }

    private var bandLedVisual: some View {
        let tint = bandVisualTint
        let lit = bandLedIsLit
        return ZStack {
            Circle()
                .fill(tint.opacity(0.08))
                .scaleEffect(lit ? 1.0 : 0.88)
            Circle()
                .fill(tint.opacity(0.14))
                .padding(32)
                .scaleEffect(lit ? 1.04 : 0.94)
            Circle()
                .fill(LoopColor.surfaceCard)
                .overlay(Circle().strokeBorder(LoopColor.strokeCard, lineWidth: 1))
                .padding(64)

            if connection.phase == .connected {
                Image(systemName: "checkmark")
                    .font(OnboardingType.value)
                    .foregroundStyle(tint)
            } else if bandHasFailed {
                Image(systemName: "exclamationmark")
                    .font(OnboardingType.value)
                    .foregroundStyle(tint)
            } else {
                Capsule()
                    .fill(tint)
                    .frame(width: 10, height: 42)
                    .opacity(lit ? 1 : 0.3)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 220, maxHeight: 220)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    private var bandStatusLine: some View {
        VStack(spacing: 6) {
            Text(bandStatusTitle)
                .font(OnboardingType.rowTitle)
                .foregroundStyle(LoopColor.textPrimary)
            if let detail = bandStatusDetail {
                Text(detail)
                    .font(OnboardingType.rowDetail)
                    .foregroundStyle(LoopColor.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var bandStatusTitle: String {
        if bandHasFailed {
            if isBluetoothOff {
                return NSLocalizedString("onboarding.band.status.bt_off", tableName: "Base", comment: "")
            }
            if bondingFailed {
                return NSLocalizedString("onboarding.band.status.bonding_failed", tableName: "Base", comment: "")
            }
            return NSLocalizedString("onboarding.band.status.no_sensor", tableName: "Base", comment: "")
        }
        switch connection.phase {
        case .detected:
            return NSLocalizedString("onboarding.band.status.detected", tableName: "Base", comment: "")
        case .connected:
            return NSLocalizedString("onboarding.band.status.connected", tableName: "Base", comment: "")
        case .scanning:
            return NSLocalizedString("onboarding.band.status.scanning", tableName: "Base", comment: "")
        case .bonding:
            return NSLocalizedString("onboarding.band.status.bonding", tableName: "Base", comment: "")
        case .noSensor:
            return NSLocalizedString("onboarding.band.status.idle", tableName: "Base", comment: "")
        }
    }

    private var bandStatusDetail: String? {
        if bandHasFailed {
            return isBluetoothOff
                ? NSLocalizedString("onboarding.band.status.bt_off_hint", tableName: "Base", comment: "")
                : nil
        }
        switch connection.phase {
        case .detected(let name, _, let batteryLevel):
            return String(
                format: NSLocalizedString("onboarding.band.status.detected_detail", tableName: "Base", comment: ""),
                name,
                Int((batteryLevel * 100).rounded())
            )
        case .connected:
            return connection.state.discoveredDeviceName ?? "WHOOP 4.0"
        case .noSensor:
            return NSLocalizedString("onboarding.band.status.idle_hint", tableName: "Base", comment: "")
        case .scanning, .bonding:
            return nil
        }
    }

    private var troubleshootingCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            checkRow(number: 1, text: NSLocalizedString("onboarding.band.check.1", tableName: "Base", comment: ""))
            divider
            checkRow(number: 2, text: NSLocalizedString("onboarding.band.check.2", tableName: "Base", comment: ""))
        }
        .padding(LoopMeasure.cardPadding)
        .loopCard(.card)
    }

    private func checkRow(number: Int, text: String) -> some View {
        HStack(spacing: 14) {
            Text("\(number)")
                .font(LoopType.body.weight(.bold))
                .foregroundStyle(Metric.strain.tint)
                .frame(width: 32, height: 32)
                .background(LoopColor.surfaceNested, in: Circle())
            Text(text)
                .font(OnboardingType.rowDetail)
                .foregroundStyle(LoopColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func startScanTimeout() {
        scanTimerTask?.cancel()
        scanTimerTask = Task {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            if !Task.isCancelled && connection.phase == .scanning {
                await MainActor.run {
                    bandScanTimedOut = true
                }
            }
        }
    }

    // MARK: - 05 Profile

    private var profileStepView: some View {
        VStack(spacing: 12) {
            VStack(spacing: 0) {
                profileWheels
                    .padding(.top, 14)

                divider
                    .padding(.top, 6)

                maxHRRow
                    .padding(.vertical, 14)

                if isMaxHRManual {
                    wheelPicker(
                        selection: intBinding(for: $controller.maxHRText, range: Self.maxHRRange, fallback: manualMaxHRFallback),
                        range: Self.maxHRRange,
                        label: NSLocalizedString("onboarding.profile.maxhr.label", tableName: "Base", comment: ""),
                        unit: "bpm",
                        isSet: true
                    )
                    .frame(height: 110)
                    .padding(.bottom, 8)
                }
            }
            .padding(.horizontal, LoopMeasure.cardPadding)
            .loopCard(.card)

            if let error = controller.profileError {
                profileErrorLine(error)
            }
        }
    }

    /// Âge, taille et poids : trois roulettes côte à côte (empilées en tailles d'accessibilité).
    private var profileWheels: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12))
            : AnyLayout(HStackLayout(spacing: 4))
        return layout {
            profileColumn(
                label: NSLocalizedString("onboarding.profile.age.label", tableName: "Base", comment: ""),
                unit: NSLocalizedString("onboarding.profile.age.unit", tableName: "Base", comment: ""),
                text: $controller.ageText,
                range: Self.ageRange,
                fallback: 30
            )
            profileColumn(
                label: NSLocalizedString("onboarding.profile.height.label", tableName: "Base", comment: ""),
                unit: "cm",
                text: $controller.heightText,
                range: Self.heightRange,
                fallback: 175
            )
            profileColumn(
                label: NSLocalizedString("onboarding.profile.weight.label", tableName: "Base", comment: ""),
                unit: "kg",
                text: $controller.weightText,
                range: Self.weightRange,
                fallback: 70
            )
        }
    }

    private func profileColumn(label: String, unit: String, text: Binding<String>, range: ClosedRange<Int>, fallback: Int) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(OnboardingType.rowTitle)
                .foregroundStyle(LoopColor.textPrimary)
            wheelPicker(
                selection: intBinding(for: text, range: range, fallback: fallback),
                range: range,
                label: label,
                unit: unit,
                isSet: parsedInt(text.wrappedValue).map { range.contains($0) } ?? false
            )
            .frame(height: 150)
            Text(unit)
                .font(OnboardingType.rowDetail)
                .foregroundStyle(LoopColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// Roulette entière. Une valeur non encore choisie est affichée atténuée.
    private func wheelPicker(selection: Binding<Int>, range: ClosedRange<Int>, label: String, unit: String, isSet: Bool) -> some View {
        Picker(selection: selection) {
            ForEach(Array(range), id: \.self) { value in
                Text("\(value)")
                    .font(OnboardingType.value)
                    .monospacedDigit()
                    .tag(value)
            }
        } label: {
            Text(label)
        }
        .pickerStyle(.wheel)
        .labelsHidden()
        .opacity(isSet ? 1 : 0.5)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text("\(selection.wrappedValue) \(unit)"))
    }

    /// Lie un champ texte du contrôleur à une roulette : lecture tolérante (vide, décimale ou hors
    /// plage → valeur par défaut affichée), écriture uniquement quand l'utilisateur fait tourner la roulette.
    private func intBinding(for text: Binding<String>, range: ClosedRange<Int>, fallback: Int) -> Binding<Int> {
        Binding(
            get: {
                if let value = parsedInt(text.wrappedValue), range.contains(value) { return value }
                return min(max(fallback, range.lowerBound), range.upperBound)
            },
            set: { newValue in
                text.wrappedValue = "\(newValue)"
                if controller.profileError != nil { controller.profileError = nil }
            }
        )
    }

    private func parsedInt(_ text: String) -> Int? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard !clean.isEmpty, let value = Double(clean) else { return nil }
        return Int(value.rounded())
    }

    private var isMaxHRManual: Bool {
        !controller.maxHRText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var manualMaxHRFallback: Int {
        controller.estimatedMaxHRFromAge ?? 190
    }

    private var maxHRRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(NSLocalizedString("onboarding.profile.maxhr.label", tableName: "Base", comment: ""))
                    .font(OnboardingType.rowTitle)
                    .foregroundStyle(LoopColor.textPrimary)
                Text(isMaxHRManual
                     ? NSLocalizedString("onboarding.profile.maxhr.manual", tableName: "Base", comment: "")
                     : maxHRAutoTag)
                    .font(OnboardingType.rowDetail)
                    .foregroundStyle(LoopColor.textSecondary)
            }
            Spacer(minLength: 8)
            Toggle(isOn: Binding(
                get: { isMaxHRManual },
                set: { manual in
                    if manual {
                        let start = min(max(manualMaxHRFallback, Self.maxHRRange.lowerBound), Self.maxHRRange.upperBound)
                        controller.maxHRText = "\(start)"
                    } else {
                        controller.maxHRText = ""
                    }
                    if controller.profileError == .invalidMaxHR { controller.profileError = nil }
                }
            )) {
                Text(NSLocalizedString("onboarding.profile.maxhr.manual", tableName: "Base", comment: ""))
            }
            .labelsHidden()
            .tint(Metric.strain.tint)
            .accessibilityLabel(NSLocalizedString("onboarding.profile.maxhr.manual", tableName: "Base", comment: ""))
        }
    }

    private var maxHRAutoTag: String {
        if let est = controller.estimatedMaxHRFromAge {
            return String(format: NSLocalizedString("onboarding.profile.maxhr.tag_auto", tableName: "Base", comment: ""), est)
        }
        return NSLocalizedString("onboarding.profile.maxhr.tag_default", tableName: "Base", comment: "")
    }

    /// Erreur de validation en une ligne courte sous la carte.
    private func profileErrorLine(_ error: OnboardingProfileError) -> some View {
        HStack(spacing: 8) {
            Image(systemName: HealthState.poor.symbol)
                .foregroundStyle(HealthState.poor.color)
                .accessibilityHidden(true)
            Text(NSLocalizedString(errorKey(error), tableName: "Base", comment: ""))
                .foregroundStyle(LoopColor.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 0)
        }
        .font(LoopType.body.weight(.medium))
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    private func errorKey(_ error: OnboardingProfileError) -> String {
        switch error {
        case .invalidMaxHR: return "onboarding.profile.error.maxhr"
        case .invalidAge: return "onboarding.profile.error.age"
        case .invalidHeight: return "onboarding.profile.error.height"
        case .invalidWeight: return "onboarding.profile.error.weight"
        }
    }

    // MARK: - 06 Goals

    private var goalsStepView: some View {
        VStack(alignment: .leading, spacing: 16) {
            let columns = dynamicTypeSize.isAccessibilitySize
                ? [GridItem(.flexible())]
                : [GridItem(.flexible(), spacing: LoopMeasure.gridSpacing), GridItem(.flexible(), spacing: LoopMeasure.gridSpacing)]

            LazyVGrid(columns: columns, spacing: LoopMeasure.gridSpacing) {
                ForEach(OnboardingSportOption.allCases) { sport in
                    let isSelected = controller.selectedSports.contains(sport.workoutKind.rawValue)
                    Button {
                        controller.toggleSport(sport.workoutKind.rawValue)
                    } label: {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Image(systemName: sport.symbol)
                                    .font(OnboardingType.rowIcon)
                                    .foregroundStyle(isSelected ? Metric.strain.tint : LoopColor.textSecondary)
                                    .frame(width: 36, height: 36, alignment: .leading)
                                Spacer(minLength: 4)
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(OnboardingType.rowTitle)
                                    .foregroundStyle(isSelected ? Metric.strain.tint : LoopColor.trackEmpty)
                            }
                            Text(sport.title)
                                .font(OnboardingType.rowTitle)
                                .foregroundStyle(LoopColor.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .loopCard(.card, cornerRadius: LoopMeasure.radiusTile)
                        .overlay(
                            RoundedRectangle(cornerRadius: LoopMeasure.radiusTile, style: .continuous)
                                .strokeBorder(isSelected ? Metric.strain.tint : Color.clear, lineWidth: 2)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }

            Text(NSLocalizedString("onboarding.goals.note", tableName: "Base", comment: ""))
                .font(OnboardingType.rowDetail)
                .foregroundStyle(LoopColor.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 07 Sync

    private var isBandPaused: Bool {
        if case .strapStuck = syncCoordinator.status { return true }
        if case .error = syncCoordinator.status { return true }
        return connection.state.backfilling && connection.phase == .noSensor
    }

    private var isHealthSyncing: Bool {
        healthImporter.isSyncing || sampleImporter.isSyncing
    }

    private var syncStepView: some View {
        VStack(alignment: .leading, spacing: 20) {
            syncRow(
                symbol: healthImporter.authorization == .requested ? "checkmark.circle.fill" : "heart.text.square.fill",
                tint: healthImporter.authorization == .requested ? HealthState.good.color : LoopColor.textSecondary,
                title: NSLocalizedString("onboarding.sync.health.title", tableName: "Base", comment: ""),
                badgeText: healthBadgeTitle,
                badgeState: healthBadgeState,
                fraction: isHealthSyncing ? nil : (healthImporter.authorization == .requested ? 1.0 : 0.0),
                barTint: healthImporter.authorization == .requested && !isHealthSyncing ? HealthState.good.color : Metric.strain.tint
            )

            divider

            syncRow(
                symbol: Metric.strain.symbol,
                tint: Metric.strain.tint,
                title: NSLocalizedString("onboarding.sync.band.title", tableName: "Base", comment: ""),
                badgeText: bandBadgeTitle,
                badgeState: bandBadgeState,
                fraction: bandSyncFraction,
                barTint: isBandPaused ? HealthState.fair.color : (connection.phase == .connected ? HealthState.good.color : Metric.strain.tint)
            )

            divider

            syncRow(
                symbol: "waveform.path.ecg",
                tint: Metric.hrv.tint,
                title: NSLocalizedString("onboarding.sync.engine.title", tableName: "Base", comment: ""),
                badgeText: repository.cache.daily.count > 0
                    ? String(format: NSLocalizedString("onboarding.sync.engine.days_progress", tableName: "Base", comment: ""), min(repository.cache.daily.count, 28), 28)
                    : NSLocalizedString("onboarding.sync.badge.waiting", tableName: "Base", comment: ""),
                badgeState: repository.cache.daily.count > 0 ? .fair : .neutral,
                fraction: engineSyncFraction,
                barTint: Metric.hrv.tint
            )
        }
        .padding(.horizontal, LoopMeasure.cardPadding + 4)
        .padding(.vertical, 22)
        .loopCard(.card)
        .task {
            if healthImporter.authorization == .requested && !isHealthSyncing {
                Task {
                    await healthImporter.sync(requestAccess: false)
                    await sampleImporter.importAll(requestAccess: false)
                    repository.requestRefresh(force: false)
                }
            } else {
                repository.requestRefresh(force: false)
            }
        }
    }

    private func syncRow(
        symbol: String,
        tint: Color,
        title: String,
        badgeText: String,
        badgeState: HealthState,
        fraction: Double?,
        barTint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(OnboardingType.rowIcon)
                    .foregroundStyle(tint)
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)
                Text(title)
                    .font(OnboardingType.rowTitle)
                    .foregroundStyle(LoopColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 8)
                badge(text: badgeText, state: badgeState)
            }
            .accessibilityElement(children: .combine)

            // Sans valeur mesurable (import en cours), pas de barre : le badge suffit.
            if let fraction {
                syncProgressBar(fraction: fraction, tint: barTint)
                    .padding(.leading, 50)
            }
        }
    }

    private func syncProgressBar(fraction: Double, tint: Color) -> some View {
        let clamped = min(max(fraction, 0), 1)
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LoopColor.trackEmpty)
                Capsule()
                    .fill(tint)
                    .frame(width: geo.size.width * clamped)
            }
        }
        .frame(height: 5)
        .accessibilityElement(children: .ignore)
        .accessibilityValue("\(Int((clamped * 100).rounded())) %")
    }

    /// `nil` quand aucune fraction réelle n'est connue (transfert, pause, recherche).
    private var bandSyncFraction: Double? {
        if case .syncing = syncCoordinator.status { return nil }
        if connection.phase == .connected || syncCoordinator.status == .connectedIdle { return 1.0 }
        if isBandPaused { return nil }
        if connection.phase == .scanning || connection.phase == .bonding { return nil }
        return 0.0
    }

    private var engineSyncFraction: Double {
        if let progress = repository.computeProgress, progress.total > 0 {
            return Double(progress.completed) / Double(progress.total)
        }
        if repository.cache.daily.count > 0 {
            return min(Double(repository.cache.daily.count) / 28.0, 1.0)
        }
        return 0.0
    }

    private var healthBadgeTitle: String {
        if isHealthSyncing {
            return NSLocalizedString("onboarding.sync.badge.syncing", tableName: "Base", comment: "")
        } else if healthImporter.authorization == .requested {
            return NSLocalizedString("onboarding.sync.badge.done", tableName: "Base", comment: "")
        } else {
            return NSLocalizedString("onboarding.sync.badge.not_connected", tableName: "Base", comment: "")
        }
    }

    private var healthBadgeState: HealthState {
        if isHealthSyncing {
            return .neutral
        } else if healthImporter.authorization == .requested {
            return .good
        } else {
            return .neutral
        }
    }

    private var bandBadgeTitle: String {
        if isBandPaused {
            return NSLocalizedString("onboarding.sync.badge.paused", tableName: "Base", comment: "")
        }
        if case .syncing = syncCoordinator.status {
            return NSLocalizedString("onboarding.sync.badge.syncing", tableName: "Base", comment: "")
        }
        switch connection.phase {
        case .connected, .detected:
            return NSLocalizedString("onboarding.sync.badge.ready", tableName: "Base", comment: "")
        case .scanning, .bonding:
            return NSLocalizedString("onboarding.sync.badge.syncing", tableName: "Base", comment: "")
        case .noSensor:
            if syncCoordinator.status == .connectedIdle {
                return NSLocalizedString("onboarding.sync.badge.ready", tableName: "Base", comment: "")
            }
            return NSLocalizedString("onboarding.sync.badge.offline", tableName: "Base", comment: "")
        }
    }

    private var bandBadgeState: HealthState {
        if isBandPaused { return .fair }
        if case .syncing = syncCoordinator.status { return .neutral }
        switch connection.phase {
        case .connected: return .good
        case .detected: return .good
        case .scanning, .bonding: return .neutral
        case .noSensor: return syncCoordinator.status == .connectedIdle ? .good : .neutral
        }
    }

    // MARK: - 08 Ready

    private var readyStepView: some View {
        VStack(spacing: 28) {
            Image(systemName: "checkmark.circle.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .foregroundStyle(Metric.strain.tint)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)

            dailyGuidancePreviewCard
        }
    }

    private var hasActionableDailyData: Bool {
        if let report = repository.trainingReport,
           TrainingAdviceModel.make(insights: report.insights, isLoading: false).phase != .absent {
            return true
        }
        if let daily = repository.cache.daily.last, !daily.isExpress {
            return true
        }
        return false
    }

    @ViewBuilder
    private var dailyGuidancePreviewCard: some View {
        if hasActionableDailyData {
            let reportInsights = repository.trainingReport?.insights ?? []
            let adviceModel = TrainingAdviceModel.make(insights: reportInsights, isLoading: repository.isRefreshing)
            // Sans cible d'effort calculée, aucune consigne chiffrée n'est inventée.
            let doText: String? = {
                if let daily = repository.cache.daily.last, !daily.isExpress, let target = daily.targetStrain {
                    return TodayFocus.make(metric: daily, strainTarget: target).message
                }
                if let insight = adviceModel.insight, adviceModel.phase == .ready || adviceModel.phase == .partial {
                    return TrainingInsightRenderer.short(insight, strings: TrainingAdviceStrings.table)
                }
                return nil
            }()
            let avoidText: String = {
                if let conflict = reportInsights.first(where: { $0.state == .contradictory }) {
                    return TrainingInsightRenderer.short(conflict, strings: TrainingAdviceStrings.table)
                }
                if let insight = adviceModel.insight, adviceModel.phase == .calibration {
                    return TrainingInsightRenderer.short(insight, strings: TrainingAdviceStrings.table)
                }
                return NSLocalizedString("onboarding.ready.avoid.default", tableName: "Base", comment: "")
            }()

            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(NSLocalizedString("onboarding.ready.card.title", tableName: "Base", comment: ""))
                        .font(OnboardingType.rowTitle)
                        .foregroundStyle(LoopColor.textPrimary)
                    Spacer()
                    badge(
                        text: String(format: NSLocalizedString("onboarding.ready.badge.calibrating", tableName: "Base", comment: ""), max(1, min(repository.cache.daily.count, 28)), 28),
                        state: repository.cache.daily.count >= 28 ? .good : .fair
                    )
                }

                if let doText {
                    adviceLine(
                        state: .good,
                        label: NSLocalizedString("onboarding.ready.do.title", tableName: "Base", comment: ""),
                        text: doText
                    )
                }
                adviceLine(
                    state: .fair,
                    label: NSLocalizedString("onboarding.ready.avoid.title", tableName: "Base", comment: ""),
                    text: avoidText
                )

                if let insight = adviceModel.insight {
                    TrainingConfidenceRow(confidence: insight.confidence, experimental: insight.isExperimental)
                }
            }
            .padding(.horizontal, LoopMeasure.cardPadding + 4)
            .padding(.vertical, 20)
            .loopCard(.card)
        } else {
            // Jour 1 : état sobre, aucune recommandation chiffrée inventée.
            HStack(spacing: 16) {
                Image(systemName: HealthState.neutral.symbol)
                    .font(OnboardingType.rowIcon)
                    .foregroundStyle(HealthState.neutral.color)
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("onboarding.ready.cold.headline", tableName: "Base", comment: ""))
                        .font(OnboardingType.rowTitle)
                        .foregroundStyle(LoopColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(NSLocalizedString("onboarding.ready.cold.desc", tableName: "Base", comment: ""))
                        .font(OnboardingType.rowDetail)
                        .foregroundStyle(LoopColor.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, LoopMeasure.cardPadding + 4)
            .padding(.vertical, 20)
            .loopCard(.card)
            .accessibilityElement(children: .combine)
        }
    }

    private func adviceLine(state: HealthState, label: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: state.symbol)
                .font(LoopType.body)
                .foregroundStyle(state.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(LoopType.label.weight(.semibold))
                    .foregroundStyle(LoopColor.textSecondary)
                Text(text)
                    .font(LoopType.body)
                    .foregroundStyle(LoopColor.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label + ", " + text)
    }

    // MARK: - Bottom Action Dock

    private var bottomActionDock: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(spacing: 10) {
                Button {
                    handlePrimaryAction()
                } label: {
                    HStack(spacing: 8) {
                        if isPrimaryLoading {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        }
                        Text(primaryButtonTitle)
                            .font(LoopType.body.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 54)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .tint(Metric.strain.tint)
                .disabled(isPrimaryDisabled)

                if let secondaryTitle = secondaryButtonTitle {
                    Button {
                        handleSecondaryAction()
                    } label: {
                        Text(secondaryTitle)
                            .font(LoopType.body.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 48)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .disabled(controller.step == .welcome && isRestoringBackup)
                }
            }
        }
        .padding(.horizontal, LoopMeasure.screenGutter)
        .padding(.bottom, 12)
    }

    private var continueTitle: String {
        NSLocalizedString("onboarding.cta.continue", tableName: "Base", comment: "")
    }

    private var primaryButtonTitle: String {
        switch controller.step {
        case .welcome:
            return NSLocalizedString("onboarding.welcome.cta.primary", tableName: "Base", comment: "")
        case .manifesto, .profile, .goals:
            return continueTitle
        case .healthKit:
            if isRequestingHealth {
                return NSLocalizedString("onboarding.health.requesting", tableName: "Base", comment: "")
            }
            return HealthKitImporter.isAvailable
                ? NSLocalizedString("onboarding.health.cta.primary", tableName: "Base", comment: "")
                : continueTitle
        case .band:
            switch connection.phase {
            case .connected:
                return continueTitle
            case .detected:
                return NSLocalizedString("onboarding.band.cta.pair", tableName: "Base", comment: "")
            case .scanning:
                return NSLocalizedString("onboarding.band.status.scanning", tableName: "Base", comment: "")
            case .bonding:
                return NSLocalizedString("onboarding.band.status.bonding", tableName: "Base", comment: "")
            case .noSensor:
                if bandScanTimedOut || bondingFailed || isBluetoothOff {
                    return NSLocalizedString("onboarding.band.cta.retry", tableName: "Base", comment: "")
                }
                return NSLocalizedString("onboarding.band.cta.search", tableName: "Base", comment: "")
            }
        case .sync:
            return NSLocalizedString("onboarding.sync.cta.primary", tableName: "Base", comment: "")
        case .ready:
            return NSLocalizedString("onboarding.ready.cta.primary", tableName: "Base", comment: "")
        }
    }

    private var secondaryButtonTitle: String? {
        switch controller.step {
        case .welcome:
            return NSLocalizedString("onboarding.welcome.cta.secondary", tableName: "Base", comment: "")
        case .healthKit:
            return NSLocalizedString("onboarding.health.cta.secondary", tableName: "Base", comment: "")
        case .band:
            return NSLocalizedString("onboarding.band.cta.secondary", tableName: "Base", comment: "")
        case .manifesto, .profile, .goals, .sync, .ready:
            return nil
        }
    }

    private var isPrimaryLoading: Bool {
        if controller.step == .welcome && isRestoringBackup { return true }
        if controller.step == .healthKit && isRequestingHealth { return true }
        if controller.step == .band && (connection.phase == .scanning || connection.phase == .bonding) { return true }
        return false
    }

    private var isPrimaryDisabled: Bool {
        if controller.step == .welcome && isRestoringBackup { return true }
        if controller.step == .healthKit && isRequestingHealth { return true }
        if controller.step == .band && (connection.phase == .scanning || connection.phase == .bonding) {
            return true
        }
        return false
    }

    private func handlePrimaryAction() {
        switch controller.step {
        case .welcome:
            controller.advance()
        case .manifesto:
            controller.advance()
        case .healthKit:
            if !HealthKitImporter.isAvailable {
                controller.advance()
            } else {
                requestHealthAccess()
            }
        case .band:
            handleBandPrimaryAction()
        case .profile:
            _ = controller.validateAndSaveProfile()
        case .goals:
            controller.saveGoalsAndAdvance()
        case .sync:
            controller.advance()
        case .ready:
            controller.finishOnboarding()
        }
    }

    private func handleSecondaryAction() {
        switch controller.step {
        case .welcome:
            showBackupImporter = true
        case .healthKit:
            controller.advance()
        case .band:
            controller.advance()
        default:
            break
        }
    }

    private func requestHealthAccess() {
        guard !isRequestingHealth else { return }
        isRequestingHealth = true
        Task {
            await healthImporter.requestAllAccess()
            await sampleImporter.refreshState()
            Task {
                await healthImporter.sync(requestAccess: false)
                await sampleImporter.importAll(requestAccess: false)
            }
            healthRequested = true
            let latestWeight = await loadLatestHealthWeightKg()
            controller.preloadFromPreferencesAndHealth(
                healthAge: UserPreferences.shared.healthAge,
                latestHealthWeightKg: latestWeight
            )
            isRequestingHealth = false
            controller.advance()
        }
    }

    private func loadLatestHealthWeightKg() async -> Double? {
        guard let path = try? StorePaths.defaultDatabasePath(),
              let store = try? await WhoopStore(path: path) else { return nil }
        let samples = (try? await store.healthSamples(
            type: HealthSampleKind.bodyMass.rawValue,
            from: 0,
            to: Date().timeIntervalSince1970 + 60
        )) ?? []
        return samples.last?.value
    }

    private func handleBandPrimaryAction() {
        switch connection.phase {
        case .connected:
            controller.advance()
        case .detected:
            connection.connectToDetectedDevice()
        case .noSensor:
            bandScanTimedOut = false
            bondingFailed = false
            connection.startScan()
        default:
            break
        }
    }

    // MARK: - Helpers

    private var divider: some View {
        Rectangle()
            .fill(LoopColor.strokeCard)
            .frame(height: 1)
    }

    /// Ligne de carte : grosse icône (≈ 28 pt) + titre Title 3 + sous-texte Body facultatif d'une ligne.
    private func iconRow(symbol: String, tint: Color, title: String, detail: String? = nil) -> some View {
        HStack(spacing: 16) {
            Image(systemName: symbol)
                .font(OnboardingType.rowIcon)
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(OnboardingType.rowTitle)
                    .foregroundStyle(LoopColor.textPrimary)
                if let detail {
                    Text(detail)
                        .font(OnboardingType.rowDetail)
                        .foregroundStyle(LoopColor.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// Bandeau d'état compact : une ligne de titre, message facultatif.
    private func statusBanner(title: String, message: String? = nil, state: HealthState) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: state.symbol)
                .font(LoopType.body.weight(.semibold))
                .foregroundStyle(state.color)
                .padding(.top, 2)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(LoopType.body.weight(.semibold))
                    .foregroundStyle(LoopColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let message {
                    Text(message)
                        .font(LoopType.label)
                        .foregroundStyle(LoopColor.textSecondary)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, LoopMeasure.cardPadding)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(state.color.opacity(0.12), in: RoundedRectangle(cornerRadius: LoopMeasure.radiusNested, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: LoopMeasure.radiusNested, style: .continuous)
                .strokeBorder(state.color.opacity(0.3), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    private func badge(text: String, state: HealthState) -> some View {
        HStack(spacing: 5) {
            Image(systemName: state.symbol)
            Text(text)
        }
        .font(OnboardingType.badge)
        .foregroundStyle(state.color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(LoopColor.surfaceNested, in: Capsule())
    }
}

#Preview {
    OnboardingView(connection: DeviceConnectionViewModel())
}
