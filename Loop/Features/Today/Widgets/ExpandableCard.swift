import SwiftUI
import UIKit

/// Reusable expandable widget shell. Collapsed: a label row + a glanceable summary. Tapping the
/// header springs open a detail section (progressive disclosure) with a soft haptic and a rotating
/// chevron. One sober glass surface — the card the whole Today page is built from.
///
/// ```
/// ExpandableCard(symbol: "bed.double.fill", title: String(localized: "today.sommeil", table: "Today")) {
///     summaryView
/// } detail: {
///     detailView
/// }
/// ```
struct ExpandableCard<Summary: View, Detail: View>: View {
    let symbol: String
    let title: String
    /// Tint for the leading icon. Keep `.secondary` when the card already carries colour elsewhere
    /// (e.g. a coloured bar) — only one accent per card.
    var symbolColor: Color = .secondary
    var trailing: String? = nil
    @ViewBuilder var summary: () -> Summary
    @ViewBuilder var detail: () -> Detail

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { expanded.toggle() }
            } label: {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: symbol)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(symbolColor)
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
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                    summary()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 12) {
                    Rectangle().fill(.primary.opacity(0.06)).frame(height: 1)
                    detail()
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .loopGlass()
    }
}

/// A small detail row used inside expanded sections: label left, value right.
struct WidgetDetailRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
        }
    }
}

/// A quiet inline "see full detail" navigation link for expanded sections.
struct WidgetDetailLink<Value: Hashable>: View {
    let title: String
    let value: Value

    var body: some View {
        NavigationLink(value: value) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }
}
