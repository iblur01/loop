import SwiftUI

/// Bloc effort : saisie du RPE (rien n'est enregistré tant qu'aucune valeur n'est choisie) et
/// charge perçue sRPE × durée, affichée seulement si elle existe.
struct WorkoutEffortCard: View {
    let session: WorkoutSession
    @ObservedObject var repository: LoopDataRepository

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let store = repository.perceivedEffortStore {
                WorkoutRPERow(workoutId: session.perceivedEffortKey, store: store) {
                    // Ré-attache les RPE au cache ; `cache` est publié, la vue se met à jour.
                    Task { await repository.reloadPerceivedEfforts() }
                }
            } else {
                HStack {
                    Text("today.effort.percu", tableName: "Today").font(.body)
                    Spacer()
                    Text("today.indisponible", tableName: "Today").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(minHeight: 48)
                .accessibilityElement(children: .combine)
            }

            if let load = session.rpeLoad, load.isFinite, load > 0 {
                Divider().overlay(.secondary.opacity(0.12))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("today.charge.percue", tableName: "Today").font(.body)
                        Spacer()
                        Text("\(Int(load.rounded())) u.a.")
                            .font(.body.weight(.semibold))
                            .monospacedDigit()
                    }
                    Text("today.effort.percu.duree.en.minutes.distincte.de.la.charge.cardio", tableName: "Today")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 12)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("today.charge.percue", tableName: "Today"))
                .accessibilityValue(TodayL.format("today.final.effort.accessibility", String(Int(load.rounded()))))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .deviceSurface()
    }
}
