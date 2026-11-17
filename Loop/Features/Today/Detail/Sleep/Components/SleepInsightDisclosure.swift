import SwiftUI

/// "Pourquoi ce score", closed by default. Collapsed: a single line with the dominant
/// driver. Expanded: the three drivers as monochrome rows, each with a contribution
/// bar (its rough weight in the score), plus a prose "ce que ça veut dire" inset.
struct SleepInsightDisclosure: View {
    let model: SleepCoachModel

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if isExpanded {
                VStack(spacing: 16) {
                    ForEach(model.drivers) { driver in
                        SleepDriverRow(driver: driver)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))

                Text(model.simpleSummary)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .loopCard(.nested, cornerRadius: 14)
                    .transition(.opacity)
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

private struct SleepDriverRow: View {
    let driver: SleepDriver

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: driver.systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 3) {
                    Text(driver.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(driver.message)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.08))
                    Capsule().fill(.primary.opacity(0.6))
                        .frame(width: proxy.size.width * CGFloat(min(max(driver.weight, 0), 1)))
                }
            }
            .frame(height: 4)
            .padding(.leading, 34)
        }
    }
}

#Preview("Score bas") {
    SleepInsightDisclosure(model: SleepCoachModel(metric: .sleepPreview(score: 48, totalSleepMin: 360)))
        .padding()
        .background(Color(.systemGroupedBackground))
}
