import SwiftUI

// MARK: - Route

/// Destinations poussées depuis les lignes calmes de la page Profil.
enum ProfileRoute: Hashable {
    case backup
    case health
    case advanced
    case settings
    case wake
    case sleep
    case effort
}

// MARK: - ProfileView

/// Onglet Profil : qui je suis, ma FC max et mes objectifs, puis les portes vers les données et les
/// réglages. Édition corporelle en feuille, chaque objectif sur sa propre page. Une seule teinte (l'arc FC max).
struct ProfileView: View {
    @ObservedObject var repository: LoopDataRepository
    @EnvironmentObject private var connection: DeviceConnectionViewModel
    @EnvironmentObject private var backup: BackupCoordinator
    @ObservedObject private var prefs = UserPreferences.shared
    @EnvironmentObject private var router: AppRouter
    @State private var sheet: ProfileSheet?
    @State private var backupFromSettings = false

    private enum ProfileSheet: String, Identifiable {
        case measures
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LoopMeasure.sectionSpacing) {
                    ProfileHeader(prefs: prefs)
                        .padding(.top, 8)
                        .padding(.bottom, 4)

                    BodyProfileCard(prefs: prefs) { sheet = .measures }

                    goalsSection
                    dataSection
                    footer
                }
                .padding(.horizontal, LoopMeasure.screenGutter)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .background(LoopColor.bgBase.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle(NSLocalizedString("profile.title", tableName: "Base", comment: ""))
            // Bouton de barre native : iOS 26 le rend en Liquid Glass sans fond forcé. Raccourci vers Réglages.
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        router.profileRoute = .settings
                    } label: {
                        Label(NSLocalizedString("profile.nav.settings", tableName: "Base", comment: ""),
                              systemImage: "gearshape")
                    }
                }
            }
            .navigationDestination(item: $router.profileRoute) { route in
                switch route {
                case .backup:
                    BackupView(repository: repository, backup: backup)
                case .health:
                    HealthImportView()
                case .advanced:
                    AdvancedView(repository: repository, connection: connection)
                case .settings:
                    SettingsView(prefs: prefs) { backupFromSettings = true }
                        .navigationDestination(isPresented: $backupFromSettings) {
                            BackupView(repository: repository, backup: backup)
                        }
                case .wake:
                    WakeTargetView(prefs: prefs)
                case .sleep:
                    SleepGoalView(prefs: prefs)
                case .effort:
                    EffortDifficultyView(repository: repository, prefs: prefs)
                }
            }
            .sheet(item: $sheet) { current in
                switch current {
                case .measures:
                    BodyMeasuresEditor(prefs: prefs)
                }
            }
        }
    }

    // MARK: - Objectifs

    private var goalsSection: some View {
        section(NSLocalizedString("profile.section.goals", tableName: "Base", comment: "")) {
            group {
                ProfileValueRow(icon: "alarm", category: .wake,
                                title: NSLocalizedString("profile.goal.wake", tableName: "Base", comment: ""),
                                value: String(format: "%d:%02d", prefs.wakeHour, prefs.wakeMinute)) { router.profileRoute = .wake }
                hairline
                ProfileValueRow(icon: "bed.double", category: .wake,
                                title: NSLocalizedString("profile.goal.sleep", tableName: "Base", comment: ""),
                                value: GoalFormat.sleepText(minutes: prefs.sleepTargetMin)) { router.profileRoute = .sleep }
                hairline
                ProfileValueRow(icon: "flame", category: .effort,
                                title: NSLocalizedString("profile.goal.effort", tableName: "Base", comment: ""),
                                value: prefs.strainDifficultyLabel) { router.profileRoute = .effort }
            }
        }
    }

    // MARK: - Données et app

    private var dataSection: some View {
        section(NSLocalizedString("profile.section.data", tableName: "Base", comment: "")) {
            group {
                if HealthKitImporter.isAvailable {
                    ProfileNavRow(icon: "heart", category: .data,
                                  title: NSLocalizedString("profile.nav.health", tableName: "Base", comment: ""),
                                  subtitle: NSLocalizedString("profile.nav.health.sub", tableName: "Base", comment: "")) {
                        router.profileRoute = .health
                    }
                    hairline
                }
                ProfileNavRow(icon: "externaldrive", category: .data,
                              title: NSLocalizedString("profile.nav.backup", tableName: "Base", comment: ""),
                              subtitle: NSLocalizedString("profile.nav.backup.sub", tableName: "Base", comment: "")) {
                    router.profileRoute = .backup
                }
                hairline
                ProfileNavRow(icon: "wrench.and.screwdriver", category: .data,
                              title: NSLocalizedString("profile.nav.advanced", tableName: "Base", comment: ""),
                              subtitle: NSLocalizedString("profile.nav.advanced.sub", tableName: "Base", comment: "")) {
                    router.profileRoute = .advanced
                }
                hairline
                ProfileNavRow(icon: "gearshape", category: .data,
                              title: NSLocalizedString("profile.nav.settings", tableName: "Base", comment: ""),
                              subtitle: NSLocalizedString("profile.nav.settings.sub", tableName: "Base", comment: "")) {
                    router.profileRoute = .settings
                }
            }
        }
    }

    // MARK: - Pied

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let updated = repository.cache.updatedAt {
                Text(String(format: NSLocalizedString("profile.footer.lastCalc", tableName: "Base", comment: ""),
                            updated.formatted(date: .abbreviated, time: .shortened)))
            }
            Text(NSLocalizedString("profile.footer.disclaimer", tableName: "Base", comment: ""))
        }
        .font(LoopType.footnote)
        .foregroundStyle(LoopColor.textSecondary)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Chrome

    private func section<Content: View>(_ title: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        ProfileSection(title: title, content: content)
    }

    private func group<Content: View>(@ViewBuilder _ content: @escaping () -> Content) -> some View {
        ProfileGroup(content: content)
    }

    private var hairline: some View { ProfileHairline() }
}

#Preview {
    ProfileView(repository: LoopDataRepository())
        .environmentObject(DeviceConnectionViewModel())
        .environmentObject(BackupCoordinator(
            deviceId: "preview",
            store: { nil },
            suspend: {},
            resume: {},
            reloadCache: {}
        ))
        .environmentObject(AppRouter())
}
