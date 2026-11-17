import SwiftUI
import Charts

/// Resting HR over 14 days, behind a disclosure. A lower resting heart rate trends with better
/// recovery and fitness, so this is the figure worth watching over time — the daily number can't
/// show it. Collapsed: the weekly direction. Expanded: a bar chart with today in accent.
struct HeartRateRestingTrendCard: View {
    let model: HeartRateCoachModel

    @State private var isExpanded = false

    private var series: [HeartRateCoachModel.RestingPoint] { model.restingSeries }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if isExpanded {
                VStack(alignment: .leading, spacing: 16) {
                    chart
                    Text("today.ta.fc.de.repos.est.le.reflet.de.ta.recuperation.plus.elle.baisse.mieux.ton", tableName: "Today")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .loopCard(.nested, cornerRadius: 14)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .deviceSurface()
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "chart.line.downtrend.xyaxis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(model.accent)
                .frame(width: 20)
            Text("today.fc.de.repos", tableName: "Today")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if !isExpanded {
                Text(model.restingTrendText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
        }
        .contentShape(Rectangle())
        .pressable {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { isExpanded.toggle() }
        }
    }

    @ViewBuilder
    private var chart: some View {
        if series.count < 2 {
            Text("today.pas.encore.assez.de.jours.pour.tracer.la.tendance", tableName: "Today")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Chart(series) { point in
                    BarMark(
                        x: .value("Jour", point.date),
                        y: .value(TodayL.text("today.remaining.hr.rest"), point.bpm)
                    )
                    .foregroundStyle(point.isToday ? model.accent : Color.primary.opacity(0.22))
                    .cornerRadius(4)
                }
                .chartYScale(domain: yDomain)
                .chartPlotStyle { $0.clipped() }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                        AxisValueLabel().font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
                .frame(height: 120)

                Text(model.restingTrendText + " · 14 derniers jours")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var yDomain: ClosedRange<Double> {
        let v = series.map(\.bpm)
        let lo = (v.min() ?? 45) - 3
        let hi = (v.max() ?? 70) + 3
        return lo...hi
    }
}

#Preview {
    HeartRateRestingTrendCard(model: .preview())
        .padding()
        .background(Color(.systemGroupedBackground))
}
