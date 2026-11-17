import SwiftUI
import LoopStrapEngine

/// Analyse d'entraînement (charge, régularité, sommeil, liens exploratoires) issue de
/// `LoopDataRepository.trainingReport`. Indicateurs statistiques : jamais présentés comme fiables
/// quand ils sont en calibration ou de faible confiance, ni comme diagnostic.
struct TrainingInsightsCard: View {
    @ObservedObject var repository: LoopDataRepository
    /// Displayed day ("yyyy-MM-dd"); nil = today. Past days frame the reading as computed today.
    var day: String? = nil
    @State private var showAll = false

    private var tense: AdviceTense { AdviceTense.of(day: day) }

    private static let collapsedCount = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WidgetHeader(symbol: "lightbulb.fill", title: String(localized: "today.analyse.d.entrainement", table: "Today"), tint: Metric.strain.tint)
            content
        }
        .padding(LoopMeasure.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .loopCard()
    }

    /// Hidden by the page grid when there is nothing to read and nothing computing.
    static func isAvailable(_ repository: LoopDataRepository) -> Bool {
        repository.trainingReport != nil || repository.isRefreshing
    }

    @ViewBuilder private var content: some View {
        if let report = repository.trainingReport {
            let insights = report.insights
            if insights.isEmpty {
                message(TodayL.text("today.final.insight.no.indicator"))
            } else {
                let shown = showAll ? insights : Array(insights.prefix(Self.collapsedCount))
                VStack(alignment: .leading, spacing: 14) {
                    if tense == .past {
                        Label(TrainingAdviceStrings.pastDayNote, systemImage: "clock.arrow.circlepath")
                            .font(LoopType.footnote)
                            .foregroundStyle(LoopColor.textSecondary)
                    }
                    ForEach(shown) { InsightRow(insight: $0, strings: TrainingAdviceStrings.table(for: tense)) }
                    if insights.count > Self.collapsedCount {
                        Button(showAll ? TodayL.text("today.final.insight.less") : TodayL.format("today.final.insight.show.count", String(insights.count))) {
                            withAnimation(.easeInOut(duration: 0.2)) { showAll.toggle() }
                        }
                        .font(LoopType.label.weight(.semibold))
                        .frame(minHeight: 44, alignment: .leading)
                    }
                }
            }
        } else if repository.isRefreshing {
            // Chargement : gabarit final masqué, pas de spinner (spec design §6).
            VStack(alignment: .leading, spacing: 8) {
                Text("today.ta.charge.recente.reste.stable.par.rapport.a.ton.habitude", tableName: "Today")
                Text("today.confiance.moyenne", tableName: "Today")
            }
            .font(LoopType.body)
            .redacted(reason: .placeholder)
            .accessibilityLabel(Text("today.analyse.en.cours.de.calcul", tableName: "Today"))
        } else {
            message(TodayL.text("today.final.insight.insufficient"))
        }
    }

    private func message(_ text: String) -> some View {
        Text(text).font(LoopType.body).foregroundStyle(LoopColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct InsightRow: View {
    let insight: TrainingInsight
    let strings: [String: String]
    @State private var expanded = false

    private var isReliable: Bool { insight.state == .ok && insight.confidence != .low && !insight.isExperimental }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } } label: {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(TrainingInsightRenderer.short(insight, strings: strings))
                            .font(LoopType.body.weight(isReliable ? .medium : .regular))
                            .foregroundStyle(isReliable ? LoopColor.textPrimary : LoopColor.textSecondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        TrainingInsightStatus(insight: insight)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.footnote.weight(.semibold)).foregroundStyle(LoopColor.textSecondary)
                        .padding(.top, 4).accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded ? TodayL.text("today.final.detail.hide") : TodayL.text("today.final.detail.show"))
            if expanded {
                Text(TrainingInsightRenderer.detail(insight, strings: strings))
                    .font(LoopType.label).foregroundStyle(LoopColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
