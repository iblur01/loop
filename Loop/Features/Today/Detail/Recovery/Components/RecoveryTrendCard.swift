import SwiftUI

/// Recovery over time, behind a disclosure. Collapsed: the weekly direction + delta.
/// Expanded: a 14-day monochrome bar chart with today highlighted in band colour and the
/// green-zone threshold (67) marked, so a downward drift is visible at a glance.
struct RecoveryTrendCard: View {
    let model: RecoveryCoachModel

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if isExpanded {
                chart
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .deviceSurface()
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: model.trendDirection.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(model.band.color)
                .frame(width: 20)
            Text("Tendance")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if !isExpanded {
                Text(model.trendText)
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
        let series = model.trendSeries
        if series.count < 2 {
            Text("today.pas.encore.assez.de.jours.pour.tracer.la.tendance", tableName: "Today")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.vertical, 8)
        } else {
            VStack(spacing: 8) {
                GeometryReader { proxy in
                    let h = proxy.size.height
                    ZStack(alignment: .bottom) {
                        // Green-zone threshold (67%).
                        Rectangle()
                            .fill(.secondary.opacity(0.18))
                            .frame(height: 1)
                            .offset(y: -h * 0.67)

                        HStack(alignment: .bottom, spacing: 4) {
                            ForEach(series) { point in
                                Capsule()
                                    .fill(point.isToday ? model.band.color : .primary.opacity(0.22))
                                    .frame(height: min(max(h * CGFloat(point.value / 100), 3), h))
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
                .frame(height: 96)

                Text("\(model.trendText) · 14 derniers jours")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

#Preview {
    RecoveryTrendCard(model: .preview(score: 72))
        .padding()
        .background(Color(.systemGroupedBackground))
}
