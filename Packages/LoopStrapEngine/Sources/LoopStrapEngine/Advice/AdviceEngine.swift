import Foundation

// MARK: - AdviceEngine

/// Stateless advice signal engine — port of `advice.py compute_advice()`.
///
/// `AdviceEngine` is a pure namespace (enum with no cases) following the same
/// pattern as `DailyEngine` and `SleepEngine` in this package.
///
/// The engine is IO-free and never throws.  When inputs are insufficient it
/// returns graceful defaults (e.g. cold-start primary code, nil secondary).
public enum AdviceEngine {

    // MARK: - Public API

    /// Compute structured advice signals for one day.
    ///
    /// Mirrors `advice.py compute_advice()` exactly, including secondary-signal
    /// assembly order (sleep_debt → earlier_bedtime → effort_target).
    ///
    /// - Parameters:
    ///   - recovery:              Tonight's recovery result (from `Recovery.swift`).
    ///   - sleepHistory:          Total sleep minutes for each of the last N nights,
    ///                            ordered oldest → newest.  Individual entries may be
    ///                            `nil` when the band had no valid sleep data for that night.
    ///   - durationBaseline:      Personal sleep-duration baseline (usable flag checked internally).
    ///   - bedtimeBaseline:       Personal bedtime-offset baseline.
    ///   - tonightBedtimeOffset:  Bedtime offset in minutes from noon UTC for today.
    ///                            Pass `nil` when no sleep session was detected tonight.
    ///   - strainBaseline:        Personal strain baseline (optional — used for effort target).
    ///   - recentStrainHistory:   Strain scores for the last N days (for overload detection).
    /// - Returns: `AdviceResult` with one primary and zero or more secondary signals.
    public static func compute(
        recovery: RecoveryResult,
        sleepHistory: [Double?],
        durationBaseline: BaselineState?,
        bedtimeBaseline: BaselineState?,
        tonightBedtimeOffset: Double?,
        strainBaseline: BaselineState?,
        recentStrainHistory: [Double?]
    ) -> AdviceResult {
        // 1. Primary signal — based solely on recovery band/confidence.
        let (primaryCode, primaryParams, primaryConf) = primaryAdvice(recovery)

        // 2. Compute sleep debt (shared between SLEEP_DEBT and EARLIER_BEDTIME).
        let debtMin = computeSleepDebt(sleepHistory, durationBaseline: durationBaseline)

        // 3. Assemble secondary signals in advice.py order.
        var secondary: [AdviceSignal] = []

        if let item = sleepDebtAdvice(debtMin: debtMin, durationBaseline: durationBaseline) {
            secondary.append(item)
        }
        if let item = earlierBedtimeAdvice(
            tonightBedtimeOffset: tonightBedtimeOffset,
            bedtimeBaseline: bedtimeBaseline,
            debtMin: debtMin
        ) {
            secondary.append(item)
        }
        // Effort target is always emitted (never nil).
        secondary.append(effortTargetAdvice(
            recovery: recovery,
            strainBaseline: strainBaseline,
            recentStrainHistory: recentStrainHistory
        ))

        return AdviceResult(
            primaryCode: primaryCode,
            primaryParams: primaryParams,
            primaryConfidence: primaryConf,
            secondary: secondary
        )
    }

    // MARK: - Private helpers

    /// Returns the primary advice code, params, and confidence from recovery state.
    ///
    /// Mirrors `advice.py _primary_advice()`.
    /// Cold-start (score == nil) → RECOVERY_CALIBRATING.
    /// Otherwise mapped from band.
    private static func primaryAdvice(
        _ recovery: RecoveryResult
    ) -> (AdviceCode, [String: Double], String) {
        guard let score = recovery.score, let band = recovery.band else {
            // Cold-start: HRV baseline not yet usable.
            let conf = recovery.confidence
            return (.recoveryCalibrating, [:], conf)
        }
        let conf = recovery.confidence
        let params: [String: Double] = ["score": score]
        switch band {
        case "red":
            return (.restRedRecovery, params, conf)
        case "yellow":
            return (.moderateYellowRecovery, params, conf)
        default:
            // "green" or any unexpected value → normal training.
            return (.normalTrainingGreenRecovery, params, conf)
        }
    }

    /// Cumulative sleep deficit (minutes) over the last `sleepDebtWindowNights` nights.
    ///
    /// Mirrors `advice.py _compute_sleep_debt()`.
    /// Returns `nil` when:
    ///   - the duration baseline is absent or not usable, or
    ///   - there are fewer than `sleepDebtWindowNights` non-nil entries in `sleepHistory`.
    private static func computeSleepDebt(
        _ sleepHistory: [Double?],
        durationBaseline: BaselineState?
    ) -> Double? {
        guard let baseline = durationBaseline, baseline.usable else { return nil }
        let window = AdviceThresholds.sleepDebtWindowNights
        let valid = sleepHistory.suffix(window).compactMap { $0 }
        guard valid.count >= window else { return nil }
        let expected = baseline.baseline * Double(window)
        let actual   = valid.reduce(0.0, +)
        return max(0.0, expected - actual)
    }

