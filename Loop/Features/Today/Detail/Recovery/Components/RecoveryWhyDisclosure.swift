import SwiftUI

/// "Pourquoi ce score", closed by default. Collapsed: the dominant (limiting) driver in
/// one line. Expanded: the driver narrative (what's holding the score back, what's
/// supporting it) plus how recovery is computed. The detailed per-metric numbers live in
/// the facts group below — this card is the understanding, not the figures.
struct RecoveryWhyDisclosure: View {
    let model: RecoveryCoachModel

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.driverNarrative)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(model.explanation)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .loopCard(.nested, cornerRadius: 14)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .deviceSurface()
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(model.band.color)
                .frame(width: 20)
            Text("today.pourquoi.ce.score", tableName: "Today")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if !isExpanded {
                Text(model.dominantDriverSummary)
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
}

#Preview {
    RecoveryWhyDisclosure(model: .preview(score: 45))
        .padding()
        .background(Color(.systemGroupedBackground))
}
