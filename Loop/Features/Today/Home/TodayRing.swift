import SwiftUI

/// Atomic hero ring: the kept `RingView` with a centred value and a label below. Monochrome text,
/// coloured ring. One of three in `TodayRingsHero`.
struct TodayRing: View {
    let model: TodayRingModel

    @State private var appeared = false

    var body: some View {
        VStack(spacing: 11) {
            ZStack {
                RingView(
                    color: model.color,
                    current: appeared ? model.current : 0,
                    maxValue: model.maxValue,
                    targetMin: model.targetMin ?? 0,
                    targetMax: model.targetMax ?? 0,
                    lineWidth: 7
                )

                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(model.valueText)
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText(value: model.current))
                    if let unit = model.unitText {
                        Text(unit)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 92, height: 92)

            Text(model.label)
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .onAppear { withAnimation(.spring(response: 0.7, dampingFraction: 0.85)) { appeared = true } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model.label) \(model.valueText)\(model.unitText ?? "")")
    }
}

#Preview {
    HStack {
        ForEach(TodayRingModel.trio(from: nil, strainTarget: 15.5)) { TodayRing(model: $0) }
    }
    .padding()
}
