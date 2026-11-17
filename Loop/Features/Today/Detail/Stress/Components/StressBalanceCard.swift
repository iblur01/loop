import SwiftUI

/// How the day split between calm and tension, behind a disclosure. Collapsed: the restoration
/// share (% of measured time at the calm level). Expanded: a single stacked bar of Bas / Stable /
/// Élevé minutes plus a legend. Replaces the old three coloured tiles with one honest breakdown.
struct StressBalanceCard: View {
    let model: StressCoachModel

    @State private var isExpanded = false

    private var slices: [StressCoachModel.StateSlice] { model.stateSlices }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if isExpanded {
                VStack(alignment: .leading, spacing: 16) {
                    if slices.isEmpty {
                        Text("today.pas.encore.assez.de.mesures.pour.repartir.la.journee", tableName: "Today")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.tertiary)
                    } else {
                        stackedBar
                        legend
                    }
                    Text("today.le.temps.au.calme.correspond.aux.mesures.sous.le.seuil.de.stress.stable.plu", tableName: "Today")
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
            Text("today.repartition", tableName: "Today")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if !isExpanded {
                Text(model.restorationText)
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

    private var stackedBar: some View {
        GeometryReader { proxy in
            HStack(spacing: 2) {
                ForEach(slices) { slice in
                    if slice.fraction > 0 {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(slice.band.color)
                            .frame(width: max(proxy.size.width * CGFloat(slice.fraction) - 2, 2))
                    }
                }
            }
        }
        .frame(height: 16)
        .clipShape(Capsule())
    }

    private var legend: some View {
        VStack(spacing: 10) {
            ForEach(slices) { slice in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(slice.band.color)
                        .frame(width: 12, height: 12)
                    Text(slice.band.label)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(minutesText(slice.minutes))
                        .font(.system(size: 14, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(slice.fraction > 0 ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                }
            }
        }
    }

    private func minutesText(_ m: Double) -> String {
        guard m > 0 else { return "0 min" }
        if m < 60 { return "\(Int(m.rounded())) min" }
        return "\(Int(m / 60)) h \(Int(m.rounded()) % 60)"
    }
}

#Preview {
    StressBalanceCard(model: .preview(score: 1.4))
        .padding()
        .background(Color(.systemGroupedBackground))
}
