import SwiftUI

/// The day's stress figures, grouped into one glass surface — not a row of coloured tiles. Each
/// row: label, value, and a band-coloured sub-bar (the card's one accent) where a fraction makes
/// sense. Monochrome otherwise; "—" when missing.
struct StressFactsGroup: View {
    let model: StressCoachModel

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.facts.enumerated()), id: \.element.id) { index, fact in
                if index > 0 {
                    Divider().overlay(.secondary.opacity(0.12)).padding(.leading, 16)
                }
                StressFactRow(fact: fact, accent: model.accent)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .deviceSurface()
    }
}

private struct StressFactRow: View {
    let fact: StressCoachModel.Fact
    let accent: Color

    @State private var appeared = false

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(fact.label)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(fact.value)
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(fact.value == "—" ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            }

            if let fraction = fact.fraction {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.primary.opacity(0.08))
                        Capsule().fill(accent)
                            .frame(width: proxy.size.width * CGFloat(appeared ? fraction : 0))
                            .animation(.spring(response: 0.6, dampingFraction: 0.85), value: appeared)
                    }
                }
                .frame(height: 6)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .onAppear { appeared = true }
    }
}

#Preview {
    StressFactsGroup(model: .preview(score: 1.4))
        .padding()
        .background(Color(.systemGroupedBackground))
}
