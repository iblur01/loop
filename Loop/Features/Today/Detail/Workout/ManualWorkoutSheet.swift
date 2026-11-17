import SwiftUI
import LoopStrapEngine
import WhoopStore

/// Feuille « Ajouter une séance » : une séance que ni la montre ni le bracelet n'ont enregistrée
/// (salle, piscine…). Sport, début, durée, RPE et note ; l'enregistrement écrit une ligne
/// `external_workout` manuelle et son RPE, puis relance le calcul.
struct ManualWorkoutSheet: View {
    @ObservedObject var repository: LoopDataRepository
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ManualWorkoutDraft
    @State private var isSaving = false
    @State private var saveFailed = false
    @State private var confirmAttach = false
    /// Séances figées à l'appui sur Enregistrer : le plan confirmé est celui qui est enregistré,
    /// même si un recalcul modifie le cache entre-temps.
    @State private var frozenSessions: [WorkoutSession]?
    private let day: String?

    init(repository: LoopDataRepository, day: String?, now: Date = Date(), zone: TimeZone = LocalDay.deviceZone) {
        self.repository = repository
        self.day = day
        _draft = State(initialValue: ManualWorkoutDraft(
            start: ManualWorkoutDraft.defaultStart(day: day, now: now, zone: zone)))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(ManualWorkoutL.text("manualWorkout.sport"), selection: $draft.sport) {
                        ForEach(ManualWorkoutSport.allCases, id: \.self) { sport in
                            let presentation = WorkoutSport(kind: nil, sportType: sport.rawValue)
                            Label(presentation.title, systemImage: presentation.symbol).tag(sport)
                        }
                    }
                    .pickerStyle(.menu)
                    DatePicker(ManualWorkoutL.text("manualWorkout.start"), selection: $draft.start,
                               in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                    durationStepper
                }

                Section {
                    rpeSlider
                } header: {
                    Text(ManualWorkoutL.text("manualWorkout.rpe"))
                } footer: {
                    Text(ManualWorkoutL.text("manualWorkout.rpe.hint"))
                }

                Section {
                    TextField(ManualWorkoutL.text("manualWorkout.note"), text: $draft.note, axis: .vertical)
                        .lineLimit(1...4)
                        .onChange(of: draft.note) { _, new in
                            if new.count > WorkoutPerceivedEffort.maxNoteLength {
                                draft.note = String(new.prefix(WorkoutPerceivedEffort.maxNoteLength))
                            }
                        }
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if case .attachEffort(_, let reason) = plan {
                            Label(ManualWorkoutL.text(reason == .merge ? "manualWorkout.attach.notice.merge"
                                                                       : "manualWorkout.attach.notice.overlap"),
                                  systemImage: "arrow.triangle.merge")
                        }
                        if saveFailed {
                            Text(ManualWorkoutL.text("manualWorkout.saveFailed"))
                                .foregroundStyle(LoopColor.textPrimary)
                        }
                        Text(ManualWorkoutL.text("manualWorkout.footer"))
                    }
                }
            }
            .navigationTitle(ManualWorkoutL.text("manualWorkout.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(ManualWorkoutL.text("manualWorkout.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(ManualWorkoutL.text(isAttaching ? "manualWorkout.attach.save" : "manualWorkout.save")) {
                        let snapshot = repository.cache.workoutSessions
                        frozenSessions = snapshot
                        if case .attachEffort = draft.plan(existing: snapshot) {
                            confirmAttach = true
                        } else {
                            Task { await save(existing: snapshot) }
                        }
                    }
                    .disabled(!draft.isValid(now: Date()) || isSaving)
                }
            }
            .interactiveDismissDisabled(isSaving)
            .confirmationDialog(ManualWorkoutL.text("manualWorkout.attach.confirm.title"),
                                isPresented: $confirmAttach, titleVisibility: .visible) {
                Button(ManualWorkoutL.text("manualWorkout.attach.confirm.action")) {
                    Task { await save(existing: frozenSessions ?? repository.cache.workoutSessions) }
                }
                Button(ManualWorkoutL.text("manualWorkout.cancel"), role: .cancel) {}
            } message: {
                Text(confirmMessage)
            }
        }
        .tint(Metric.strain.tint)
    }

    // MARK: - Fields

    private var durationStepper: some View {
        VStack(alignment: .leading, spacing: 4) {
            Stepper(value: $draft.durationMinutes, in: ManualWorkoutDraft.durationRange,
                    step: ManualWorkoutDraft.durationStep) {
                HStack {
                    Text(ManualWorkoutL.text("manualWorkout.duration"))
                    Spacer()
                    Text(ManualWorkoutL.format("manualWorkout.duration.value", draft.durationMinutes))
                        .monospacedDigit()
                        .foregroundStyle(LoopColor.textSecondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(ManualWorkoutL.text("manualWorkout.duration.accessibility")))
            .accessibilityValue(Text(ManualWorkoutL.format("manualWorkout.duration.accessibilityValue", draft.durationMinutes)))
            .accessibilityAdjustableAction { direction in
                let step = ManualWorkoutDraft.durationStep
                let range = ManualWorkoutDraft.durationRange
                switch direction {
                case .increment: draft.durationMinutes = min(range.upperBound, draft.durationMinutes + step)
                case .decrement: draft.durationMinutes = max(range.lowerBound, draft.durationMinutes - step)
                @unknown default: break
                }
            }
            if !draft.isDurationValid {
                Text(ManualWorkoutL.text("manualWorkout.duration.invalid"))
                    .font(.footnote)
                    .foregroundStyle(LoopColor.textSecondary)
            } else if draft.validationError(now: Date()) == .endsInFuture {
                Text(ManualWorkoutL.text("manualWorkout.future"))
                    .font(.footnote)
                    .foregroundStyle(LoopColor.textSecondary)
            }
        }
    }

    private var rpeSlider: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ManualWorkoutL.format("manualWorkout.rpe.value", draft.rpe, ManualWorkoutL.rpeLabel(draft.rpe)))
                .font(.headline)
                .monospacedDigit()
                .accessibilityHidden(true)
            Slider(value: Binding(get: { Double(draft.rpe) }, set: { draft.rpe = Int($0.rounded()) }),
                   in: 1...10, step: 1) {
                Text(ManualWorkoutL.text("manualWorkout.rpe"))
            } minimumValueLabel: {
                Text(verbatim: "1").font(.caption).foregroundStyle(LoopColor.textSecondary)
            } maximumValueLabel: {
                Text(verbatim: "10").font(.caption).foregroundStyle(LoopColor.textSecondary)
            }
            .accessibilityLabel(Text(ManualWorkoutL.text("manualWorkout.rpe.accessibility")))
            .accessibilityValue(Text(ManualWorkoutL.format("manualWorkout.rpe.accessibilityValue",
                                                           draft.rpe, ManualWorkoutL.rpeLabel(draft.rpe))))
        }
    }

    // MARK: - Actions

    private var plan: ManualWorkoutDraft.Plan {
        draft.plan(existing: repository.cache.workoutSessions)
    }

    private var isAttaching: Bool {
        if case .attachEffort = plan { return true }
        return false
    }

    /// Séance visée (sport et horaires) puis l'effet du rattachement, d'après le plan figé.
    private var confirmMessage: String {
        let effect = ManualWorkoutL.text("manualWorkout.attach.confirm.message")
        guard case .attachEffort(let target, _) = draft.plan(existing: frozenSessions ?? repository.cache.workoutSessions)
        else { return effect }
        let sport = WorkoutSport(kind: target.kind, sportType: target.sportType).title
        let from = Date(timeIntervalSince1970: Double(target.startTs))
        let to = Date(timeIntervalSince1970: Double(target.endTs))
        let header = ManualWorkoutL.format("manualWorkout.attach.confirm.target", sport,
                                           from.formatted(date: .abbreviated, time: .shortened),
                                           to.formatted(date: .omitted, time: .shortened))
        return header + "\n" + effect
    }

    private func save(existing: [WorkoutSession]) async {
        let now = Date()
        guard draft.isValid(now: now), !isSaving else { return }
        isSaving = true
        saveFailed = false
        defer { isSaving = false }
        do {
            try await repository.saveManualEntry(draft, existing: existing, now: now)
            dismiss()
        } catch {
            saveFailed = true
        }
    }
}

