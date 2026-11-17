import Foundation

// MARK: - SleepScoreResult

/// Sleep score result with all four sub-score components.
///
/// Mirrors `SleepScoreResult` from `sleep_score.py`. Sub-scores are always
/// present; the composite `score` is nil only when no weighted terms are present
/// (cold-start with all baselines missing), which cannot occur in normal usage.
public struct SleepScoreResult {
    /// Composite score 0..100, weighted average of the four sub-scores.
    public let score: Double
    /// Duration sub-score 0..100 (logistic squash of z-score vs personal baseline).
    public let durationScore: Double
    /// Efficiency sub-score 0..100 (logistic squash vs EFFICIENCY_CENTER=0.85).
    public let efficiencyScore: Double
    /// Stage balance sub-score 0..100 (logistic squash of mean |z| across deep/REM/light).
    /// Equal to 50.0 when no usable stage baselines are provided.
    public let stageBalanceScore: Double
    /// Disturbance sub-score 0..100 (penalty on disturbance count and WASO).
    public let disturbanceScore: Double
}

// MARK: - Public API

/// Daily personalized score. A complete classified night and a usable duration
/// reference are required. Missing WASO carries no reward or penalty.
public func personalizedSleepScore(
    summary: DailySleepSummary,
    durationBaseline: BaselineState?,
    stageBaselines: [String: BaselineState]?
) -> SleepScoreResult? {
    guard let durationBaseline, durationBaseline.usable,
          (MetricCfg.sleepDuration.minVal...MetricCfg.sleepDuration.maxVal).contains(durationBaseline.baseline),
          summary.totalSleepMin.isFinite, summary.totalSleepMin > 0,
          summary.efficiency > 0, summary.efficiency <= 1, summary.disturbances >= 0,
          [summary.deepMin, summary.remMin, summary.lightMin].allSatisfy({ $0.isFinite && $0 >= 0 }),
          abs(summary.deepMin + summary.remMin + summary.lightMin - summary.totalSleepMin) <= 1 / 60.0
    else { return nil }

    let countPenalty = (Double(summary.disturbances) - disturbanceTargetCount) / disturbanceScaleCount
    return compositeSleepScore(summary: summary, durationBaseline: durationBaseline,
                               stageBaselines: stageBaselines, disturbanceSub: logisticSquash(-countPenalty))
}

/// Compute the sleep score and all sub-score components.
///
/// Ports `sleep_score()` from `sleep_score.py` (250 lines).
///
/// The composite score is a weighted sum of four sub-scores:
///   - duration      (W = 0.40): z-score vs personal duration baseline
///   - efficiency    (W = 0.25): logistic squash around EFFICIENCY_CENTER = 0.85
///   - stage balance (W = 0.20): mean |z| across deep/REM/light vs personal baselines
///   - disturbance   (W = 0.15): penalty on disturbance count
///
/// When no usable stage baselines are provided, the stage balance term is excluded
/// from the weighted composite (its weight is redistributed to the remaining terms),
/// mirroring the Python oracle's behaviour when `stage_balance_sub` is None.
/// The `stageBalanceScore` field of the result reports 50.0 in that case.
///
/// Stage percentages are derived from `summary.deepMin`, `remMin`, `lightMin`
/// and `totalSleepMin`. WASO is not available in `DailySleepSummary`, so the
/// disturbance penalty is computed from the disturbance count only (WASO term = 0).
///
/// - Parameters:
///   - summary: Aggregated AASM metrics from `dailySleepSummary()`.
///   - durationBaseline: Personal rolling baseline for sleep duration (minutes);
///     nil or non-usable falls back to DURATION_FALLBACK_MIN = 480.0.
///   - stageBaselines: Per-stage personal baselines keyed by "deep_pct",
///     "rem_pct", "light_pct"; nil or missing keys → term excluded from composite.
/// - Returns: `SleepScoreResult` with all four sub-scores and the composite.
public func sleepScore(
    summary: DailySleepSummary,
    durationBaseline: BaselineState?,
    stageBaselines: [String: BaselineState]?
) -> SleepScoreResult {

    compositeSleepScore(summary: summary, durationBaseline: durationBaseline,
                        stageBaselines: stageBaselines, disturbanceSub: _disturbanceSubScore(summary: summary))
}

private func compositeSleepScore(
    summary: DailySleepSummary,
    durationBaseline: BaselineState?,
    stageBaselines: [String: BaselineState]?,
    disturbanceSub: Double
) -> SleepScoreResult {
    // ── Duration sub-score ────────────────────────────────────────────────────
    let durationSub = _durationSubScore(summary: summary, durationBaseline: durationBaseline)

    // ── Efficiency sub-score ──────────────────────────────────────────────────
    let efficiencySub = _efficiencySubScore(summary: summary)

    // ── Stage balance sub-score (nil when no usable stage baselines) ──────────
    let stageBalanceSubOpt = _stageBalanceSubScoreOpt(summary: summary, stageBaselines: stageBaselines)

    // ── Weighted composite (mirrors Python: exclude nil terms, renormalise) ───
    var weightedSum = durationSub * wDuration
                    + efficiencySub * wEfficiency
                    + disturbanceSub * wDisturbance
    var totalWeight = wDuration + wEfficiency + wDisturbance
    if let sb = stageBalanceSubOpt {
        weightedSum += sb * wStageBalance
        totalWeight += wStageBalance
    }
    let composite = totalWeight > 0 ? max(0.0, min(100.0, weightedSum / totalWeight)) : 0.0

    return SleepScoreResult(
        score: composite,
        durationScore: durationSub,
        efficiencyScore: efficiencySub,
        stageBalanceScore: stageBalanceSubOpt ?? 50.0,
        disturbanceScore: disturbanceSub
    )
}

