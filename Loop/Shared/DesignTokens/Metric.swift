import SwiftUI

// MARK: - HealthState

/// Evaluation vocabulary (spec design §2.2): good / fair / poor, plus neutral for calibration,
/// normal or unknown. Only evaluations and real alerts use these colours, and they always come
/// with a word or a symbol — never the colour alone.
enum HealthState: CaseIterable, Sendable {
    case good, fair, poor, neutral

    var token: TokenColor {
        switch self {
        case .good:    return TokenColor(light: 0x157A3F, dark: 0x34D17A)
        case .fair:    return TokenColor(light: 0x8F6000, dark: 0xFFC233)
        case .poor:    return TokenColor(light: 0xC92F2A, dark: 0xFF5A4F)
        case .neutral: return TokenColor(light: 0x5E5E66, dark: 0xA6A6AD)
        }
    }

    var color: Color { token.color }

    /// Mandatory companion symbol so the state never relies on hue alone.
    var symbol: String {
        switch self {
        case .good:    return "checkmark.circle.fill"
        case .fair:    return "minus.circle.fill"
        case .poor:    return "exclamationmark.triangle.fill"
        case .neutral: return "circle.dashed"
        }
    }
}

// MARK: - Metric

/// One metric, one tint, everywhere (spec design §2.3-2.4): ring, tile, detail page, widget.
/// Recovery and battery are *state* metrics — their colour is their evaluation.
enum Metric: CaseIterable, Sendable {
    case recovery, strain, sleep, cardio, hrv, stress, energy, steps, spo2, temp, battery

    /// Fixed identity tint. For state metrics (recovery, battery) this is the neutral state;
    /// use `color(for:)` to get the evaluated colour.
    var token: TokenColor {
        switch self {
        case .recovery, .battery: return HealthState.neutral.token
        case .strain: return TokenColor(light: 0x0070B8, dark: 0x1FB6FF)
        case .sleep:  return TokenColor(light: 0x5A45D6, dark: 0x8E7CFF)
        case .cardio: return TokenColor(light: 0xC8155A, dark: 0xFF3D7F)
        case .hrv:    return TokenColor(light: 0x007D6E, dark: 0x2FD9C5)
        case .stress: return TokenColor(light: 0x8A3CCF, dark: 0xC77DFF)
        case .energy: return TokenColor(light: 0xB4500A, dark: 0xFF8A3D)
        case .steps:  return TokenColor(light: 0x4A7A0E, dark: 0xA3E635)
        case .spo2:   return TokenColor(light: 0x2F5FD0, dark: 0x7AA7FF)
        case .temp:   return TokenColor(light: 0x9E5200, dark: 0xFFA347)
        }
    }

    var tint: Color { token.color }

    /// The metric's single SF Symbol.
    var symbol: String {
        switch self {
        case .recovery: return "heart.text.square.fill"
        case .strain:   return "flame.fill"
        case .sleep:    return "moon.fill"
        case .cardio:   return "heart.fill"
        case .hrv:      return "waveform.path.ecg"
        case .stress:   return "brain.head.profile"
        case .energy:   return "bolt.fill"
        case .steps:    return "figure.walk"
        case .spo2:     return "lungs.fill"
        case .temp:     return "thermometer.medium"
        case .battery:  return "battery.75percent"
        }
    }

    /// The one threshold set per notion (spec §2.2). Metrics without an intrinsic evaluation
    /// (strain, cardio, energy…) return `.neutral`: their state is expressed by a word, a badge
    /// or a segment relative to a reference, not by their raw value.
    func state(for value: Double) -> HealthState {
        guard value.isFinite else { return .neutral }
        switch self {
        case .recovery:
            // Mirrors the engine's recoveryBand(): red < 34, yellow 34–67, green ≥ 67.
            if value >= 67 { return .good }
            if value >= 34 { return .fair }
            return .poor
        case .sleep:
            // Sleep score 0–100: < 55 poor, 55–70 fair, ≥ 70 good. 0 = no score.
            if value <= 0 { return .neutral }
            if value >= 70 { return .good }
            if value >= 55 { return .fair }
            return .poor
        case .stress:
            // Stress level 0–3: high ≥ 2, steady ≥ 1, low otherwise.
            if value >= 2 { return .poor }
            if value >= 1 { return .fair }
            return .good
        case .battery:
            // Battery %: alert at ≤ 15 (same threshold as the Today alert), low under 35,
            // otherwise neutral (no decorative green).
            if value <= 15 { return .poor }
            if value < 35 { return .fair }
            return .neutral
        default:
            return .neutral
        }
    }

    /// Whether this metric's colour *is* its evaluation.
    var isStateMetric: Bool { self == .recovery || self == .battery }

    /// Display colour for a value: the tint, or the state colour for recovery / battery.
    /// `nil` (no value, calibrating) gives the neutral state for state metrics.
    func color(for value: Double?) -> Color {
        token(for: value).color
    }

    func token(for value: Double?) -> TokenColor {
        guard isStateMetric else { return token }
        guard let value else { return HealthState.neutral.token }
        return state(for: value).token
    }

    /// Battery evaluation including charging (charging reads as good).
    static func batteryState(percent: Int?, isCharging: Bool) -> HealthState {
        if isCharging { return .good }
        guard let percent else { return .neutral }
        return Metric.battery.state(for: Double(percent))
    }
}

// MARK: - MetricLoadState

/// Shared display states for a metric surface (spec design §6).
enum MetricLoadState: Equatable {
    case loading
    /// `day`/`of` when the engine exposes the calibration progress, otherwise nil.
    case calibrating(day: Int?, of: Int?)
    case absent
    case partial(reason: String)
    case contradictory(reason: String)
    case ready
}