// MARK: - Localisation (table Base)

enum ManualWorkoutL {
    static func text(_ key: String) -> String {
        NSLocalizedString(key, tableName: "Base", comment: "")
    }

    static func format(_ key: String, _ args: CVarArg...) -> String {
        String(format: text(key), locale: Locale.current, arguments: args)
    }

    /// Libellés CR-10 simplifiés, mêmes paliers que `WorkoutRPEScale`.
    static func rpeLabel(_ rpe: Int) -> String {
        switch rpe {
        case ...1: return text("manualWorkout.rpe.scale.veryEasy")
        case 2...3: return text("manualWorkout.rpe.scale.easy")
        case 4...5: return text("manualWorkout.rpe.scale.moderate")
        case 6...7: return text("manualWorkout.rpe.scale.hard")
        case 8...9: return text("manualWorkout.rpe.scale.veryHard")
        default: return text("manualWorkout.rpe.scale.max")
        }
    }
}

// MARK: - Suppression (détail d'une séance)

/// Bouton de suppression affiché dans le détail, uniquement pour une séance saisie à la main
/// (vérifié sur la ligne stockée : `sourceBundle` manuel). Confirmation obligatoire.
struct ManualWorkoutDeleteButton: View {
    let session: WorkoutSession
    @ObservedObject var repository: LoopDataRepository
    var onDeleted: () -> Void = {}

    @State private var isManual = false
    @State private var confirm = false
    @State private var failed = false

    var body: some View {
        Group {
            if isManual, let id = session.externalID {
                VStack(spacing: 6) {
                    Button(role: .destructive) { confirm = true } label: {
                        Label(ManualWorkoutL.text("manualWorkout.delete"), systemImage: "trash")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    if failed {
                        Text(ManualWorkoutL.text("manualWorkout.delete.failed"))
                            .font(.footnote)
                            .foregroundStyle(LoopColor.textSecondary)
                    }
                }
                .confirmationDialog(ManualWorkoutL.text("manualWorkout.delete.confirm.title"),
                                    isPresented: $confirm, titleVisibility: .visible) {
                    Button(ManualWorkoutL.text("manualWorkout.delete"), role: .destructive) {
                        Task { await delete(id: id) }
                    }
                    Button(ManualWorkoutL.text("manualWorkout.cancel"), role: .cancel) {}
                } message: {
                    Text(ManualWorkoutL.text("manualWorkout.delete.confirm.message"))
                }
            }
        }
        .task(id: session.externalID) {
            guard let id = session.externalID else { isManual = false; return }
            isManual = await repository.isManualWorkout(externalID: id)
        }
    }

    private func delete(id: String) async {
        failed = false
        do {
            if try await repository.deleteManualWorkout(externalID: id) { onDeleted() } else { failed = true }
        } catch {
            failed = true
        }
    }
}
