import SwiftUI
import UIKit

/// Source Apple Santé : une seule action (connecter), puis synchronisation automatique.
/// Lecture seule. Textes localisés via la table `Base` (clés FR/EN dans les `Base.strings`).
struct HealthImportView: View {
    @StateObject private var importer = HealthKitImporter.shared
    @StateObject private var samples = HealthSampleImporter()
    @StateObject private var continued = HealthContinuedSync.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        ProfileSubpage {
            ProfileGroup {
                if importer.authorization == .unavailable {
                    ProfileActionRow(icon: "heart.slash", title: NSLocalizedString("Apple Santé n'est pas disponible sur cet appareil.", tableName: "Base", comment: ""))
                } else if !isConnected {
                    Button {
                        Task { await connect() }
                    } label: {
                        ProfileActionRow(icon: "heart.fill", title: NSLocalizedString("Connecter Apple Santé", tableName: "Base", comment: ""))
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                } else {
                    ProfileActionRow(
                        icon: isBusy ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill",
                        title: NSLocalizedString("health.permissions.requested", tableName: "Base", comment: ""),
                        subtitle: lastSync.map { String(format: NSLocalizedString("health.last_sync", tableName: "Base", comment: ""), $0.formatted(date: .abbreviated, time: .shortened)) }
                    ) {
                        if isBusy { ProgressView() }
                    }
                }

                if hasError {
                    hairline
                    ProfileStatusRow(text: NSLocalizedString("health.error.generic", tableName: "Base", comment: ""), symbol: "info.circle")
                }
                if isConnected {
                    hairline
                    Button {
                        Task { await connect() }
                    } label: {
                        ProfileActionRow(icon: "heart", title: NSLocalizedString("health.permissions.request", tableName: "Base", comment: ""))
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                    hairline
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    } label: {
                        ProfileActionRow(icon: "hand.raised", title: NSLocalizedString("health.permissions.review", tableName: "Base", comment: "")) {
                            ProfileChevron()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            if isConnected {
                ProfileFootnote(text: NSLocalizedString("health.permissions.explanation", tableName: "Base", comment: ""))
            }
        }
        .navigationTitle(NSLocalizedString("Apple Santé", tableName: "Base", comment: ""))
        .onChange(of: continued.finishedCount) {
            Task {
                await importer.refreshState()
                await samples.refreshState()
            }
        }
        .task {
            // Chaque ouverture resynchronise, sans action de l'utilisateur, si Santé est déjà connecté.
            await importer.refreshState()
            await samples.refreshState()
            guard isConnected else { return }
            await importer.sync(requestAccess: false)
            await samples.importAll(requestAccess: false)
        }
    }

    private var hairline: some View { ProfileHairline(inset: SettingsMetrics.hairlineInset) }

    // MARK: - État

    private var isConnected: Bool {
        importer.authorization == .requested && samples.authorization == .requested
    }

    private var isBusy: Bool { importer.isSyncing || samples.isSyncing || continued.isRunning }

    private var hasError: Bool {
        importer.lastError != nil || samples.lastError != nil
    }

    /// Dernière synchro réussie, toutes sources confondues.
    private var lastSync: Date? {
        let samplesDates = samples.states.values.compactMap { $0.lastSyncAt }
        return ([importer.lastImportAt].compactMap { $0 } + samplesDates).max()
    }

    /// iOS ne distingue pas refus et absence de données : on ne conclut au refus que si rien du tout n'est arrivé.
    private var likelyDenied: Bool {
        isConnected && !isBusy && importer.workoutCount == 0 && HealthSampleKind.allCases.allSatisfy { (samples.states[$0]?.count ?? 0) == 0 }
    }

    /// Demande l'accès une fois, puis lance le premier import complet (séances + données).
    @MainActor private func connect() async {
        await importer.requestAllAccess()
        guard importer.lastError == nil else { return }
        await importer.sync(requestAccess: false)
        await samples.importAll(requestAccess: false)
    }
}
