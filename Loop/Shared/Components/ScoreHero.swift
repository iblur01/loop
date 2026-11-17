import SwiftUI

// MARK: - StateLabel

/// A state always told by a word *and* a symbol, in the state colour (spec design §2.2, §8.6).
struct StateLabel: View {
    let state: HealthState
    let text: String
    var font: Font = LoopType.label.weight(.semibold)
    /// Overrides the state's default symbol (e.g. `exclamationmark.circle` for a contradiction).
    var symbol: String? = nil

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol ?? state.symbol)
                .accessibilityHidden(true)
        }
        .font(font)
        .foregroundStyle(state.color)
    }
}

// MARK: - PartialNote

/// "Partial data" mention: footnote + half-filled circle, no state colour (spec §6).
struct PartialNote: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "circle.lefthalf.filled")
            .font(LoopType.footnote)
            .foregroundStyle(LoopColor.textSecondary)
    }
}

// MARK: - ScoreHero

/// The one score of a screen (spec design §6 #1), laid directly on `bg.base`, no card.
/// Ink number, smaller unit in the metric tint, state word + symbol, context line.
/// Numbers never take a colour; the tint lives on the icon and the unit.
struct ScoreHero: View {
    let metric: Metric
    let overline: String
    let value: String
    var unit: String? = nil
    let state: HealthState
    let stateText: String
    var stateSymbol: String? = nil
    var context: String? = nil
    var partialNote: String? = nil
    /// Spoken value, e.g. "14,2 sur 21".
    var accessibilityValue: String? = nil

    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 72
    @ScaledMetric(relativeTo: .title) private var unitSize: CGFloat = 30
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(overline.uppercased())
                    .tracking(0.6)
            } icon: {
                Image(systemName: metric.symbol)
                    .foregroundStyle(metric.tint)
                    .accessibilityHidden(true)
            }
            .font(LoopType.overline)
            .foregroundStyle(LoopColor.textSecondary)

            valueRow

            StateLabel(state: state, text: stateText, font: LoopType.heroState, symbol: stateSymbol)

            if let context {
                Text(context)
                    .font(LoopType.label)
                    .foregroundStyle(LoopColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let partialNote {
                PartialNote(text: partialNote)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var valueRow: some View {
        let number = Text(value)
            .font(LoopType.hero(heroSize))
            .monospacedDigit()
            .foregroundStyle(LoopColor.textPrimary)
            .contentTransition(.numericText())
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        let unitText = unit.map {
            Text($0)
                .font(LoopType.heroUnit(unitSize))
                .foregroundStyle(metric.tint)
        }
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 0) { number; unitText }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 4) { number; unitText }
        }
    }

    private var accessibilityText: String {
        var parts = [overline, accessibilityValue ?? [value, unit].compactMap { $0 }.joined(separator: " "), stateText]
        if let context { parts.append(context) }
        if let partialNote { parts.append(partialNote) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - WidgetHeader

/// Card title row: metric-tinted icon + `.headline` title in ink + optional trailing text.
struct WidgetHeader: View {
    let symbol: String
    let title: String
    var tint: Color = LoopColor.textSecondary
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(LoopColor.textPrimary)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(LoopType.footnote)
                    .foregroundStyle(LoopColor.textSecondary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .font(LoopType.cardTitle)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - AdviceBlock

/// Short advice under the hero (spec design §6 #7): overline, title, 1–2 sentences.
/// Contradiction = both sentences, neutral, `exclamationmark.circle`, no state colour.
struct AdviceBlock: View {
    let overline: String
    let title: String
    let message: String
    var contradiction: String? = nil
    var level: LoopCardLevel = .card

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(overline.uppercased())
                .font(LoopType.overline)
                .tracking(0.6)
                .foregroundStyle(LoopColor.textSecondary)

            if contradiction != nil {
                StateLabel(state: .neutral, text: "Signaux contradictoires", symbol: "exclamationmark.circle")
            }

            Text(title)
                .font(LoopType.cardTitle)
                .foregroundStyle(LoopColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(message)
                .font(LoopType.body)
                .foregroundStyle(LoopColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let contradiction {
                Text(contradiction)
                    .font(LoopType.body)
                    .foregroundStyle(LoopColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(LoopMeasure.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .loopCard(level)
        .accessibilityElement(children: .combine)
    }
}
