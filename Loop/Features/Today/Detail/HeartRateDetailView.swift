import SwiftUI

/// Heart-rate detail page, rebuilt to the Sleep/Recovery/Strain language: a card-less hero, one
/// foregrounded interactive chart, the figures in a single grouped surface, and two progressive
/// disclosures carrying the added value — effort zones (heart-rate reserve) and the resting-HR
/// trend. Monochrome with one accent (red); micro-interactions over decoration.
struct HeartRateDetailView: View {
    let samples: [HeartRateSample]
    let metrics: [DailySnapshot]
    var loadSamples: ((Int, Int) async throws -> [HeartRateSample])? = nil

    @State private var range: HeartRateCoachModel.Range = .day
    @State private var appeared = false
    @State private var loadedSamples: [HeartRateSample]?
    @State private var loadFailed = false
    @State private var engineRevision = 0

    private struct LoadKey: Equatable {
        let range: HeartRateCoachModel.Range
        let cachedSamples: [HeartRateSample]
        let engineRevision: Int
    }

    private var model: HeartRateCoachModel {
        HeartRateCoachModel(samples: loadedSamples ?? (loadSamples == nil ? samples : []), metrics: metrics, range: range)
    }

    var body: some View {
        let model = model
        return ZStack {
            AppBackground()

            ScrollView {
                VStack(spacing: 22) {
                    staged(0) { HeartRateHero(model: model) }
                    if loadFailed {
                        Text("Impossible de charger les mesures cardiaques.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    staged(1) { HeartRateRangeChart(model: model, range: $range) }
                    staged(2) { HeartRateStatsGroup(model: model) }
                    staged(3) { HeartRateZonesCard(model: model) }
                    staged(4) { HeartRateRestingTrendCard(model: model) }
                }
                .padding(.horizontal, 16)
                .padding(.top, 24)
                .padding(.bottom, 34)
            }
        }
        .navigationTitle(TodayL.text("today.final.heart.rate.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .onAppear { withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) { appeared = true } }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("loop.healthEngineChanged"))) { _ in
            engineRevision += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("loop.bandHistoryChanged"))) { _ in
            engineRevision += 1
        }
        .task(id: LoadKey(range: range, cachedSamples: samples, engineRevision: engineRevision)) {
            guard let loadSamples else { return }
            loadedSamples = nil
            loadFailed = false
            let end = Int(Date().timeIntervalSince1970)
            do {
                let result = try await loadSamples(end - Int(range.seconds), end)
                guard !Task.isCancelled else { return }
                loadedSamples = result
            } catch {
                guard !Task.isCancelled else { return }
                loadFailed = true
            }
        }
    }

    private func staged<Content: View>(_ index: Int, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 14)
            .animation(.spring(response: 0.5, dampingFraction: 0.85).delay(0.05 * Double(index)), value: appeared)
    }
}

#Preview {
    NavigationStack {
        HeartRateDetailView(
            samples: HeartRateCoachModel.previewSamples,
            metrics: HeartRateCoachModel.previewMetrics
        )
    }
}
