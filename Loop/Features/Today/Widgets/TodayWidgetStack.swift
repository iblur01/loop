import SwiftUI

/// Renders the contextual widgets in the order `TodayContext` decided. Full-width widgets expand
/// inline; the compact Cardio + Stress tiles are paired into a single half-width row. Soft staggered
/// entrance.
struct TodayWidgetStack: View {
    let widgets: [TodayWidgetID]
    let metric: DailySnapshot?
    let strainTarget: Double
    let stress: StressSnapshot?
    let samples: [HeartRateSample]
    let day: String?
    let sleepSessions: [SleepSession]
    let workoutSessions: [WorkoutSession]
    let onRejectWorkout: (WorkoutSession) -> Void
    let batteryPercent: Double?
    let isCharging: Bool

    @State private var appeared = false

    /// Group the ordered widgets into rows, pairing adjacent compact tiles (cardio / stress) so they
    /// sit two-up.
    private var rows: [[TodayWidgetID]] {
        var out: [[TodayWidgetID]] = []
        var pending: [TodayWidgetID] = []
        func flush() { if !pending.isEmpty { out.append(pending); pending = [] } }

        for id in widgets {
            if id == .cardio || id == .stress {
                pending.append(id)
                if pending.count == 2 { flush() }
            } else {
                flush()
                out.append([id])
            }
        }
        flush()
        return out
    }

    var body: some View {
        VStack(spacing: 14) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                rowView(row)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 12)
                    .animation(.spring(response: 0.5, dampingFraction: 0.85).delay(0.04 * Double(index)), value: appeared)
            }
        }
        .onAppear { appeared = true }
    }

    @ViewBuilder
    private func rowView(_ row: [TodayWidgetID]) -> some View {
        if row.count == 2 {
            HStack(spacing: 14) {
                ForEach(row) { tile(for: $0) }
            }
        } else if let id = row.first {
            widget(for: id)
        }
    }

    // MARK: - Full-width widgets

    @ViewBuilder
    private func widget(for id: TodayWidgetID) -> some View {
        switch id {
        case .deviceAlert:
            DeviceAlertWidget(batteryPercent: batteryPercent, isCharging: isCharging)
        case .alarm:
            AlarmWidget(prefs: UserPreferences.shared)
        case .focus:
            FocusWidget(metric: metric, strainTarget: strainTarget)
        case .strainTarget:
            StrainTargetWidget(metric: metric, strainTarget: strainTarget)
        case .sleep:
            if let metric { SleepWidget(metric: metric) }
        case .timeline:
            TimelineWidget(day: day, sleep: sleepSessions, workouts: workoutSessions, onReject: onRejectWorkout)
        case .cardio:
            cardioTile        // single (no pair) → still a tile, full width
        case .stress:
            stressTile
        }
    }

    // MARK: - Compact tiles

    @ViewBuilder
    private func tile(for id: TodayWidgetID) -> some View {
        switch id {
        case .cardio: cardioTile
        case .stress: stressTile
        default: EmptyView()
        }
    }

    private var cardioTile: some View {
        CompactMetricTile(
            symbol: "heart.fill",
            symbolColor: Pop.red,
            title: "Cardio",
            value: samples.last.map { "\($0.bpm)" } ?? "—",
            unit: samples.last != nil ? "bpm" : nil,
            caption: cardioCaption,
            navValue: TodayRoute.heartRate
        )
    }

    private var stressTile: some View {
        CompactMetricTile(
            symbol: "waveform.path.ecg",
            symbolColor: stressColor,
            title: "Stress",
            value: stressValue,
            unit: stressValue == "—" ? nil : "/ 3",
            caption: stressCaption,
            navValue: TodayRoute.stress
        )
    }

    private var cardioCaption: String? {
        guard let last = samples.last else { return nil }
        return Self.timeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(last.ts)))
    }

    private var stressValue: String {
        guard let avg = stress?.summary.avgScore, avg.isFinite else { return "—" }
        return String(format: "%.1f", avg)
    }

    private var stressCaption: String? {
        guard let m = stress?.summary.highMinutes, m > 0 else { return nil }
        return TodayL.format("today.stress.high.minutes", String(Int(m.rounded())))
    }

    private var stressColor: Color {
        guard let avg = stress?.summary.avgScore else { return .secondary }
        if avg >= 2 { return Pop.red }
        if avg >= 1 { return Pop.amber }
        return Pop.green
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
}
