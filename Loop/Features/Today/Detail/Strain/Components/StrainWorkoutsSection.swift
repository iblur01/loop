import SwiftUI

/// Séances du jour sélectionné, chacune ouvrant le détail (saisie de l'effort ressenti), et
/// point d'entrée « Ajouter une séance » (séance non enregistrée par la montre ni le bracelet).
/// Toujours affiché quand le dépôt est disponible : un jour sans séance garde l'ajout.
struct StrainWorkoutsSection: View {
    @ObservedObject var repository: LoopDataRepository
    let day: String
    @State private var showAddSheet = false

    var body: some View {
        let sessions = repository.workoutSessions(forDay: day)
        VStack(alignment: .leading, spacing: 4) {
                WidgetHeader(symbol: "figure.run", title: String(localized: "today.seances.du.jour", table: "Today"), tint: Metric.strain.tint,
                             trailing: sessions.count > 1 ? TodayL.format("today.final.sessions.count", String(sessions.count)) : nil)
                    .padding(.horizontal, LoopMeasure.cardPadding)
                    .padding(.top, LoopMeasure.cardPadding)
                    .padding(.bottom, 4)

                if sessions.isEmpty {
                    Text(ManualWorkoutL.text("manualWorkout.empty"))
                        .font(LoopType.label)
                        .foregroundStyle(LoopColor.textSecondary)
                        .padding(.horizontal, LoopMeasure.cardPadding)
                        .padding(.vertical, 4)
                }

                ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                    if index > 0 {
                        Divider().overlay(LoopColor.strokeCard).padding(.leading, LoopMeasure.cardPadding)
                    }
                    NavigationLink {
                        WorkoutDetailView(sessionID: session.id, repository: repository)
                    } label: {
                        WorkoutListRow(session: session)
                    }
                    .buttonStyle(.plain)
                }

                Divider().overlay(LoopColor.strokeCard).padding(.leading, LoopMeasure.cardPadding)
                Button { showAddSheet = true } label: {
                    Label(ManualWorkoutL.text("manualWorkout.add"), systemImage: "plus.circle")
                        .font(LoopType.body.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Metric.strain.tint)
                .padding(.horizontal, LoopMeasure.cardPadding)
        }
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .loopCard()
        .sheet(isPresented: $showAddSheet) {
            ManualWorkoutSheet(repository: repository, day: day)
        }
    }
}

private struct WorkoutListRow: View {
    let session: WorkoutSession

    /// An unrated session is the expected action of the page: it says so in words.
    private var rpeText: String {
        session.perceivedEffort.map { TodayL.format("today.final.effort.rating", String($0)) } ?? TodayL.text("today.final.workout.no.effort")
    }

    private var sport: WorkoutSport { WorkoutSport(kind: session.kind, sportType: session.sportType) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: sport.symbol)
                .font(.body.weight(.medium))
                .foregroundStyle(sport.tint)
                .frame(width: 28, alignment: .center)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(sport.title)
                    .font(LoopType.body.weight(.medium))
                    .foregroundStyle(LoopColor.textPrimary)
                Text([WorkoutFormat.duration(session), rpeText].compactMap { $0 }.joined(separator: " · "))
                    .font(LoopType.label)
                    .foregroundStyle(LoopColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(LoopColor.textSecondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, LoopMeasure.cardPadding)
        .padding(.vertical, 8)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(TodayL.text("today.final.workout.open.detail"))
    }
}
