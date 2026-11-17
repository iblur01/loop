import SwiftUI

/// « Journée » : timeline verticale du jour (sommeil, siestes, séances), composant unique partagé
/// par l'accueil et la page Strain. Rail horaire à gauche, un nœud par événement relié par un
/// trait, contenu puis durée à droite. Doublons et fragments traités par `DayTimelineBuilder`
/// (pur, testé) ; rien n'est modifié en base. Une séance ouvre son détail via
/// `TodayRoute.workout` (pile de navigation de l'accueil).
struct DayTimelineCard: View {
    /// Jour local "yyyy-MM-dd" ; nil = aucune journée (rien n'est affiché).
    let day: String?
    let sleep: [SleepSession]
    let workouts: [WorkoutSession]
    var isLoading: Bool = false
    /// Rejet d'une séance (faux positif) via le menu contextuel ; nil = action absente.
    var onReject: ((WorkoutSession) -> Void)? = nil

    @State private var showsFragments = false

    private var result: DayTimelineBuilder.Result {
        guard let day else { return .init(entries: [], fragments: []) }
        return DayTimelineBuilder.build(day: day, sleep: sleep, workouts: workouts)
    }

    /// Le jour affiché est aujourd'hui : la liste peut encore se compléter.
    private var isToday: Bool {
        guard let day else { return false }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date()) == day
    }

    var body: some View {
        let r = result
        VStack(alignment: .leading, spacing: 12) {
            WidgetHeader(symbol: "clock", title: String(localized: "timeline.title", table: "Core"), tint: Metric.strain.tint,
                         trailing: r.entries.isEmpty ? nil : (r.entries.count == 1 ? String(format: String(localized: "timeline.events.one", table: "Core"), r.entries.count) : String(format: String(localized: "timeline.events.other", table: "Core"), r.entries.count)))

            if r.entries.isEmpty && r.fragments.isEmpty {
                if isLoading {
                    placeholder
                } else {
                    Text(String(localized: "timeline.noData", table: "Core"))
                        .font(LoopType.body)
                        .foregroundStyle(LoopColor.textSecondary)
                }
            } else {
                let shown = showsFragments ? (r.entries + r.fragments).sorted { $0.start < $1.start } : r.entries
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, entry in
                        DayTimelineRow(entry: entry, isFirst: index == 0, isLast: index == shown.count - 1,
                                       isFragment: r.fragments.contains(entry),
                                       workout: entry.workoutID.flatMap { id in workouts.first { $0.id == id } },
                                       onReject: onReject)
                    }
                }

                if !r.entries.contains(where: \.isWorkout) {
                    Text(String(localized: "timeline.noWorkouts", table: "Core"))
                        .font(LoopType.label)
                        .foregroundStyle(LoopColor.textSecondary)
                }

                if !r.fragments.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showsFragments.toggle() }
                    } label: {
                        Label(showsFragments
                              ? String(localized: "timeline.hideFragments", table: "Core")
                              : (r.fragments.count == 1 ? String(format: String(localized: "timeline.fragments.one", table: "Core"), r.fragments.count) : String(format: String(localized: "timeline.fragments.other", table: "Core"), r.fragments.count)),
                              systemImage: showsFragments ? "eye.slash" : "eye")
                            .font(LoopType.footnote)
                            .foregroundStyle(LoopColor.textSecondary)
                            .frame(minHeight: LoopMeasure.minTarget, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }

            if isToday && !(r.entries.isEmpty && r.fragments.isEmpty) {
                PartialNote(text: String(localized: "timeline.partial", table: "Core"))
            }
        }
        .padding(LoopMeasure.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .loopCard()
    }

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "timeline.placeholder.sleep", table: "Core"))
            Text(String(localized: "timeline.placeholder.run", table: "Core"))
        }
        .font(LoopType.body)
        .redacted(reason: .placeholder)
        .accessibilityLabel(String(localized: "timeline.loading", table: "Core"))
    }
}

// MARK: - Row

private struct DayTimelineRow: View {
    let entry: DayTimelineEntry
    let isFirst: Bool
    let isLast: Bool
    let isFragment: Bool
    let workout: WorkoutSession?
    let onReject: ((WorkoutSession) -> Void)?

    @ScaledMetric(relativeTo: .body) private var nodeSize: CGFloat = 28
    @ScaledMetric(relativeTo: .footnote) private var railWidth: CGFloat = 44

    private var sport: WorkoutSport? {
        guard entry.isWorkout else { return nil }
        return WorkoutSport(kind: entry.rawKind, sportType: entry.sportType)
    }

    private var title: String {
        switch entry.kind {
        case .sleep: return String(localized: "timeline.sleep", table: "Core")
        case .nap: return String(localized: "timeline.nap", table: "Core")
        case .workout: return sport?.title ?? String(localized: "timeline.activity", table: "Core")
        }
    }

    private var symbol: String {
        if entry.overlapsSleep { return "exclamationmark.circle" }
        switch entry.kind {
        case .sleep: return "bed.double.fill"
        case .nap: return "moon.zzz.fill"
        case .workout: return sport?.symbol ?? "figure.arms.open"
        }
    }

    /// Sommeil = teinte sommeil ; séance = teinte du sport ; incohérence = état neutre.
    private var tint: Color {
        if entry.overlapsSleep { return HealthState.neutral.color }
        switch entry.kind {
        case .sleep, .nap: return Metric.sleep.tint
        case .workout: return sport?.tint ?? HealthState.neutral.color
        }
    }

