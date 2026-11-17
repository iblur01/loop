import SwiftUI

/// Half-width metric tile — a coloured icon, a title, one big figure, an optional caption. Taps
/// through to a detail. Two of these sit side by side (Cardio · Stress). The icon is the tile's one
/// touch of colour.
struct CompactMetricTile<Value: Hashable>: View {
    let symbol: String
    let symbolColor: Color
    let title: String
    let value: String
    var unit: String? = nil
    var caption: String? = nil
    let navValue: Value

    var body: some View {
        NavigationLink(value: navValue) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(symbolColor)
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }

                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText())
                    if let unit {
                        Text(unit)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    if let caption {
                        Spacer(minLength: 6)
                        Text(caption)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .loopGlass()
        }
        .buttonStyle(.plain)
    }
}
