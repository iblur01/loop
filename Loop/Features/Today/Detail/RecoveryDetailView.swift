import SwiftUI

struct RecoveryDetailView: View {
    let metrics: [DailySnapshot]
    @Binding var selectedDay: String?

    @State private var appeared = false

    private var sortedMetrics: [DailySnapshot] {
        metrics.sorted { $0.date < $1.date }
    }

    private var metric: DailySnapshot? {
        let day = selectedDay ?? sortedMetrics.last?.date
        return sortedMetrics.first { $0.date == day } ?? sortedMetrics.last
    }

    private var model: RecoveryCoachModel? {
        guard let metric else { return nil }
        return RecoveryCoachModel(metric: metric, history: sortedMetrics)
    }

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                if let model {
                    VStack(spacing: 22) {
                        staged(0) { RecoveryHero(model: model) }
                        staged(1) { RecoveryGaugeCard(model: model) }
                        staged(2) { RecoveryWhyDisclosure(model: model) }
                        staged(3) { RecoveryFactsGroup(model: model) }
                        staged(4) { RecoveryTrendCard(model: model) }
                        staged(5) { RecoveryImproveCard(model: model) }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 24)
                    .padding(.bottom, 34)
                } else {
                    ContentUnavailableView(TodayL.text("today.final.missing.recovery"), systemImage: "heart.text.square")
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

    /// Soft rise-and-settle entrance, cascaded by section index (matches Device/Sleep).
    private func staged<Content: View>(_ index: Int, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 14)
            .animation(.spring(response: 0.5, dampingFraction: 0.85).delay(0.05 * Double(index)), value: appeared)
    }
}

#Preview {
    RecoveryDetailPreview()
}

private struct RecoveryDetailPreview: View {
    @State private var selectedDay: String?

    var body: some View {
        NavigationStack {
            RecoveryDetailView(metrics: RecoveryCoachModel.preview(score: 72).history, selectedDay: $selectedDay)
        }
    }
}
