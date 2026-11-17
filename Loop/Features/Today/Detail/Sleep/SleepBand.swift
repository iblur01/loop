import SwiftUI

/// The sleep page's single accent band — green/yellow/red by score, mirroring the
/// hero quality thresholds (À améliorer < 55 < Correct < 70 < Bon/Excellent).
/// `calibrating` is the cold-start state with no score yet. This is the *only*
/// colour the Sleep page exposes; everything else stays monochrome ink.
enum SleepBand {
    case red, yellow, green, calibrating

    init(score: Int) {
        if score <= 0 { self = .calibrating; return }
        if score < 55 { self = .red; return }
        if score < 70 { self = .yellow; return }
        self = .green
    }

    var state: HealthState {
        switch self {
        case .green:       return .good
        case .yellow:      return .fair
        case .red:         return .poor
        case .calibrating: return .neutral
        }
    }

    var color: Color { state.color }

    /// `true` for the low/critical state where the hero accent should pulse.
    var isLow: Bool { self == .red }
}
