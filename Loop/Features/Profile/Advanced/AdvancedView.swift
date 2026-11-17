import SwiftUI
import UIKit

/// Advanced page — everything technical, debug, or destructive. Reached from Profile → Avancé.
/// Replaces the old "Maintenance" + "Debug" sections of `SettingsView`. Les confirmations portent le risque.
struct AdvancedView: View {
    @ObservedObject var repository: LoopDataRepository
    @ObservedObject var connection: DeviceConnectionViewModel
    @State private var showPurgeAllConfirm = false
    @State private var showFullRecalcConfirm = false
    @State private var showOnboardingConfirm = false

    var body: some View {
        ProfileSubpage {
            maintenanceSection
            debugSection
            onboardingSection
        }
        .navigationTitle(NSLocalizedString("Avancé", tableName: "Base", comment: ""))
    }

    private var hairline: some View { ProfileHairline(inset: SettingsMetrics.hairlineInset) }

    // MARK: - Maintenance

    @ViewBuilder
    private var maintenanceSection: some View {
        ProfileSection(title: NSLocalizedString("Maintenance", tableName: "Base", comment: "")) {
            ProfileGroup {
                Button {
                    showFullRecalcConfirm = true
                } label: {
                    ProfileActionRow(icon: "arrow.triangle.2.circlepath",
                                     title: NSLocalizedString("advanced.fullrecalc.title", tableName: "Base", comment: ""),
                                     subtitle: NSLocalizedString("advanced.fullrecalc.subtitle", tableName: "Base", comment: ""))
                }
                .buttonStyle(.plain)
                .disabled(repository.isRefreshing || repository.localMetricsEngine == nil)
                .confirmationDialog(
                    NSLocalizedString("advanced.fullrecalc.confirm.title", tableName: "Base", comment: ""),
                    isPresented: $showFullRecalcConfirm,
                    titleVisibility: .visible
                ) {
                    Button(NSLocalizedString("advanced.fullrecalc.confirm.action", tableName: "Base", comment: "")) { repository.requestRefresh(force: true) }
                    Button(NSLocalizedString("Annuler", tableName: "Base", comment: ""), role: .cancel) {}
                } message: {
                    Text(NSLocalizedString("advanced.fullrecalc.confirm.message", tableName: "Base", comment: ""))
                }

                hairline
                if repository.isPurging {
                    ProfileProgressRow(text: NSLocalizedString("Purge en cours…", tableName: "Base", comment: ""))
                } else {
                    Button {
                        showPurgeAllConfirm = true
                    } label: {
                        ProfileActionRow(icon: "trash", title: NSLocalizedString("Tout effacer", tableName: "Base", comment: ""), isDestructive: true)
                    }
                    .buttonStyle(.plain)
                    .disabled(repository.localMetricsEngine == nil)
                    .confirmationDialog(
                        NSLocalizedString("Supprimer TOUTES les données ?", tableName: "Base", comment: ""),
                        isPresented: $showPurgeAllConfirm,
                        titleVisibility: .visible
                    ) {
                        Button(NSLocalizedString("Tout supprimer", tableName: "Base", comment: ""), role: .destructive) { repository.purgeAll() }
                        Button(NSLocalizedString("Annuler", tableName: "Base", comment: ""), role: .cancel) {}
                    } message: {
                        Text(NSLocalizedString("Vide toutes les tables de mesures. Action irréversible — restaurable depuis une sauvegarde .loopbackup.", tableName: "Base", comment: ""))
                    }
                }
            }
        }
    }

    // MARK: - Debug

    @ViewBuilder
    private var debugSection: some View {
        ProfileSection(title: NSLocalizedString("Debug", tableName: "Base", comment: "")) {
            ProfileGroup {
                Button {
                    UIPasteboard.general.string = connection.state.log.joined(separator: "\n")
                } label: {
                    ProfileActionRow(icon: "doc.on.doc", title: NSLocalizedString("Copier les logs de connexion", tableName: "Base", comment: ""))
                }
                .buttonStyle(.plain)
                .disabled(connection.state.log.isEmpty)

#if DEBUG
                hairline
                Button {
                    connection.simulateCriticalBatteryLiveActivity()
                } label: {
                    ProfileActionRow(icon: "exclamationmark.triangle.fill", title: NSLocalizedString("Simuler batterie critique", tableName: "Base", comment: ""))
                }
                .buttonStyle(.plain)
                hairline
                Button {
                    connection.simulateChargingLiveActivity()
                } label: {
                    ProfileActionRow(icon: "bolt.fill", title: NSLocalizedString("Simuler bracelet en charge", tableName: "Base", comment: ""))
                }
                .buttonStyle(.plain)
                hairline
                Button {
                    connection.stopBatteryLiveActivitySimulation()
                } label: {
                    ProfileActionRow(icon: "xmark.circle", title: NSLocalizedString("Arrêter la simulation Live Activity", tableName: "Base", comment: ""))
                }
                .buttonStyle(.plain)
                hairline
                Button {
                    repository.requestRefresh(force: true)
                } label: {
                    ProfileActionRow(icon: "stopwatch", title: NSLocalizedString("Recalcul complet (mesure perf)", tableName: "Base", comment: ""))
                }
                .buttonStyle(.plain)
                .disabled(repository.isRefreshing)
#endif
            }
#if DEBUG
            ProfileFootnote(text: NSLocalizedString("advanced.perf.footer", tableName: "Base", comment: ""))
#endif
        }
    }

    // MARK: - Onboarding

    @ViewBuilder
    private var onboardingSection: some View {
        ProfileSection(title: NSLocalizedString("Onboarding", tableName: "Base", comment: "")) {
            ProfileGroup {
                Button {
                    showOnboardingConfirm = true
                } label: {
                    ProfileActionRow(icon: "arrow.counterclockwise", title: NSLocalizedString("Refaire l'onboarding", tableName: "Base", comment: ""), isDestructive: true)
                }
                .buttonStyle(.plain)
                .confirmationDialog(
                    NSLocalizedString("advanced.onboarding.confirm.title", tableName: "Base", comment: ""),
                    isPresented: $showOnboardingConfirm,
                    titleVisibility: .visible
                ) {
                    Button(NSLocalizedString("advanced.onboarding.confirm.action", tableName: "Base", comment: ""), role: .destructive) { UserPreferences.shared.resetOnboarding() }
                    Button(NSLocalizedString("Annuler", tableName: "Base", comment: ""), role: .cancel) {}
                } message: {
                    Text(NSLocalizedString("advanced.onboarding.confirm.message", tableName: "Base", comment: ""))
                }
            }
            ProfileFootnote(text: NSLocalizedString("advanced.onboarding.footer", tableName: "Base", comment: ""))
        }
    }
}
