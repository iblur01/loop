import SwiftUI
import Charts
import UIKit

/// The day's stress over 24 h, foregrounded. A smooth curve with a soft area fill and three faint
/// band guides (Bas / Stable / Élevé), plus drag-to-scrub: a cursor snaps to the nearest reading,
/// shows its time + level + context, and ticks a light haptic on each new point. Swift Charts —
/// legible, not a bare path.
struct StressTimelineCard: View {
    let model: StressCoachModel

    @State private var selectedID: UUID?

    private var points: [StressCoachModel.TimelinePoint] { model.timelinePoints }

    private var selected: StressCoachModel.TimelinePoint? {
        guard let id = selectedID else { return nil }
        return points.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if model.hasTimeline {
                chart.frame(height: 196)
                caption
            } else {
                ContentUnavailableView(TodayL.text("today.final.missing.today"), systemImage: "waveform.path")
                    .frame(height: 196)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .deviceSurface()
    }

    private var header: some View {
        HStack {
            WidgetLabel(symbol: "waveform.path.ecg", title: String(localized: "today.journee", table: "Today"), tint: model.accent)
            if let sel = selected {
                Text(String(format: "%.1f", sel.score))
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
            }
        }
    }

    private var chart: some View {
        Chart {
            // Faint band guides at the Stable / Élevé thresholds.
            RuleMark(y: .value("Stable", 1.0))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                .foregroundStyle(.secondary.opacity(0.25))
            RuleMark(y: .value(TodayL.text("today.final.stress.high"), 2.0))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                .foregroundStyle(.secondary.opacity(0.25))

            ForEach(points) { p in
                AreaMark(x: .value("Heure", p.date), y: .value("Stress", p.score))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(
                        LinearGradient(colors: [model.accent.opacity(0.22), model.accent.opacity(0.02)],
                                       startPoint: .top, endPoint: .bottom)
                    )
                LineMark(x: .value("Heure", p.date), y: .value("Stress", p.score))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(model.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
            }

            if let sel = selected {
                RuleMark(x: .value(TodayL.text("today.final.chart.selection"), sel.date))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(.secondary.opacity(0.4))
                PointMark(x: .value(TodayL.text("today.final.chart.selection"), sel.date), y: .value("Stress", sel.score))
                    .symbolSize(120)
                    .foregroundStyle(model.accent)
            }
        }
        .chartYScale(domain: 0...3)
        .chartPlotStyle { $0.clipped() }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 1, 2, 3]) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                AxisValueLabel { stressTick(value.as(Int.self)) }
            }
        }
        .chartXAxis {
            AxisMarks(preset: .aligned) { _ in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                AxisValueLabel(format: .dateTime.hour())
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard let plot = proxy.plotFrame else { return }
                                let x = value.location.x - geo[plot].origin.x
                                guard let date: Date = proxy.value(atX: x) else { return }
                                let nearest = points.min {
                                    abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
                                }
                                if let nearest, nearest.id != selectedID {
                                    selectedID = nearest.id
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.5)
                                }
                            }
                            .onEnded { _ in selectedID = nil }
                    )
            }
        }
    }

    @ViewBuilder
    private func stressTick(_ value: Int?) -> some View {
        let labels = ["Bas", "", "", "Max"]
        if let v = value, v >= 0, v < labels.count, !labels[v].isEmpty {
            Text(labels[v]).font(.system(size: 10)).foregroundStyle(.tertiary)
        } else {
            Text(value.map { "\($0)" } ?? "").font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    private var caption: some View {
        HStack(spacing: 8) {
            if let sel = selected {
                Label(scrubTimeText(sel.date), systemImage: "clock")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                if let ctx = sel.context, !ctx.isEmpty {
                    Text("· \(ctx)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("today.glisse.sur.la.courbe.pour.explorer.ta.journee", tableName: "Today")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    private func scrubTimeText(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}

#Preview {
    StressTimelineCard(model: .preview(score: 1.6))
        .padding()
        .background(Color(.systemGroupedBackground))
}
