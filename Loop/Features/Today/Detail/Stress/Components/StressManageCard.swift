import SwiftUI

/// What to do about today's stress, prescriptive. A title set by band, a tailored message, and the
/// accent-coloured seal flagging this as the actionable card. Mirrors the manage card on Strain.
struct StressManageCard: View {
    let model: StressCoachModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WidgetLabel(symbol: "wind", title: String(localized: "today.comment.gerer", table: "Today"), tint: model.accent)

            Text(model.manageTitle)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(model.accent)
                    .padding(.top, 1)
                Text(model.manageMessage)
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

#Preview("Élevé") {
    StressManageCard(model: .preview(score: 2.3))
        .padding()
        .background(Color(.systemGroupedBackground))
}

#Preview("Bas") {
    StressManageCard(model: .preview(score: 0.6))
        .padding()
        .background(Color(.systemGroupedBackground))
}
