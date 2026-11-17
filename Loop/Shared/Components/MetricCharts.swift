import SwiftUI

// MARK: - SegmentedCursorBar

/// Segmented track with a triangle cursor at the value (spec design §6 #5). Empty segments in
/// `track.empty`, the active segment coloured. Optional labels under the segments carry the
/// meaning in words. VoiceOver reads "value, segment n of m".
struct SegmentedCursorBar: View {
    struct Segment {
        /// Upper bound of the segment (the last one ends at `range.upperBound`).
        let upperBound: Double
        let label: String
    }

    let range: ClosedRange<Double>
    let segments: [Segment]
    let value: Double
    let activeColor: Color
    var showsLabels: Bool = true
    /// Spoken value (e.g. "14,2").
    var valueText: String

    private var activeIndex: Int {
        segments.firstIndex { value < $0.upperBound } ?? (segments.count - 1)
    }

    private func lowerBound(_ index: Int) -> Double {
        index == 0 ? range.lowerBound : segments[index - 1].upperBound
    }

    private func fraction(_ v: Double) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return CGFloat(min(max((v - range.lowerBound) / span, 0), 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let w = geo.size.width
                let gap = LoopMeasure.segmentedBarGap
                let tri = LoopMeasure.cursorTriangle
                ZStack(alignment: .topLeading) {
                    ForEach(segments.indices, id: \.self) { i in
                        let x0 = fraction(lowerBound(i)) * w
                        let x1 = fraction(min(segments[i].upperBound, range.upperBound)) * w
                        RoundedRectangle(cornerRadius: LoopMeasure.segmentedBarHeight / 2, style: .continuous)
                            .fill(i == activeIndex ? activeColor : LoopColor.trackEmpty)
                            .frame(width: max(x1 - x0 - gap, 2), height: LoopMeasure.segmentedBarHeight)
                            .offset(x: x0, y: tri + 2)
                    }
                    CursorTriangle()
                        .fill(LoopColor.textPrimary)
                        .frame(width: tri, height: tri * 0.8)
                        .offset(x: min(max(fraction(value) * w - tri / 2, 0), w - tri), y: 0)
                }
            }
            .frame(height: LoopMeasure.cursorTriangle + 2 + LoopMeasure.segmentedBarHeight)

            if showsLabels {
                GeometryReader { geo in
                    let w = geo.size.width
                    ZStack(alignment: .topLeading) {
                        ForEach(segments.indices, id: \.self) { i in
                            let x0 = fraction(lowerBound(i)) * w
                            let x1 = fraction(min(segments[i].upperBound, range.upperBound)) * w
                            Text(segments[i].label)
                                .font(LoopType.footnote.weight(i == activeIndex ? .semibold : .regular))
                                .foregroundStyle(i == activeIndex ? LoopColor.textPrimary : LoopColor.textSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .frame(width: max(x1 - x0, 1), alignment: .leading)
                                .offset(x: x0)
                        }
                    }
                }
                .frame(height: 20)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(valueText), \(segments[activeIndex].label), segment \(activeIndex + 1) sur \(segments.count)")
    }
}

private struct CursorTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - DayBarsChart

/// Rounded bars with the value above (spec design §5.6 réf., §6 #4). Current day on a
/// `surface.highlight` column; a day without data is a short dash, never a zero bar.
struct DayBarsChart: View {
    struct Day: Identifiable {
        let id: String
        /// Short label under the bar ("L", "M"…).
        let label: String
        /// Full spoken label ("lundi 10 novembre").
        let spokenLabel: String
        let value: Double?
        let valueText: String
        let isCurrent: Bool
    }

    let days: [Day]
    let maxValue: Double
    let tint: Color

    @ScaledMetric(relativeTo: .body) private var chartHeight: CGFloat = 110

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(days) { day in
                VStack(spacing: 6) {
                    Text(day.value == nil ? " " : day.valueText)
                        .font(LoopType.footnote.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(day.isCurrent ? LoopColor.textPrimary : LoopColor.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)

                    ZStack(alignment: .bottom) {
                        Color.clear
                        if let v = day.value {
                            UnevenRoundedRectangle(topLeadingRadius: 9, bottomLeadingRadius: 3,
                                                   bottomTrailingRadius: 3, topTrailingRadius: 9,
                                                   style: .continuous)
                                .fill(tint.opacity(day.isCurrent ? 1 : 0.55))
                                .frame(height: max(chartHeight * CGFloat(min(v / maxValue, 1)), 6))
                        } else {
                            Capsule()
                                .fill(LoopColor.trackEmpty)
                                .frame(width: 12, height: 3)
                        }
                    }
                    .frame(height: chartHeight)
                    .frame(maxWidth: 22)

                    Text(day.label)
                        .font(LoopType.footnote.weight(day.isCurrent ? .semibold : .regular))
                        .foregroundStyle(day.isCurrent ? LoopColor.textPrimary : LoopColor.textSecondary)
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background {
                    if day.isCurrent {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(LoopColor.surfaceHighlight)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(day.spokenLabel)
                .accessibilityValue(day.value == nil ? String(localized: "charts.noData", table: "Core") : day.valueText)
                .accessibilityAddTraits(day.isCurrent ? .isSelected : [])
            }
        }
    }
}
