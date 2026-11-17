import SwiftUI
import LoopStrapEngine

/// The page's added layer: where the heart spent the day's load window. Collapsed shows the
/// dominant zone; expanded shows a single stacked bar of the engine's zones (below zone 1, then
/// zones 1…5) plus a legend with each zone's minutes and share. Minutes, bounds and references
/// are read from the daily snapshot (LoopStrapEngine) — nothing is computed here. Without engine
/// data the card renders nothing.
struct HeartRateZonesCard: View {
    let model: HeartRateCoachModel

    @State private var isExpanded = false

    private var distribution: [(zone: HeartRateZone, fraction: Double, minutes: Double)] {
        model.zoneDistribution
    }

    var body: some View {
        if let zones = model.zones, !distribution.isEmpty {
            card(zones)
        }
    }

    private static func sourceLabel(_ source: MaxHeartRateSource) -> String {
        switch source {
        case .personal: return "max personnel"
        case .estimated: return TodayL.text("today.hr.source.estimated.data")
        case .replay: return TodayL.text("today.hr.source.set")
        }
    }

    private var dayLabel: String {
        guard let date = model.zonesDate else { return "" }
        let parse = DateFormatter(); parse.dateFormat = "yyyy-MM-dd"
        guard let d = parse.date(from: date) else { return date }
        if Calendar.current.isDateInToday(d) { return "aujourd'hui" }
        let out = DateFormatter(); out.locale = Locale.current; out.setLocalizedDateFormatFromTemplate("EEEE d MMMM")
        return out.string(from: d)
    }

    private func card(_ zones: HeartRateZoneBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if isExpanded {
                VStack(alignment: .leading, spacing: 16) {
                    stackedBar
                    legend
                    if let below = model.belowZoneMinutes, below >= 1 {
                        Text(TodayL.format("today.final.heart.zone.rest", StrainCoachModel.durationText(below)))
                            .font(.footnote)
                            .foregroundStyle(LoopColor.textSecondary)
                    }
                    Text(TodayL.format("today.final.heart.zone.description", dayLabel, String(Int(zones.restingHR.rounded())), Self.sourceLabel(zones.maxHRSource), String(Int(zones.maxHR.rounded()))))
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
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(model.accent)
                .frame(width: 20)
            Text(TodayL.format("today.final.heart.zone.total", StrainCoachModel.durationText(model.activeZoneMinutes)))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if !isExpanded, let dominant = model.dominantZone {
                Text(dominant.shortLabel)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(LoopColor.textSecondary)
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

    private var stackedBar: some View {
        GeometryReader { proxy in
            HStack(spacing: 2) {
                ForEach(distribution, id: \.zone.id) { item in
                    if item.fraction > 0 {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(item.zone.color)
                            .frame(width: max(proxy.size.width * CGFloat(item.fraction) - 2, 2))
                    }
                }
            }
        }
        .frame(height: 16)
        .clipShape(Capsule())
    }

    private var legend: some View {
        VStack(spacing: 10) {
            ForEach(distribution, id: \.zone.id) { item in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(item.zone.color)
                        .frame(width: 12, height: 12)
                    Text(item.zone.label)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(StrainCoachModel.durationText(item.minutes))
                        .font(.system(size: 14, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text("\(Int((item.fraction * 100).rounded())) %")
                        .font(.system(size: 14, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(item.fraction > 0 ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                        .frame(minWidth: 40, alignment: .trailing)
                }
            }
        }
    }
}

#Preview {
    HeartRateZonesCard(model: .preview())
        .padding()
        .background(Color(.systemGroupedBackground))
}