    private var hrText: String? {
        let avg = entry.avgHr.map { String(format: String(localized: "timeline.average.short", table: "Core"), Int($0.rounded())) }
        let peak = entry.peakHr.map { String(format: String(localized: "timeline.peak.short", table: "Core"), $0) }
        let parts = [avg, peak].compactMap { $0 }
        return parts.isEmpty ? nil : String(localized: "timeline.hr.short", table: "Core") + " " + parts.joined(separator: " · ") + " bpm"
    }

    var body: some View {
        if let id = entry.workoutID {
            NavigationLink(value: TodayRoute.workout(id)) { row }
                .buttonStyle(.plain)
                .accessibilityHint(String(localized: "timeline.openWorkout", table: "Core"))
                .contextMenu {
                    if let workout, let onReject {
                        Button(role: .destructive) { onReject(workout) } label: {
                            Label(String(localized: "timeline.reject", table: "Core"), systemImage: "xmark.circle")
                        }
                    }
                }
        } else {
            row
        }
    }

    private var row: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(Self.time(entry.start))
                .font(LoopType.footnote.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(LoopColor.textSecondary)
                .frame(width: railWidth, alignment: .trailing)
                .padding(.top, 5)

            node

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(LoopType.body.weight(.semibold))
                        .foregroundStyle(entry.overlapsSleep ? LoopColor.textSecondary : LoopColor.textPrimary)
                    Spacer(minLength: 6)
                    Text(StrainCoachModel.durationText(Double(entry.durationMinutes)))
                        .font(LoopType.label.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(LoopColor.textPrimary)
                }
                Text("\(Self.time(entry.start)) – \(Self.time(entry.end))")
                    .font(LoopType.footnote)
                    .monospacedDigit()
                    .foregroundStyle(LoopColor.textSecondary)
                if let hrText {
                    Text(hrText)
                        .font(LoopType.footnote)
                        .monospacedDigit()
                        .foregroundStyle(LoopColor.textSecondary)
                }
                if entry.overlapsSleep {
                    StateLabel(state: .neutral, text: String(localized: "timeline.overlap", table: "Core"), font: LoopType.footnote.weight(.semibold),
                               symbol: "exclamationmark.circle")
                }
                HStack(spacing: 6) {
                    Text(entry.source.label)
                        .font(LoopType.footnote)
                        .foregroundStyle(LoopColor.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .loopCard(.nested, cornerRadius: 8)
                    if !entry.mergedSources.isEmpty {
                        Text(String(format: String(localized: "timeline.also", table: "Core"), entry.mergedSources.map(\.label).joined(separator: ", ")))
                            .font(LoopType.footnote)
                            .foregroundStyle(LoopColor.textSecondary)
                            .lineLimit(1)
                    }
                    if isFragment {
                        Text(String(localized: "timeline.fragment", table: "Core"))
                            .font(LoopType.footnote)
                            .foregroundStyle(LoopColor.textSecondary)
                    }
                }
            }
            .padding(.bottom, isLast ? 0 : 14)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(entry.workoutID != nil ? .isButton : [])
    }

    /// Nœud + trait vers le suivant. Une séance qui chevauche le sommeil a un nœud creux en
    /// pointillés (pas un nœud d'effort).
    private var node: some View {
        ZStack(alignment: .top) {
            if !isLast {
                Rectangle()
                    .fill(LoopColor.trackEmpty)
                    .frame(width: 2)
                    .padding(.top, nodeSize)
                    .frame(maxHeight: .infinity)
            }
            if !isFirst {
                Rectangle()
                    .fill(LoopColor.trackEmpty)
                    .frame(width: 2, height: 4)
            }
            Group {
                if entry.overlapsSleep {
                    Circle()
                        .strokeBorder(tint, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                        .background(Circle().fill(LoopColor.surfaceCard))
                } else {
                    Circle().fill(tint.opacity(0.18))
                }
            }
            .frame(width: nodeSize, height: nodeSize)
            .overlay {
                Image(systemName: symbol)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: nodeSize)
        .accessibilityHidden(true)
    }

    private var accessibilityText: String {
        var parts = ["\(Self.time(entry.start))", title,
                     StrainCoachModel.durationText(Double(entry.durationMinutes)),
                     String(format: String(localized: "timeline.range", table: "Core"), Self.time(entry.start), Self.time(entry.end))]
        if let avg = entry.avgHr { parts.append(String(format: String(localized: "timeline.hr.average", table: "Core"), Int(avg.rounded()))) }
        if let peak = entry.peakHr { parts.append(String(format: String(localized: "timeline.hr.peak", table: "Core"), peak)) }
        if entry.overlapsSleep { parts.append(String(localized: "timeline.overlap", table: "Core")) }
        parts.append(String(format: String(localized: "timeline.source", table: "Core"), entry.source.label))
        if !entry.mergedSources.isEmpty { parts.append(String(format: String(localized: "timeline.alsoRecorded", table: "Core"), entry.mergedSources.map(\.label).joined(separator: ", "))) }
        return parts.joined(separator: ", ")
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter(); f.locale = .autoupdatingCurrent; f.setLocalizedDateFormatFromTemplate("Hm"); return f
    }()

    static func time(_ ts: Int) -> String { formatter.string(from: Date(timeIntervalSince1970: TimeInterval(ts))) }
}
