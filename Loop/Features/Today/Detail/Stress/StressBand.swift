import SwiftUI

/// Stress level on the 0–3 scale, banded. Like Recovery, this is a state where low is genuinely
/// good and high genuinely bad, so the band carries the page's one accent (green→amber→red by
/// level only — not a decorative per-row tint).
enum StressBand {
    case low, steady, high, calibrating

    init(score: Double?) {
        guard let score, score.isFinite else { self = .calibrating; return }
        if score >= 2.0 { self = .high }
        else if score >= 1.0 { self = .steady }
        else { self = .low }
    }

    var label: String {
        switch self {
        case .low:         return String(localized: "today.bas", table: "Today")
        case .steady:      return String(localized: "today.stable", table: "Today")
        case .high:        return String(localized: "today.eleve", table: "Today")
        case .calibrating: return String(localized: "today.calibrage", table: "Today")
        }
    }

    var state: HealthState {
        switch self {
        case .low:         return .good
        case .steady:      return .fair
        case .high:        return .poor
        case .calibrating: return .neutral
        }
    }

    var color: Color { state.color }

    /// Whether the level warrants a warning treatment (high only).
    var isElevated: Bool { self == .high }
}
