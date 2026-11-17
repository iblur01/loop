import SwiftUI

struct SleepDetailView: View {
    let metrics: [DailySnapshot]
    var sessions: [SleepSession] = []
    @Binding var selectedDay: String?

    @State private var appeared = false

    private var sortedMetrics: [DailySnapshot] {
        metrics.sorted { $0.date < $1.date }
    }

    private var resolvedDay: String? {
        let day = selectedDay ?? sortedMetrics.last?.date
        return sortedMetrics.first { $0.date == day }?.date ?? sortedMetrics.last?.date
    }

    private var metric: DailySnapshot? {
        let day = selectedDay ?? sortedMetrics.last?.date
        return sortedMetrics.first { $0.date == day } ?? sortedMetrics.last
    }

    /// The sleep session whose night ENDS on the selected day, matched on the same UTC
    /// "yyyy-MM-dd" convention as `ActivityTimeline`. nil is expected and handled, not
    /// an error.
    private var session: SleepSession? {
        guard let day = resolvedDay else { return nil }
        return sessions.first { Self.dayString(from: $0.endTs) == day }
    }

    private var model: SleepCoachModel? {
        guard let metric else { return nil }
        return SleepCoachModel(metric: metric, session: session, history: sortedMetrics)
    }

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                if let model {
                    VStack(spacing: 22) {
                        staged(0) { SleepHero(model: model) }
                        staged(1) { SleepDurationCard(model: model) }
                        staged(2) { SleepInsightDisclosure(model: model) }
                        staged(3) { SleepStagesCard(model: model) }
                        staged(4) { SleepFactsGroup(model: model) }
                        staged(5) { SleepTonightPlan(model: model) }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 24)
                    .padding(.bottom, 34)
                } else {
                    ContentUnavailableView(TodayL.text("today.final.missing.sleep"), systemImage: "bed.double")
                        .padding(.top, 40)
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                DateNavigator(metrics: sortedMetrics, selectedDay: $selectedDay)
            }
        }
        .onAppear { withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) { appeared = true } }
    }

    /// Soft rise-and-settle entrance, cascaded by section index (matches DeviceView).
    private func staged<Content: View>(_ index: Int, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 14)
            .animation(.spring(response: 0.5, dampingFraction: 0.85).delay(0.05 * Double(index)), value: appeared)
    }

    /// Shared local-day date formatter — allocated once to avoid per-call allocation.
    private static let _dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.autoupdatingCurrent  // jour local, même politique que le moteur
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Local "yyyy-MM-dd" of an epoch-second timestamp — the project's day-matching
    /// convention (same formatter as `ActivityTimeline`).
    private static func dayString(from timestamp: Int) -> String {
        _dayFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }
}

#Preview {
    SleepDetailPreview()
}

private struct SleepDetailPreview: View {
    @State private var selectedDay: String?

    var body: some View {
        NavigationStack {
            SleepDetailView(
                metrics: [.sleepPreview(score: 78)],
                selectedDay: $selectedDay
            )
        }
    }
}
