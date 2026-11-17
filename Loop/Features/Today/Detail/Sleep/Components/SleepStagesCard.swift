import SwiftUI

/// The night's shape, behind a disclosure. Collapsed: a compact 60 pt mini-hypnogram
/// where stages read by row position, not hue. Expanded: the full 232 pt chart with a
/// draggable cursor and an hour axis, plus the three restorative-stage shares. One
/// glass surface, monochrome throughout (ported from the old Apple-Health ribbon).
struct SleepStagesCard: View {
    let model: SleepCoachModel

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if model.ribbonSegments.isEmpty {
                Text("today.hypnogramme.non.disponible", tableName: "Today")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else if isExpanded {
                expanded
            } else {
                collapsed
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .deviceSurface()
    }

    private var header: some View {
        HStack(spacing: 10) {
            WidgetLabel(symbol: "waveform.path.ecg", title: String(localized: "today.carte.de.la.nuit", table: "Today"), trailing: model.ribbonTimeRange, tint: model.band.color)
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

    private var collapsed: some View {
        VStack(spacing: 10) {
            SleepMiniHypnogram(segments: model.ribbonSegments)
                .frame(height: 60)

            HStack(spacing: 12) {
                ForEach(SleepStage.ribbonRows) { stage in
                    SleepStageLegendItem(stage: stage)
                }
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var expanded: some View {
        VStack(spacing: 16) {
            SleepStageRibbonChart(segments: model.ribbonSegments)
                .frame(height: 232)

            HStack(spacing: 12) {
                ForEach(SleepStage.ribbonRows) { stage in
                    SleepStageLegendItem(stage: stage)
                }
            }

            Divider().overlay(.secondary.opacity(0.16))

            VStack(spacing: 12) {
                ForEach(model.stageRows) { row in
                    SleepStageShareRow(row: row, totalMinutes: model.totalStageMinutes)
                }
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

// MARK: - Legend

private struct SleepStageLegendItem: View {
    let stage: SleepStage

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(stage.color)
                .frame(width: 9, height: 9)
            Text(stage.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Restorative-stage share rows (expanded only)

private struct SleepStageShareRow: View {
    let row: SleepStageRow
    let totalMinutes: Double

    private var progress: Double {
        guard totalMinutes > 0 else { return 0 }
        return min(max(row.minutes / totalMinutes, 0), 1)
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(row.stage.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(row.durationText)
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.08))
                    Capsule().fill(.primary).frame(width: proxy.size.width * CGFloat(progress))
                }
            }
            .frame(height: 6)
        }
    }
}

// MARK: - Mini hypnogram (collapsed)

/// Compact monochrome hypnogram: one bar per segment placed on its stage row, no axis
/// or cursor. Stages read by vertical position only.
private struct SleepMiniHypnogram: View {
    let segments: [SleepRibbonSegment]

    private var start: Date { segments.first?.from ?? Date() }
    private var end: Date { segments.last?.to ?? Date() }
    private var span: TimeInterval { max(end.timeIntervalSince(start), 1) }

    var body: some View {
        GeometryReader { proxy in
            let layout = RibbonLayout(width: proxy.size.width, height: proxy.size.height)
            ForEach(segments) { segment in
                let frame = layout.barFrame(for: segment, start: start, span: span)
                RoundedRectangle(cornerRadius: layout.cornerRadius, style: .continuous)
                    .fill(segment.stage.color)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
            }
        }
    }
}

// MARK: - Full chart (expanded)

/// Apple-Health-style sleep-stages chart: rounded bars per stage joined by thin links
/// over a masked vertical gradient, an hour/stage axis, and a draggable cursor that
/// surfaces the segment under the finger. Monochrome — stages differ by row.
private struct SleepStageRibbonChart: View {
    let segments: [SleepRibbonSegment]

    private let axisLabelHeight: CGFloat = 16

    @State private var cursorX: CGFloat?

    private var start: Date { segments.first?.from ?? Date() }
    private var end: Date { segments.last?.to ?? Date() }
    private var span: TimeInterval { max(end.timeIntervalSince(start), 1) }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let plotHeight = proxy.size.height - axisLabelHeight
            let layout = RibbonLayout(width: width, height: plotHeight)

            ZStack(alignment: .topLeading) {
                RibbonAxis(segments: segments, start: start, span: span, layout: layout, axisLabelHeight: axisLabelHeight)
                gradientUnderlay(layout: layout)
                bars(layout: layout)

                if let cursorX, let segment = segment(atX: cursorX, width: width) {
                    RibbonCursor(x: cursorX, segment: segment, plotHeight: plotHeight, chartWidth: width)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in cursorX = min(max(value.location.x, 0), width) }
            )
        }
    }

    private func gradientUnderlay(layout: RibbonLayout) -> some View {
        let stops = SleepStage.ribbonRows.map { stage in
            Gradient.Stop(color: stage.color.opacity(0.30), location: layout.centerY(of: stage) / max(layout.height, 1))
        }
        return LinearGradient(gradient: Gradient(stops: stops), startPoint: .top, endPoint: .bottom)
            .frame(width: layout.width, height: layout.height)
            .mask(
                RibbonShape(segments: segments, start: start, span: span)
                    .frame(width: layout.width, height: layout.height)
            )
            .frame(width: layout.width, height: layout.height, alignment: .topLeading)
    }

    private func bars(layout: RibbonLayout) -> some View {
        ForEach(segments) { segment in
            let frame = layout.barFrame(for: segment, start: start, span: span)
            RoundedRectangle(cornerRadius: layout.cornerRadius, style: .continuous)
                .fill(segment.stage.color)
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
        }
    }

    private func segment(atX x: CGFloat, width: CGFloat) -> SleepRibbonSegment? {
        guard !segments.isEmpty else { return nil }
        let fraction = min(max(x / max(width, 1), 0), 1)
        let time = start.addingTimeInterval(fraction * span)
        return segments.first { time >= $0.from && time <= $0.to }
            ?? (fraction <= 0 ? segments.first : segments.last)
    }
}

// MARK: - Geometry

private struct RibbonLayout {
    let width: CGFloat
    let height: CGFloat

    private var rowHeight: CGFloat { height / CGFloat(SleepStage.ribbonRows.count) }
    var barHeight: CGFloat { rowHeight * 0.42 }
    var cornerRadius: CGFloat { min(barHeight / 2, 7) }

    func x(for date: Date, start: Date, span: TimeInterval) -> CGFloat {
        CGFloat(date.timeIntervalSince(start) / span) * width
    }

    func centerY(of stage: SleepStage) -> CGFloat {
        CGFloat(stage.rowIndex) * rowHeight + rowHeight / 2
    }

    func barFrame(for segment: SleepRibbonSegment, start: Date, span: TimeInterval) -> CGRect {
        let left = x(for: segment.from, start: start, span: span)
        let right = x(for: segment.to, start: start, span: span)
        let w = max(right - left, 3)
        let top = centerY(of: segment.stage) - barHeight / 2
        return CGRect(x: left, y: top, width: w, height: barHeight)
    }
}

// MARK: - Ribbon shape (bars + connecting links, used as the gradient mask)

private struct RibbonShape: Shape {
    let segments: [SleepRibbonSegment]
    let start: Date
    let span: TimeInterval

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let layout = RibbonLayout(width: rect.width, height: rect.height)
        let linkWidth: CGFloat = 2.5

        for (index, segment) in segments.enumerated() {
            let frame = layout.barFrame(for: segment, start: start, span: span)
            path.addRoundedRect(
                in: frame,
                cornerSize: CGSize(width: layout.cornerRadius, height: layout.cornerRadius),
                style: .continuous
            )

            guard index < segments.count - 1 else { continue }
            let next = segments[index + 1]
            guard next.stage != segment.stage else { continue }

            let boundaryX = layout.x(for: segment.to, start: start, span: span)
            let centerA = layout.centerY(of: segment.stage)
            let centerB = layout.centerY(of: next.stage)
            let top = min(centerA, centerB)
            let bottom = max(centerA, centerB)
            path.addRect(CGRect(x: boundaryX - linkWidth / 2, y: top, width: linkWidth, height: bottom - top))
        }

        return path
    }
}

// MARK: - Axis (row separators, stage labels, hour grid)

private struct RibbonAxis: View {
    let segments: [SleepRibbonSegment]
    let start: Date
    let span: TimeInterval
    let layout: RibbonLayout
    let axisLabelHeight: CGFloat

    private var hourTicks: [Date] {
        guard let last = segments.last?.to else { return [] }
        var ticks: [Date] = []
        let calendar = Calendar.current
        var tick = calendar.nextDate(
            after: start.addingTimeInterval(-1),
            matching: DateComponents(minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) ?? start
        while tick <= last {
            ticks.append(tick)
            tick = tick.addingTimeInterval(3600)
        }
        return ticks
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                let rowHeight = layout.height / CGFloat(SleepStage.ribbonRows.count)
                for row in 1..<SleepStage.ribbonRows.count {
                    let y = rowHeight * CGFloat(row)
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: layout.width, y: y))
                }
            }
            .stroke(.secondary.opacity(0.12), lineWidth: 1)

            ForEach(SleepStage.ribbonRows) { stage in
                Text(stage.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .position(x: 0, y: 0)
                    .offset(x: 4, y: layout.centerY(of: stage) - layout.barHeight / 2 - 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Path { path in
                for tick in hourTicks {
                    let x = layout.x(for: tick, start: start, span: span)
                    guard x > 1, x < layout.width - 1 else { continue }
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: layout.height))
                }
            }
            .stroke(.secondary.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

            ForEach(hourTicks, id: \.self) { tick in
                let x = layout.x(for: tick, start: start, span: span)
                Text(Self.hourFormatter.string(from: tick))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                    .position(x: x, y: layout.height + axisLabelHeight / 2)
            }
        }
    }

    static let hourFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

// MARK: - Cursor + detail card

private struct RibbonCursor: View {
    let x: CGFloat
    let segment: SleepRibbonSegment
    let plotHeight: CGFloat
    let chartWidth: CGFloat

    private let cardWidth: CGFloat = 168

    private var cardCenterX: CGFloat {
        min(max(x, cardWidth / 2), chartWidth - cardWidth / 2)
    }

    private var rangeText: String {
        let formatter = RibbonAxis.hourFormatter
        return "\(formatter.string(from: segment.from)) – \(formatter.string(from: segment.to))"
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Capsule()
                .fill(.secondary.opacity(0.55))
                .frame(width: 2.5, height: plotHeight)
                .position(x: x, y: plotHeight / 2)

            card
                .frame(width: cardWidth)
                .fixedSize(horizontal: false, vertical: true)
                .position(x: cardCenterX, y: 36)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(segment.stage.title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(segment.durationMinutes)")
                    .font(.system(size: 22, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                Text("min")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Text(rangeText)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .loopCard(.nested, cornerRadius: 14)
    }
}

#Preview {
    SleepStagesCard(model: SleepCoachModel(metric: .sleepPreview(score: 78)))
        .padding()
        .background(Color(.systemGroupedBackground))
}
