import SwiftUI
import Charts
import UIKit

/// The page's foregrounded chart. A smooth HR curve with a soft area fill, a dashed resting-HR
/// reference line for context, and drag-to-scrub: a cursor that snaps to the nearest sample,
/// reads out its value + time, and fires a light haptic when it crosses to a new point. The
/// range picker drives the window. Built on Swift Charts — readable, not a bare path.
struct HeartRateRangeChart: View {
    let model: HeartRateCoachModel
    @Binding var range: HeartRateCoachModel.Range

    @State private var selectedTs: Int?

    private var samples: [HeartRateSample] { model.visibleSamples }

    private var selected: HeartRateSample? {
        guard let ts = selectedTs else { return nil }
        return samples.min { abs($0.ts - ts) < abs($1.ts - ts) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            picker

            if model.hasData {
                chart
                    .frame(height: 196)
                    .id(range)
                caption
            } else {
                ContentUnavailableView(
                    samples.isEmpty ? TodayL.text("today.remaining.hr.no.range") : TodayL.text("today.remaining.hr.insufficient"),
                    systemImage: "waveform.path.ecg"
                )
                .frame(height: 196)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .deviceSurface()
    }

    private var header: some View {
        HStack {
            WidgetLabel(symbol: "waveform.path.ecg", title: "Courbe", tint: model.accent)
            if let sel = selected {
                Text("\(sel.bpm) bpm")
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
            }
        }
    }

    private var picker: some View {
        Picker("Plage", selection: $range) {
            ForEach(HeartRateCoachModel.Range.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .onChange(of: range) { selectedTs = nil }
    }

    private var chart: some View {
        Chart {
            if let rest = model.restingBpm {
                RuleMark(y: .value("Repos", rest))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .annotation(position: .top, alignment: .leading) {
                        Text("Repos \(rest)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
            }

            ForEach(HeartRateCoachModel.chartSegments(samples, bucketSeconds: max(60, Int(range.seconds) / 1000))) { segment in
              ForEach(segment.samples) { s in
                AreaMark(
                    x: .value("Heure", Date(timeIntervalSince1970: TimeInterval(s.ts))),
                    y: .value("BPM", s.bpm), series: .value("Période", segment.id)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(
                    LinearGradient(colors: [model.accent.opacity(0.25), model.accent.opacity(0.02)],
                                   startPoint: .top, endPoint: .bottom)
                )

                LineMark(
                    x: .value("Heure", Date(timeIntervalSince1970: TimeInterval(s.ts))),
                    y: .value("BPM", s.bpm), series: .value("Période", segment.id)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(model.accent)
                .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
              }
            }

            if let sel = selected {
                let date = Date(timeIntervalSince1970: TimeInterval(sel.ts))
                RuleMark(x: .value(TodayL.text("today.final.chart.selection"), date))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(.secondary.opacity(0.4))
                PointMark(x: .value(TodayL.text("today.final.chart.selection"), date), y: .value("BPM", sel.bpm))
                    .symbolSize(120)
                    .foregroundStyle(model.accent)
            }
        }
        .chartYScale(domain: yDomain)
        .chartPlotStyle { $0.clipped() }
        .chartXAxis {
            AxisMarks(preset: .aligned) { _ in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                AxisValueLabel(format: axisTimeFormat)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                AxisValueLabel()
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
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
                                let ts = Int(date.timeIntervalSince1970)
                                let nearest = samples.min { abs($0.ts - ts) < abs($1.ts - ts) }
                                if let nearest, nearest.ts != selectedTs {
                                    selectedTs = nearest.ts
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.5)
                                }
                            }
                            .onEnded { _ in selectedTs = nil }
                    )
            }
        }
    }

    private var caption: some View {
        HStack(spacing: 14) {
            if let sel = selected {
                Label(scrubTimeText(sel.ts), systemImage: "clock")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                Text("today.glisse.sur.la.courbe.pour.explorer", tableName: "Today")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    private var yDomain: ClosedRange<Int> {
        let lo = model.minBpm ?? 50
        let hi = model.maxBpm ?? 120
        let pad = max((hi - lo) / 6, 4)
        return (lo - pad)...(hi + pad)
    }

    private var axisTimeFormat: Date.FormatStyle {
        switch range {
        case .sixHours, .day: return .dateTime.hour()
        default:              return .dateTime.weekday(.abbreviated)
        }
    }

    private func scrubTimeText(_ ts: Int) -> String {
        let f = DateFormatter()
        f.dateFormat = (range == .sixHours || range == .day) ? "HH:mm" : "EEE HH:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
}

#Preview {
    HeartRateRangeChart(model: .preview(), range: .constant(.day))
        .padding()
        .background(Color(.systemGroupedBackground))
}
