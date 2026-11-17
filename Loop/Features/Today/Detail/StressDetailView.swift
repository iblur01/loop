import SwiftUI

/// Stress detail page, rebuilt to the Sleep/Recovery/Strain language: a card-less hero, one
/// foregrounded interactive 24 h timeline, the "why" (autonomic drivers) and time-in-state
/// breakdown behind progressive disclosures, the figures in a single grouped surface, and a
/// prescriptive manage card. Monochrome with one band accent; micro-interactions over decoration.
struct StressDetailView: View {
    let snapshot: StressSnapshot

    @State private var appeared = false

    private var model: StressCoachModel { StressCoachModel(snapshot: snapshot) }

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                VStack(spacing: 22) {
                    staged(0) { StressHero(model: model) }
                    staged(1) { StressTimelineCard(model: model) }
                    staged(2) { StressWhyDisclosure(model: model) }
                    staged(3) { StressFactsGroup(model: model) }
                    staged(4) { StressBalanceCard(model: model) }
                    staged(5) { StressManageCard(model: model) }
                }
                .padding(.horizontal, 16)
                .padding(.top, 24)
                .padding(.bottom, 34)
            }
        }
        .navigationTitle("Stress")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .onAppear { withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) { appeared = true } }
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
        StressDetailView(snapshot: StressCoachModel.previewSnapshot(score: 1.6))
    }
}