    /// Emit a SLEEP_DEBT secondary signal when cumulative deficit ≥ threshold.
    ///
    /// Mirrors `advice.py _sleep_debt_advice()`.
    private static func sleepDebtAdvice(
        debtMin: Double?,
        durationBaseline: BaselineState?
    ) -> AdviceSignal? {
        guard let debt = debtMin,
              debt >= AdviceThresholds.sleepDebtThresholdMin else { return nil }
        let params: [String: Any] = [
            "debt_min":       debt,
            "window_nights":  Double(AdviceThresholds.sleepDebtWindowNights)
        ]
        let json = serialiseParams(params)
        let conf = durationBaseline.map { $0.usable ? "high" : "medium" } ?? "low"
        return AdviceSignal(code: AdviceCode.sleepDebt.rawValue, paramsJSON: json, confidence: conf)
    }

    /// Emit an EARLIER_BEDTIME secondary signal when tonight's bedtime is later
    /// than personal baseline by more than `earlierBedtimeOffsetMin`.
    ///
    /// Mirrors `advice.py _earlier_bedtime_advice()`.
    /// Not emitted when no sleep debt is present (debt == nil or debt == 0).
    private static func earlierBedtimeAdvice(
        tonightBedtimeOffset: Double?,
        bedtimeBaseline: BaselineState?,
        debtMin: Double?
    ) -> AdviceSignal? {
        // Require both a valid tonight bedtime and a usable baseline.
        guard let tonightOffset = tonightBedtimeOffset,
              let baseline = bedtimeBaseline,
              baseline.usable else { return nil }
        // Only emit when there is meaningful sleep debt.
        guard let debt = debtMin, debt > 0 else { return nil }
        let drift = tonightOffset - baseline.baseline
        guard drift > AdviceThresholds.earlierBedtimeOffsetMin else { return nil }
        let params: [String: Any] = [
            "tonight_offset_min":  tonightOffset,
            "baseline_offset_min": baseline.baseline,
            "drift_min":           drift,
            "debt_min":            debt
        ]
        let json = serialiseParams(params)
        let conf = baseline.usable ? "high" : "medium"
        return AdviceSignal(code: AdviceCode.earlierBedtime.rawValue, paramsJSON: json, confidence: conf)
    }

    /// Compute a strain effort target for today.
    ///
    /// Always returns a signal (never nil) — mirrors `advice.py _effort_target_advice()`.
    ///
    /// Target logic:
    ///   - Red band      → cap at `effortTargetRedCeiling`
    ///   - Yellow band   → `baseline * effortTargetYellowFactor`
    ///   - Green band    → `baseline` (maintain)
    ///   - Cold-start    → `nil` target (signal still emitted, target absent)
    private static func effortTargetAdvice(
        recovery: RecoveryResult,
        strainBaseline: BaselineState?,
        recentStrainHistory: [Double?]
    ) -> AdviceSignal {
        let baseline = strainBaseline?.usable == true ? strainBaseline!.baseline : nil

        var targetStrain: Double? = nil
        if let base = baseline, let band = recovery.band {
            switch band {
            case "red":
                targetStrain = min(AdviceThresholds.effortTargetRedCeiling, base)
            case "yellow":
                targetStrain = base * AdviceThresholds.effortTargetYellowFactor
            default:
                targetStrain = base
            }
        }

        // Recent overload: any of the last `effortTargetTrendWindowDays` strain values
        // exceeds the baseline (when baseline is available).
        let recentOverload: Bool? = {
            guard let base = baseline else { return nil }
            let window = AdviceThresholds.effortTargetTrendWindowDays
            let recent = recentStrainHistory.suffix(window).compactMap { $0 }
            guard !recent.isEmpty else { return nil }
            return recent.contains { $0 > base }
        }()

        var params: [String: Any] = [:]
        if let recentOverload { params["recent_overload"] = recentOverload }
        if let t = targetStrain {
            params["target_strain"] = t
        }
        if let base = baseline {
            params["strain_baseline"] = base
        }
        let json = serialiseParams(params)
        let conf = strainBaseline.map { $0.trusted ? "high" : ($0.usable ? "medium" : "low") } ?? "low"
        return AdviceSignal(code: AdviceCode.effortTarget.rawValue, paramsJSON: json, confidence: conf)
    }

    // MARK: - JSON serialisation

    /// Serialise a `[String: Any]` params dict to a compact JSON string.
    ///
    /// Uses `JSONSerialization` with typed arguments — no string interpolation.
    /// Conforms to threat mitigation T-07-01 (no user input, typed values only).
    private static func serialiseParams(_ params: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: params,
            options: [.sortedKeys]
        ) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

