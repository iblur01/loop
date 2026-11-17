import SwiftUI
import UIKit

// MARK: - TokenColor

/// One colour token: a light and a dark sRGB value (0xRRGGBB) plus an optional alpha.
/// The single place where raw colour values live (spec design §2). Everything else reads
/// `LoopColor`, `Metric` or `HealthState`.
struct TokenColor: Sendable, Equatable {
    let light: UInt32
    let dark: UInt32
    var lightAlpha: Double = 1
    var darkAlpha: Double = 1

    /// Dynamic SwiftUI colour that follows the system appearance.
    var color: Color {
        let l = Self.uiColor(light, alpha: lightAlpha)
        let d = Self.uiColor(dark, alpha: darkAlpha)
        return Color(UIColor { $0.userInterfaceStyle == .dark ? d : l })
    }

    /// Light-mode hex ("RRGGBB"), for consumers that only take a fixed value (WidgetKit snapshot).
    var lightHex: String { String(format: "%06X", light) }

    private static func uiColor(_ hex: UInt32, alpha: Double) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: CGFloat(alpha))
    }
}

// MARK: - Surfaces & text

/// Surfaces, text and tracks (spec design §2.1). Cards are opaque; glass is reserved to navigation,
/// actions and sheets (§5).
enum LoopColor {
    enum Token {
        static let bgBase = TokenColor(light: 0xF2F2F7, dark: 0x000000)
        static let bgSheet = TokenColor(light: 0xF7F7FA, dark: 0x0E0E10)
        static let surfaceCard = TokenColor(light: 0xFFFFFF, dark: 0x1A1A1D)
        static let surfaceNested = TokenColor(light: 0xF2F2F6, dark: 0x2A2A2E)
        static let surfaceHighlight = TokenColor(light: 0xE4E4EA, dark: 0x3A3A3E)
        static let strokeCard = TokenColor(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.06, darkAlpha: 0.08)
        static let trackEmpty = TokenColor(light: 0xE2E2E8, dark: 0x2C2C2E)
        static let textPrimary = TokenColor(light: 0x0B0B0C, dark: 0xFFFFFF)
        static let textSecondary = TokenColor(light: 0x5E5E66, dark: 0xA6A6AD)
        static let textTertiary = TokenColor(light: 0x8A8A90, dark: 0x7C7C83)
    }

    /// Screen background, plain (replaces the navy gradient).
    static let bgBase = Token.bgBase.color
    static let bgSheet = Token.bgSheet.color
    /// Data card.
    static let surfaceCard = Token.surfaceCard.color
    /// Nested card, advice block, zone row.
    static let surfaceNested = Token.surfaceNested.color
    /// Current-day column, active option.
    static let surfaceHighlight = Token.surfaceHighlight.color
    static let strokeCard = Token.strokeCard.color
    /// Empty track and segments.
    static let trackEmpty = Token.trackEmpty.color
    static let textPrimary = Token.textPrimary.color
    /// Labels, neutral units, advice. Replaces system `.secondary` (≈3.3:1 in light).
    static let textSecondary = Token.textSecondary.color
    /// Decorative only — never carries information (≈3.4:1).
    static let textTertiary = Token.textTertiary.color
}

// MARK: - Heart-rate zone ramp

extension LoopColor {
    /// Z0…Z5 ramp (spec §2.3): grey, then SpO2 blue, HRV teal, green, energy orange, cardio pink.
    /// Always shown with a zone label — the hue alone never identifies a zone.
    static func zone(_ index: Int) -> Color {
        switch index {
        case ..<1: return TokenColor(light: 0x8E8E93, dark: 0x8E8E93).color
        case 1:    return Metric.spo2.token.color
        case 2:    return Metric.hrv.token.color
        case 3:    return TokenColor(light: 0x34D17A, dark: 0x34D17A).color
        case 4:    return Metric.energy.token.color
        default:   return Metric.cardio.token.color
        }
    }
}
