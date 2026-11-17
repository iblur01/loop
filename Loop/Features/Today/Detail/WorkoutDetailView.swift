import SwiftUI

/// Détail d'une séance : en-tête (carte si tracé), mesures, effort perçu, zones (moteur) et courbe
/// de FC (si fournies), source. La séance est relue depuis le cache à chaque affichage pour
/// refléter une saisie RPE ou sa disparition (recalcul, rejet) sans garder de copie périmée.
struct WorkoutDetailView: View {
    let sessionID: String
    @ObservedObject var repository: LoopDataRepository
    /// Série FC de la séance (courbe) ; non exposée aujourd'hui, bloc masqué si nil. Les zones
    /// sont lues dans `session.heartRateZones` (moteur).
    var heartRateProfile: WorkoutHeartRateProfile? = nil
    /// Tracé GPS ; `HKWorkoutRoute` n'est pas importé, carte masquée si nil.
    var route: WorkoutRoute? = nil
    @Environment(\.dismiss) private var dismiss

    private var session: WorkoutSession? {
        repository.cache.workoutSessions.first { $0.id == sessionID }
    }

    private var isLoading: Bool {
        session == nil && repository.isRefreshing && repository.cache.workoutSessions.isEmpty
    }

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                VStack(spacing: 18) {
                    if let session {
                        WorkoutDetailHeader(session: session, route: route)
                            .padding(.bottom, 4)
                        WorkoutMetricsGrid(metrics: WorkoutFormat.metrics(session))
                        WorkoutEffortCard(session: session, repository: repository)
                        WorkoutHeartRateZonesCard(zones: session.heartRateZones)
                        WorkoutHeartRateCurve(profile: heartRateProfile, averageBpm: session.avgHr)
                        WorkoutSourcesCard(session: session)
                        ManualWorkoutDeleteButton(session: session, repository: repository) { dismiss() }
                    } else if isLoading {
                        ProgressView("Chargement")
                            .frame(maxWidth: .infinity, minHeight: 120)
                    } else {
                        missing
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 34)
            }
        }
        .navigationTitle(session.map(WorkoutFormat.title) ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    private var missing: some View {
        VStack(spacing: 6) {
            Text("today.seance.introuvable", tableName: "Today")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("today.elle.a.ete.supprimee.ou.recalculee", tableName: "Today")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding(18)
        .deviceSurface()
        .accessibilityElement(children: .combine)
    }
}
