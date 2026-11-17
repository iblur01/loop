import SwiftUI

/// How to act on the score, prescriptive. A title set by the band, a tailored message
/// driven by the limiting driver (low HRV / high RHR / poor sleep), and the band-coloured
/// seal — the one accent that flags this as the actionable card.
struct RecoveryImproveCard: View {
    let model: RecoveryCoachModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WidgetLabel(symbol: "figure.run", title: String(localized: "today.comment.ameliorer", table: "Today"), tint: model.band.color)

            Text(model.improvementTitle)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(model.band.color)
                    .padding(.top, 1)
                Text(model.improvementMessage)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .deviceSurface()
    }
}

#Preview("Basse") {
    RecoveryImproveCard(model: .preview(score: 28))
        .padding()
        .background(Color(.systemGroupedBackground))
}

#Preview("Haute") {
    RecoveryImproveCard(model: .preview(score: 85))
        .padding()
        .background(Color(.systemGroupedBackground))
}
