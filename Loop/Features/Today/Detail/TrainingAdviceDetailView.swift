import SwiftUI
import LoopStrapEngine

/// Detail page of the "Conseil du jour" widget: the retained insight in full, its confidence, the
/// contributing factors and notes, then the other readings. Read-only; all sentences are rendered
/// from keys (`TrainingInsightRenderer`), no literal number in any text.
struct TrainingAdviceDetailView: View {
    let insights: [TrainingInsight]
    var isLoading: Bool = false

    @State private var appeared = false

    private var model: TrainingAdviceModel { .make(insights: insights, isLoading: isLoading) }
    private var strings: [String: String] { TrainingAdviceStrings.table }

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let insight = model.insight, model.phase != .loading {
                        staged(0) { hero(insight) }
                        staged(1) { contributors(insight) }
                        if !insight.detailNoteKeys.isEmpty { staged(2) { notes(insight) } }
                        let others = model.all.filter { $0.id != insight.id }
                        if !others.isEmpty { staged(3) { othersSection(others) } }
                    } else {
                        Text(TrainingAdviceStrings.text(model.phase == .loading ? "training.widget.loading" : "training.detail.none"))
                            .font(.subheadline).foregroundStyle(.secondary)
                            .widgetSurface()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 24)
                .padding(.bottom, 34)
            }
        }
        .navigationTitle(TrainingAdviceStrings.text("training.detail.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .onAppear { withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) { appeared = true } }
    }

    // MARK: Sections

    private func hero(_ insight: TrainingInsight) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let badge = badge(model.phase) {
                Text(TrainingAdviceStrings.text(badge)).font(.footnote.weight(.semibold))
            }
            Text(TrainingInsightRenderer.short(insight, strings: strings))
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(TrainingInsightRenderer.render(key: insight.detailKey, facts: insight.facts, strings: strings))
                .font(.subheadline).foregroundStyle(.secondary).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            if model.showsConfidence {
                TrainingConfidenceRow(confidence: insight.confidence, experimental: insight.isExperimental)
            } else {
                Text(TrainingAdviceStrings.text("training.confidence.none"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .widgetSurface()
        .accessibilityElement(children: .combine)
    }

    private func contributors(_ insight: TrainingInsight) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            WidgetLabel(symbol: "list.bullet", title: TrainingAdviceStrings.text("training.detail.contributors"))
            ForEach(insight.contributors, id: \.self) { id in
                Label(TrainingAdviceStrings.contributorLabel(id), systemImage: "circle.fill")
                    .labelStyle(BulletLabelStyle())
                    .font(.subheadline)
            }
        }
        .widgetSurface()
        .accessibilityElement(children: .contain)
    }

    private func notes(_ insight: TrainingInsight) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            WidgetLabel(symbol: "note.text", title: TrainingAdviceStrings.text("training.detail.notes"))
            ForEach(insight.detailNoteKeys, id: \.self) { key in
                Text(TrainingInsightRenderer.render(key: key, facts: insight.facts, strings: strings))
                    .font(.subheadline).foregroundStyle(.secondary).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .widgetSurface()
        .accessibilityElement(children: .combine)
    }

    private func othersSection(_ others: [TrainingInsight]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            WidgetLabel(symbol: "square.stack", title: TrainingAdviceStrings.text("training.detail.others"))
            ForEach(others) { other in
                VStack(alignment: .leading, spacing: 4) {
                    Text(TrainingInsightRenderer.short(other, strings: strings))
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    TrainingInsightStatus(insight: other)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .widgetSurface()
    }

    private func badge(_ phase: TrainingAdviceModel.Phase) -> String? {
        switch phase {
        case .calibration: return "training.widget.calibration.badge"
        case .insufficient: return "training.widget.insufficient.badge"
        case .partial: return "training.widget.partial.badge"
        case .contradictory: return "training.widget.contradictory.badge"
        default: return nil
        }
    }

    private func staged<Content: View>(_ index: Int, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 14)
            .animation(.spring(response: 0.5, dampingFraction: 0.85).delay(0.05 * Double(index)), value: appeared)
    }
}

private struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            configuration.icon.font(.system(size: 5)).foregroundStyle(.tertiary).accessibilityHidden(true)
            configuration.title
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        TrainingAdviceDetailView(insights: [TrainingAdvicePreviewData.contradictory, TrainingAdvicePreviewData.calibration])
    }
}
#endif
