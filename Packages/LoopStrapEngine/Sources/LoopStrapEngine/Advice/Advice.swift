import Foundation

// MARK: - AdviceThresholds

/// Tunable constants ported from `advice.py` — values carried as-is, without re-tuning.
///
/// Mirrors the module-level constants in `advice.py`.  All values are marked
/// `[ASSUMED] tunable` — they were not validated against personal data and may
/// need adjustment once real-world data is available.
enum AdviceThresholds {
    /// Number of prior nights used to compute the cumulative sleep-debt window.
    static let sleepDebtWindowNights: Int = 5        // [ASSUMED] tunable
    /// Minimum accumulated sleep deficit (minutes) over the window to emit SLEEP_DEBT.
    static let sleepDebtThresholdMin: Double = 90.0  // [ASSUMED] tunable
    /// Bedtime-offset shift (minutes) relative to baseline that triggers EARLIER_BEDTIME.
    static let earlierBedtimeOffsetMin: Double = 20.0 // [ASSUMED] tunable
    /// Effort target factor applied to strain baseline for a yellow-recovery day.
    static let effortTargetYellowFactor: Double = 0.7 // [ASSUMED] tunable
    /// Maximum effort target (score 0–21) for a red-recovery day.
    static let effortTargetRedCeiling: Double = 4.0   // [ASSUMED] tunable
    /// Number of recent days used to detect a strain-overload trend.
    static let effortTargetTrendWindowDays: Int = 3   // [ASSUMED] tunable
}

// MARK: - _CONFIDENCE_MAP

// Independence note: this mapping is duplicated from Recovery.swift intentionally.
// advice.py carries the same duplication to keep the advice module free of any
// dependency on recovery.py.  Do NOT replace this with a call to confidenceFromStatus()
// in Recovery.swift.
private let _CONFIDENCE_MAP: [String: String] = [
    "low":    "low",
    "medium": "medium",
    "high":   "high"
]

// MARK: - AdviceCode

/// Structured signal codes produced by the advice engine.
///
/// Raw values mirror the Python `AdviceCode` string constants in `advice.py`.
/// The coach layer (M2) maps these codes to localised human-readable messages.
public enum AdviceCode: String {
    case recoveryCalibrating       = "RECOVERY_CALIBRATING"
    case restRedRecovery           = "REST_RED_RECOVERY"
    case moderateYellowRecovery    = "MODERATE_YELLOW_RECOVERY"
    case normalTrainingGreenRecovery = "NORMAL_TRAINING_GREEN_RECOVERY"
    case sleepDebt                 = "SLEEP_DEBT"
    case earlierBedtime            = "EARLIER_BEDTIME"
    case effortTarget              = "EFFORT_TARGET"
}

// MARK: - AdviceSignal

/// One structured advice signal, serialisable for GRDB persistence.
///
/// `Codable` conformance is required so that `DailySnapshot` (plan 07-03) can
/// round-trip through `LocalDataStore.saveCache()`.
public struct AdviceSignal: Codable, Equatable {
    /// Raw string value of the `AdviceCode` enum (e.g. `"SLEEP_DEBT"`).
    public let code: String
    /// JSON-serialised parameters dictionary, produced by `JSONSerialization`.
    /// Example: `{"debt_min": 120.5, "window_nights": 5}`.
    public let paramsJSON: String
    /// Confidence tier: `"low"` | `"medium"` | `"high"`.
    public let confidence: String

    public init(code: String, paramsJSON: String, confidence: String) {
        self.code = code
        self.paramsJSON = paramsJSON
        self.confidence = confidence
    }
}

// MARK: - AdviceResult

/// Complete advice output for one day.
///
/// Contains one primary signal (the dominant recovery recommendation) and zero
/// or more secondary signals (sleep debt, earlier bedtime, effort target).
public struct AdviceResult {
    /// The dominant advice code for this day.
    public let primaryCode: AdviceCode
    /// Numeric parameters associated with the primary signal (e.g. `score`, `band`).
    public let primaryParams: [String: Double]
    /// Confidence tier of the primary signal: `"low"` | `"medium"` | `"high"`.
    public let primaryConfidence: String
    /// Secondary signals emitted alongside the primary.  May be empty.
    public let secondary: [AdviceSignal]

    public init(
        primaryCode: AdviceCode,
        primaryParams: [String: Double],
        primaryConfidence: String,
        secondary: [AdviceSignal]
    ) {
        self.primaryCode = primaryCode
        self.primaryParams = primaryParams
        self.primaryConfidence = primaryConfidence
        self.secondary = secondary
    }
}

// MARK: - bedtimeOffsetMinutes

/// Converts a Unix-seconds timestamp to a signed bedtime offset in minutes
/// relative to noon UTC, with wrap into `(-720, 720]`.
///
/// Mirrors `advice.py bedtime_offset_minutes()` exactly.  All arithmetic uses
/// UTC — no user time-zone calendar is applied.
///
/// - Parameter ts: Unix timestamp in seconds (Double).
/// - Returns: Offset in minutes, wrapped into `(-720, 720]`.
public func bedtimeOffsetMinutes(_ ts: Double) -> Double {
    let dt = Date(timeIntervalSince1970: ts)
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let comps = cal.dateComponents([.hour, .minute, .second], from: dt)
    let minutesSinceMidnight = Double((comps.hour ?? 0) * 60 + (comps.minute ?? 0))
                             + Double(comps.second ?? 0) / 60.0
    var offset = minutesSinceMidnight - 12.0 * 60.0
    if offset <= -720.0 { offset += 1440.0 }
    else if offset > 720.0 { offset -= 1440.0 }
    return offset
}
