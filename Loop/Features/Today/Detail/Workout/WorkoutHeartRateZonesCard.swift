import SwiftUI
import LoopStrapEngine

/// Répartition du temps par zone de FC, lue telle quelle dans le snapshot de séance
/// (`WorkoutSession.heartRateZones`, calculé par le moteur avec la charge cardio). Aucun calcul
/// de zone ici ; sans données moteur, la carte ne rend rien.
struct WorkoutHeartRateZonesCard: View {
    let zones: HeartRateZoneBreakdown?

    var body: some View {
        if let zones, zones.totalMinutes > 0 {
            content(zones)
        }
    }

    private struct Row: Identifiable {
        let id: Int
        let title: String
        let range: String
        let minutes: Double
        let share: Double
        let color: Color
    }

    /// Rampe de zones partagée (`LoopColor.zone`), zones 1 à 5.
    private static let zoneColors: [Color] = (1...5).map { LoopColor.zone($0) }

    /// Borne basse arrondie d'une zone (1…5), fournie par le moteur.
    private static func lower(_ p: HeartRateZoneBreakdown, _ zone: Int) -> Int {
        Int((p.lowerBpm(zone: zone) ?? 0).rounded())
    }

    private func rows(_ p: HeartRateZoneBreakdown) -> [Row] {
        let total = p.totalMinutes
        var out = (0..<5).reversed().map { i -> Row in
            let low = Self.lower(p, i + 1)
            let range = i == 4 ? "≥ \(low) bpm" : "\(low)–\(Self.lower(p, i + 2) - 1) bpm"
            return Row(id: i + 1, title: "Zone \(i + 1)", range: range, minutes: p.zoneMinutes[i],
                       share: p.zoneMinutes[i] / total, color: Self.zoneColors[i])
        }
        out.append(Row(id: 0, title: "Sous la zone 1", range: "< \(Self.lower(p, 1)) bpm",
                       minutes: p.belowZoneMinutes, share: p.belowZoneMinutes / total,
                       color: LoopColor.zone(0)))
        return out
    }

    private static func sourceLabel(_ source: MaxHeartRateSource) -> String {
        switch source {
        case .personal: return "max personnel"
        case .estimated: return TodayL.text("today.hr.source.estimated")
        case .replay: return TodayL.text("today.hr.source.set")
        }
    }

    private func content(_ p: HeartRateZoneBreakdown) -> some View {
        let rows = rows(p)
        return VStack(alignment: .leading, spacing: 16) {
            Text("today.zones.de.frequence.cardiaque", tableName: "Today")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)

            stackedBar(rows.reversed())
                .accessibilityHidden(true)

            VStack(spacing: 12) {
                ForEach(rows) { row in
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(row.color)
                            .frame(width: 12, height: 12)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.title).font(.subheadline.weight(.medium))
                            Text(row.range).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Spacer(minLength: 8)
                        Text("\(Int(row.minutes.rounded())) min")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                        Text("\(Int((row.share * 100).rounded())) %")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(minWidth: 44, alignment: .trailing)
                    }
                    .foregroundStyle(row.minutes > 0 ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(row.title), \(row.range.replacingOccurrences(of: "bpm", with: "battements par minute"))")
                    .accessibilityValue(TodayL.format("today.remaining.zone.spoken.value", String(Int(row.minutes.rounded())), String(Int((row.share * 100).rounded()))))
                }
            }

            Divider().overlay(.secondary.opacity(0.12))

            HStack(alignment: .firstTextBaseline) {
                Text("today.methode", tableName: "Today").font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Text(TodayL.format("today.remaining.zone.karvonen", String(Int(p.restingHR.rounded())), Self.sourceLabel(p.maxHRSource), String(Int(p.maxHR.rounded()))))
                    .font(.footnote.weight(.medium))
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
            }
            .accessibilityElement(children: .combine)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .deviceSurface()
    }

    private func stackedBar(_ rows: [Row]) -> some View {
        GeometryReader { proxy in
            HStack(spacing: 2) {
                ForEach(rows) { row in
                    if row.share > 0 {
                        Rectangle()
                            .fill(row.color)
                            .frame(width: max(proxy.size.width * CGFloat(row.share) - 2, 2))
                    }
                }
            }
        }
        .frame(height: 14)
        .clipShape(Capsule())
    }
}
