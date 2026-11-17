import SwiftUI
import WhoopStore

/// Ligne « Effort perçu » pour le détail d'une séance : affiche le RPE saisi (ou une invitation) et
/// ouvre une feuille de saisie 1-10 + note courte. `onChange` est appelé après une saisie ou une
/// suppression (l'appelant recharge alors les RPE du cache). Usage : `WorkoutRPERow(workoutId: "external:<uuid>", store: PerceivedEffortStore(store: whoopStore))`.
struct WorkoutRPERow: View {
    let workoutId: String
    let store: PerceivedEffortStore
    var onChange: (() -> Void)? = nil

    @State private var effort: WorkoutPerceivedEffort?
    @State private var showSheet = false

    var body: some View {
        Button { showSheet = true } label: {
            HStack {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.tint)
                    .frame(minWidth: 26, alignment: .leading)
                    .accessibilityHidden(true)
                Text("today.effort.percu", tableName: "Today")
                    .font(.body)
                    .foregroundStyle(.primary)
                Spacer()
                if let effort {
                    Text("\(effort.rpe)/10 · \(WorkoutRPEScale.label(effort.rpe))")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                } else {
                    Text("today.ajouter", tableName: "Today")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("today.effort.percu", tableName: "Today"))
        .accessibilityValue(effort.map { TodayL.format("today.final.effort.score.accessibility", String($0.rpe), WorkoutRPEScale.label($0.rpe)) } ?? TodayL.text("today.final.workout.unspecified"))
        .accessibilityHint(TodayL.text("today.final.workout.enter.effort"))
        .task(id: workoutId) { await reload() }
        .sheet(isPresented: $showSheet) {
            WorkoutRPESheet(workoutId: workoutId, store: store, existing: effort) {
                Task { await reload() }
                onChange?()
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func reload() async {
        effort = try? await store.get(workoutId: workoutId)
    }
}

enum WorkoutRPEScale {
    /// Libellés courts de l'échelle CR-10 simplifiée.
    static func label(_ rpe: Int) -> String {
        switch rpe {
        case ...1: return String(localized: "today.tres.facile", table: "Today")
        case 2...3: return "Facile"
        case 4...5: return String(localized: "today.modere", table: "Today")
        case 6...7: return "Difficile"
        case 8...9: return String(localized: "today.tres.difficile", table: "Today")
        default: return "Maximal"
        }
    }
}

struct WorkoutRPESheet: View {
    let workoutId: String
    let store: PerceivedEffortStore
    let existing: WorkoutPerceivedEffort?
    var onChange: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var rpe: Int?
    @State private var confirmDelete = false
    @State private var note: String = ""
    @State private var error: String?

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("today.effort.percu", tableName: "Today")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Text(rpe.map { "\($0)/10 · \(WorkoutRPEScale.label($0))" } ?? TodayL.text("today.remaining.effort.not.selected"))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(rpe == nil ? .secondary : .primary)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(rpe ?? 0)))
                    .animation(.spring(response: 0.4, dampingFraction: 0.7), value: rpe)
                    .accessibilityHidden(true)
            }
            // Position neutre (milieu) tant que rien n'est choisi ; aucune valeur n'est enregistrée avant un geste.
            Slider(
                value: Binding(get: { Double(rpe ?? 5) }, set: { rpe = Int($0.rounded()) }),
                in: 1...10, step: 1,
                label: { Text("RPE") },
                minimumValueLabel: { Text("1").font(.system(size: 12)).foregroundStyle(.secondary) },
                maximumValueLabel: { Text("10").font(.system(size: 12)).foregroundStyle(.secondary) }
            )
            .accessibilityLabel(Text("today.effort.percu.de.1.a.10", tableName: "Today"))
            .accessibilityValue(rpe.map { TodayL.format("today.remaining.effort.score", String($0), WorkoutRPEScale.label($0)) } ?? TodayL.text("today.remaining.effort.not.selected"))
            TextField("Note (facultatif)", text: $note)
                .font(.system(size: 15))
                .accessibilityLabel(Text("today.note.facultative", tableName: "Today"))
                .onChange(of: note) { _, new in
                    if new.count > WorkoutPerceivedEffort.maxNoteLength {
                        note = String(new.prefix(WorkoutPerceivedEffort.maxNoteLength))
                    }
                }
            if let error {
                Text(error).font(.system(size: 13)).foregroundStyle(.red)
                    .accessibilityLabel("Erreur : \(error)")
            }
            Text("today.comment.cette.seance.t.a.t.elle.semble.de.1.tres.facile.a.10.effort.maximal", tableName: "Today")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            HStack {
                if existing != nil {
                    Button("Supprimer", role: .destructive) { confirmDelete = true }
                }
                Spacer()
                Button("Annuler") { dismiss() }
                Button("Enregistrer") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(rpe == nil)
            }
            .controlSize(.large)
        }
        .padding(20)
        }
        .alert(TodayL.text("today.final.workout.delete.effort"), isPresented: $confirmDelete) {
            Button("Supprimer", role: .destructive) { Task { await delete() } }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("today.la.valeur.et.la.note.de.cette.seance.seront.effacees", tableName: "Today")
        }
        .onAppear {
            if let existing { rpe = existing.rpe; note = existing.note ?? "" }
        }
    }

    private func save() async {
        guard let rpe else { return }
        do {
            try await store.save(workoutId: workoutId, rpe: min(max(rpe, 1), 10), note: note)
            onChange(); dismiss()
        } catch { self.error = "Enregistrement impossible." }
    }

    private func delete() async {
        do {
            try await store.delete(workoutId: workoutId)
            onChange(); dismiss()
        } catch { self.error = "Suppression impossible." }
    }
}
