import SwiftUI

/// "Pourquoi ce niveau", closed by default. Collapsed: the dominant driver. Expanded: a short
/// narrative, the ranked physiological drivers with weight bars (HRV, heart rate, baseline,
/// movement), and how stress is computed. This is the page's added "understand" layer.
struct StressWhyDisclosure: View {
    let model: StressCoachModel

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if isExpanded {
                VStack(alignment: .leading, spacing: 16) {
                    Text(model.whyNarrative)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(spacing: 14) {
                        ForEach(model.drivers) { driver in
                            DriverRow(driver: driver, accent: model.accent)
                        }
                    }

                    Text(model.explanation)
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
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(model.accent)
                .frame(width: 20)
            Text("today.pourquoi.ce.niveau", tableName: "Today")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if !isExpanded {
                Text(model.dominantSummary)
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

private struct DriverRow: View {
    let driver: StressCoachModel.Driver
    let accent: Color

    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(driver.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
            Text(driver.detail)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.08))
                    Capsule().fill(accent)
                        .frame(width: proxy.size.width * CGFloat(appeared ? driver.weight : 0))
                        .animation(.spring(response: 0.6, dampingFraction: 0.85), value: appeared)
                }
            }
            .frame(height: 6)
        }
        .onAppear { appeared = true }
    }
}

#Preview {
    StressWhyDisclosure(model: .preview(score: 2.2))
        .padding()
        .background(Color(.systemGroupedBackground))
}
