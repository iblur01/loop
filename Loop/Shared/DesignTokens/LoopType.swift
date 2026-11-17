import SwiftUI

// MARK: - LoopType

/// Type roles (spec design §3). Semantic text styles only, so everything follows Dynamic Type.
/// The hero sizes are `@ScaledMetric` values held by the view (see `ScoreHero`).
enum LoopType {
    /// Hero score, base 72 pt scaled relative to `.largeTitle`.
    static func hero(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
    /// Hero unit, base 30 pt scaled relative to `.title`.
    static func heroUnit(_ size: CGFloat) -> Font { .system(size: size, weight: .medium, design: .rounded) }
    static let heroState = Font.title3.weight(.semibold)
    static let cardValue = Font.system(.largeTitle, design: .rounded).weight(.semibold)
    static let tileValue = Font.system(.title, design: .rounded).weight(.semibold)
    static let cardUnit = Font.title3.weight(.medium)
    static let tileUnit = Font.headline.weight(.medium)
    static let cardTitle = Font.headline
    static let sectionTitle = Font.title2.bold()
    static let label = Font.subheadline
    static let body = Font.body
    static let footnote = Font.footnote
    static let overline = Font.caption.weight(.semibold)
}

// MARK: - Measures

/// Radii and spacings (spec design §2.5).
enum LoopMeasure {
    static let radiusCard: CGFloat = 26
    static let radiusNested: CGFloat = 18
    static let radiusTile: CGFloat = 22
    static let screenGutter: CGFloat = 16
    static let cardPadding: CGFloat = 16
    static let gridSpacing: CGFloat = 12
    static let sectionSpacing: CGFloat = 20
    static let segmentedBarHeight: CGFloat = 8
    static let segmentedBarGap: CGFloat = 2
    static let cursorTriangle: CGFloat = 12
    static let minTarget: CGFloat = 44
}

// MARK: - Opaque card surface

enum LoopCardLevel {
    /// Top-level data card (`surface.card` + 1 px stroke).
    case card
    /// Nested block inside a card (`surface.nested`, no stroke).
    case nested
}

/// The one opaque surface for data (spec §5.2). Data cards are never glass, never tinted.
struct LoopCard: ViewModifier {
    var level: LoopCardLevel = .card
    var cornerRadius: CGFloat?

    func body(content: Content) -> some View {
        let radius = cornerRadius ?? (level == .card ? LoopMeasure.radiusCard : LoopMeasure.radiusNested)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(level == .card ? LoopColor.surfaceCard : LoopColor.surfaceNested, in: shape)
            .overlay {
                if level == .card { shape.strokeBorder(LoopColor.strokeCard, lineWidth: 1) }
            }
    }
}

extension View {
    /// Opaque data surface. `.card` for a top-level card, `.nested` inside a card.
    func loopCard(_ level: LoopCardLevel = .card, cornerRadius: CGFloat? = nil) -> some View {
        modifier(LoopCard(level: level, cornerRadius: cornerRadius))
    }
}
