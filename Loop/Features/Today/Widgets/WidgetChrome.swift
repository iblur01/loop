import SwiftUI

/// Shared widget chrome so every Today widget reads the same: a monochrome SF-symbol, a title, and
/// an optional trailing accessory (value or chevron). Keeps widgets atomic — they compose this plus
/// their own body inside `.loopGlass()`.
struct WidgetLabel: View {
    let symbol: String
    let title: String
    var trailing: String? = nil
    var showsChevron: Bool = false
    /// Optional accent for the leading symbol — the single pop of colour a card carries.
    /// `nil` keeps it monochrome (`.secondary`).
    var tint: Color? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint ?? .secondary)
                .frame(width: 20)

            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            if let trailing {
                Text(trailing)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// A big value + small unit, the dominant figure inside a widget. Monochrome.
struct WidgetMetric: View {
    let value: String
    var unit: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
            if let unit {
                Text(unit)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Standard widget padding + sober glass surface.
extension View {
    func widgetSurface() -> some View {
        self
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .loopGlass()
    }
}