// MARK: - Helpers

// ===========================================================================
// Formula constants — matching sleep_score.py exactly
// ===========================================================================

private let wDuration:     Double = 0.40
private let wEfficiency:   Double = 0.25
private let wStageBalance: Double = 0.20
private let wDisturbance:  Double = 0.15

private let durationFallbackMin: Double = 480.0

private let logisticK:  Double = 1.6
private let logisticZ0: Double = -0.20

private let stageBalanceLogisticK:  Double = 1.6
private let stageBalanceLogisticZ0: Double = -1.0

private let efficiencyCenter: Double = 0.85
private let efficiencyScale:  Double = 0.10

private let wasoTargetMin:         Double = 20.0
private let wasoScaleMin:          Double = 20.0
private let disturbanceTargetCount: Double = 2.0
private let disturbanceScaleCount:  Double = 2.0

// ===========================================================================
// Sub-score helpers
// ===========================================================================

private func _durationSubScore(
    summary: DailySleepSummary,
    durationBaseline: BaselineState?
) -> Double {
    let actual = max(0.0, summary.totalSleepMin)
    let target: Double
    let spread: Double
    if let state = durationBaseline, state.usable {
        target = state.baseline
        spread = state.standardDeviation
    } else {
        target = durationFallbackMin
        spread = 1.253 * MetricCfg.sleepDuration.floorSpread
    }
    let z = (actual - target) / spread
    return logisticSquash(z, k: logisticK, z0: logisticZ0)
}

private func _efficiencySubScore(summary: DailySleepSummary) -> Double {
    let actual = max(0.0, min(1.0, summary.efficiency))
    let z = (actual - efficiencyCenter) / efficiencyScale
    return logisticSquash(z, k: logisticK, z0: logisticZ0)
}

/// Returns the stage balance sub-score, or nil when no usable stage baselines are present.
///
/// Mirrors `_stage_balance_sub_score()` returning None in the Python oracle.
private func _stageBalanceSubScoreOpt(
    summary: DailySleepSummary,
    stageBaselines: [String: BaselineState]?
) -> Double? {
    let baselines = stageBaselines ?? [:]
    let totalMin = summary.totalSleepMin

    // Compute stage percentages from absolute minutes.
    // Matches sleep_score.py: caller derives percentages from daily_metrics at fold-time.
    var deepPct  = 0.0
    var remPct   = 0.0
    var lightPct = 0.0
    if totalMin > 0 {
        deepPct  = max(0.0, min(100.0, summary.deepMin  / totalMin * 100.0))
        remPct   = max(0.0, min(100.0, summary.remMin   / totalMin * 100.0))
        lightPct = max(0.0, min(100.0, summary.lightMin / totalMin * 100.0))
    }

    let stagePcts: [(key: String, pct: Double)] = [
        ("deep_pct",  deepPct),
        ("rem_pct",   remPct),
        ("light_pct", lightPct),
    ]

    var terms: [Double] = []
    for (key, actual) in stagePcts {
        guard let state = baselines[key], state.usable else { continue }
        let sigma = state.standardDeviation
        let z = (actual - state.baseline) / sigma
        terms.append(abs(z))
    }

    guard !terms.isEmpty else {
        // No usable stage baselines → return nil (weight excluded from composite)
        return nil
    }

    let meanAbsZ = terms.reduce(0.0, +) / Double(terms.count)
    return logisticSquash(-meanAbsZ, k: stageBalanceLogisticK, z0: stageBalanceLogisticZ0)
}

private func _disturbanceSubScore(summary: DailySleepSummary) -> Double {
    // WASO is not available in DailySleepSummary — use 0.0 (waso term = 0).
    // disturbance count from DailySleepSummary.disturbances.
    let wasoMin = 0.0
    let disturbanceCount = max(0.0, Double(summary.disturbances))
    let wasoPenalty        = (wasoMin - wasoTargetMin) / wasoScaleMin
    let disturbancePenalty = (disturbanceCount - disturbanceTargetCount) / disturbanceScaleCount
    let penalty = (wasoPenalty + disturbancePenalty) / 2.0
    return logisticSquash(-penalty, k: logisticK, z0: logisticZ0)
}

// ===========================================================================
// Math primitives (private copies — pattern established by Recovery.swift etc.)
// ===========================================================================

/// Logistic squash to [0, 100].
///
/// Mirrors `_squash()` from `sleep_score.py`.
private func logisticSquash(_ z: Double, k: Double = 1.6, z0: Double = -0.20) -> Double {
    let raw = 100.0 / (1.0 + exp(-k * (z - z0)))
    return max(0.0, min(100.0, raw))
}
