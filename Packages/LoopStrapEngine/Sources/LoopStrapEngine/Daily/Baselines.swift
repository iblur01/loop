import Foundation

// MARK: - BaselineStatus

/// Confidence level of a personal baseline estimate.
///
/// Mirrors `baselines.py` status strings exactly — used as raw values in fixture JSON.
public enum BaselineStatus: String, Codable {
    case calibrating = "calibrating"
    case provisional = "provisional"
    case trusted     = "trusted"
    case stale       = "stale"
}

// MARK: - BaselineState

/// Immutable snapshot of a personal rolling baseline for one nightly metric.
///
/// Mirrors the Python `BaselineState` frozen dataclass in `baselines.py`.
/// All fields are `let`-only — state is never mutated in place.
public struct BaselineState: Equatable {
    public enum Dispersion: Equatable {
        case meanAbsoluteDeviation
        case gaussianSigma
    }
    public let dispersion: Dispersion
    public var standardDeviation: Double {
        dispersion == .gaussianSigma ? spread : 1.253 * spread
    }
    /// Robust EWMA center (the personal "mean" for this metric).
    public let baseline: Double
    /// Dispersion in the units declared by `dispersion`.
    public let spread: Double
    /// Count of valid nights that have contributed to the state.
    public let nValid: Int
    /// Number of consecutive nights with no valid value (for staleness detection).
    public let nightsSinceUpdate: Int
    /// Confidence level of this baseline.
    public let status: BaselineStatus

    /// True iff the baseline is fully trusted (status == .trusted).
    public var trusted: Bool { status == .trusted }

    /// True iff the baseline is at least provisionally usable (provisional or trusted).
    public var usable: Bool {
        (status == .provisional || status == .trusted) && baseline.isFinite
            && standardDeviation.isFinite && standardDeviation > 0
    }

    public init(baseline: Double, spread: Double, nValid: Int,
                nightsSinceUpdate: Int, status: BaselineStatus,
                dispersion: Dispersion = .meanAbsoluteDeviation) {
        self.dispersion = dispersion
        self.baseline = baseline
        self.spread = spread
        self.nValid = nValid
        self.nightsSinceUpdate = nightsSinceUpdate
        self.status = status
    }
}

// MARK: - MetricCfg

/// Per-metric configuration for the rolling EWMA baseline model.
///
/// Mirrors the Python `MetricCfg` NamedTuple in `baselines.py`.
public struct MetricCfg {
    /// Physiological lower bound — values below are treated as missing.
    public let minVal: Double
    /// Physiological upper bound — values above are treated as missing.
    public let maxVal: Double
    /// Minimum dispersion (σ_floor); prevents over-sensitivity on very stable metrics.
    public let floorSpread: Double
    /// Baseline center half-life in nights (→ λ_b). Default 14 nights ≈ α 0.0483.
    public let halfLifeB: Double
    /// Spread half-life in nights (→ λ_s). Slower than center; default 21 nights.
    public let halfLifeS: Double

    public init(minVal: Double, maxVal: Double, floorSpread: Double,
                halfLifeB: Double, halfLifeS: Double) {
        self.minVal = minVal
        self.maxVal = maxVal
        self.floorSpread = floorSpread
        self.halfLifeB = halfLifeB
        self.halfLifeS = halfLifeS
    }
}

/// Default per-metric configurations, ported exactly from `METRIC_CFG` dict in `baselines.py`.
public extension MetricCfg {
    /// HRV (RMSSD) baseline. Floor spread 5 ms (conservative of doc 03 / doc 06).
    static let hrv = MetricCfg(minVal: 5.0, maxVal: 250.0, floorSpread: 5.0,
                                halfLifeB: 14.0, halfLifeS: 21.0)
    /// Resting heart rate baseline. Floor spread 2 bpm.
    static let restingHR = MetricCfg(minVal: 30.0, maxVal: 120.0, floorSpread: 2.0,
                                      halfLifeB: 14.0, halfLifeS: 21.0)
    /// Respiratory rate baseline. Floor spread 0.5 brpm.
    static let resp = MetricCfg(minVal: 4.0, maxVal: 40.0, floorSpread: 0.5,
                                 halfLifeB: 14.0, halfLifeS: 21.0)
    /// Sleep duration baseline (minutes). Floor spread 20 min.
    static let sleepDuration = MetricCfg(minVal: 120.0, maxVal: 720.0, floorSpread: 20.0,
                                          halfLifeB: 14.0, halfLifeS: 21.0)
    /// Deep-sleep percentage of TST. Floor spread 4%.
    static let deepPct = MetricCfg(minVal: 0.0, maxVal: 100.0, floorSpread: 4.0,
                                    halfLifeB: 14.0, halfLifeS: 21.0)
    /// REM-sleep percentage of TST. Floor spread 4%.
    static let remPct = MetricCfg(minVal: 0.0, maxVal: 100.0, floorSpread: 4.0,
                                   halfLifeB: 14.0, halfLifeS: 21.0)
    /// Light-sleep percentage of TST. Floor spread 4%.
    static let lightPct = MetricCfg(minVal: 0.0, maxVal: 100.0, floorSpread: 4.0,
                                     halfLifeB: 14.0, halfLifeS: 21.0)
    /// Daily strain on the 0–21 log-mapped scale. Floor spread 1.5.
    static let strain = MetricCfg(minVal: 0.0, maxVal: 21.0, floorSpread: 1.5,
                                   halfLifeB: 14.0, halfLifeS: 21.0)
}

// MARK: - Public API

/// Incorporate one new nightly value into the baseline state.
///
/// Implements the Winsorized EWMA from `baselines.py update_baseline()` exactly,
/// including all 6 branch conditions in the same order as the Python oracle.
///
/// Branch order:
///  1. `state == nil` — first night ever (seed state)
///  2. `value == nil` — missing night (skip-and-hold)
///  3. value outside `[minVal, maxVal]` — physiologically implausible (skip-and-hold)
///  4. hard outlier (`nValid >= 4` AND `|dev| > 5 * spread`) — reset `nightsSinceUpdate`, no EWMA
///  5. `nValid == 0` with first real value — seed propre without Winsorization
///  6. normal update — Winsorize ±3·spread, EWMA baseline + spread
///
/// - Parameters:
///   - state: Previous `BaselineState`, or `nil` for the very first night.
///   - value: Tonight's nightly value, or `nil` for a missing night.
///   - cfg: Metric configuration (bounds, floor spread, half-lives).
/// - Returns: Updated (or carried-forward) state.
public func updateBaseline(state: BaselineState?, value: Double?, cfg: MetricCfg) -> BaselineState {
    let λb = ewmaLambda(halfLife: cfg.halfLifeB)
    let λs = ewmaLambda(halfLife: cfg.halfLifeS)

    // ── Branch 1: First night ever — seed state ──────────────────────────────
    if state == nil {
        if value == nil || !(cfg.minVal <= value! && value! <= cfg.maxVal) {
            // No valid first value — placeholder seeded at physiological midpoint.
            let seed = (cfg.minVal + cfg.maxVal) / 2.0
            return BaselineState(
                baseline: seed,
                spread: cfg.floorSpread,
                nValid: 0,
                nightsSinceUpdate: 1,
                status: .calibrating
            )
        }
        return BaselineState(
            baseline: value!,
            spread: cfg.floorSpread,
            nValid: 1,
            nightsSinceUpdate: 0,
            status: .calibrating
        )
    }

    let prior = state!
    // The streaming update uses mean absolute deviations even when seeded from a MAD fold.
    let s = prior.dispersion == .meanAbsoluteDeviation ? prior : BaselineState(
        baseline: prior.baseline, spread: prior.standardDeviation / 1.253,
        nValid: prior.nValid, nightsSinceUpdate: prior.nightsSinceUpdate, status: prior.status
    )

    // ── Branch 2: Missing night — skip-and-hold ──────────────────────────────
    if value == nil {
        let newMissing = s.nightsSinceUpdate + 1
        return BaselineState(
            baseline: s.baseline,
            spread: s.spread,
            nValid: s.nValid,
            nightsSinceUpdate: newMissing,
            status: _computeStatus(nValid: s.nValid, nightsSinceUpdate: newMissing)
        )
    }

    let v = value!

    // ── Branch 3: Physiologically implausible — skip-and-hold ────────────────
    if !(cfg.minVal <= v && v <= cfg.maxVal) {
        let newMissing = s.nightsSinceUpdate + 1
        return BaselineState(
            baseline: s.baseline,
            spread: s.spread,
            nValid: s.nValid,
            nightsSinceUpdate: newMissing,
            status: _computeStatus(nValid: s.nValid, nightsSinceUpdate: newMissing)
        )
    }

    // ── Branch 4: Hard outlier rejection ─────────────────────────────────────
    // Only gate when we have enough nights to trust the baseline.
    if s.nValid >= minNightsSeed {
        let dev = abs(v - s.baseline)
        if dev > hardOutlierK * s.spread {
            // Seen a night, just a suspicious one — reset nightsSinceUpdate to 0.
            return BaselineState(
                baseline: s.baseline,
                spread: s.spread,
                nValid: s.nValid,
                nightsSinceUpdate: 0,
                status: _computeStatus(nValid: s.nValid, nightsSinceUpdate: 0)
            )
        }
    }

    // ── Branch 5: First real value with placeholder state (nValid == 0) ──────
    // Do NOT Winsorize toward the physiological midpoint placeholder.
    if s.nValid == 0 {
        return BaselineState(
            baseline: v,
            spread: cfg.floorSpread,
            nValid: 1,
            nightsSinceUpdate: 0,
            status: .calibrating
        )
    }

    // ── Branch 6: Normal Winsorized EWMA update ───────────────────────────────
    let lo = s.baseline - winsorK * s.spread
    let hi = s.baseline + winsorK * s.spread
    let clamped = max(lo, min(hi, v))

    let newBaseline = λb * clamped + (1.0 - λb) * s.baseline

    // Use UNCLAMPED value for spread update (track true deviations).
    let absDeviation = abs(v - newBaseline)
    let newSpread = max(cfg.floorSpread, λs * absDeviation + (1.0 - λs) * s.spread)

    let newNValid = s.nValid + 1

    return BaselineState(
        baseline: newBaseline,
        spread: newSpread,
        nValid: newNValid,
        nightsSinceUpdate: 0,
        status: _computeStatus(nValid: newNValid, nightsSinceUpdate: 0)
    )
}

/// Replay an ordered sequence of nightly values (oldest first) to build a baseline state.
///
/// Uses a robust median-based approach: the baseline center is the median of valid
/// values, and the spread is the MAD (Median Absolute Deviation) scaled to approximate
/// Gaussian σ. This is more robust to outliers than EWMA.
///
/// Equivalent to `baselines.py fold_history()` but with improved robustness.
///
/// - Parameters:
///   - nights: Ordered list of nightly values (oldest → newest). `nil` = missing night.
///   - cfg: Metric configuration.
/// - Returns: Final baseline state after all nights have been processed.
public func foldHistory(_ nights: [Double?], cfg: MetricCfg) -> BaselineState {
    // Filter valid values within physiological bounds
    let validValues = nights.compactMap { v -> Double? in
        guard let val = v, val >= cfg.minVal, val <= cfg.maxVal else { return nil }
        return val
    }

    // Count consecutive missing nights at the end (for staleness)
    var trailingMissing = 0
    for v in nights.reversed() {
        if let v, (cfg.minVal...cfg.maxVal).contains(v) { break }
        trailingMissing += 1
    }

    // Need at least minNightsSeed valid values for a usable baseline
    guard validValues.count >= minNightsSeed else {
        // Not enough data — return calibrating state
        let seed: Double
        if let firstValid = validValues.first {
            seed = firstValid
        } else {
            seed = (cfg.minVal + cfg.maxVal) / 2.0
        }
        return BaselineState(
            baseline: seed,
            spread: cfg.floorSpread,
            nValid: validValues.count,
            nightsSinceUpdate: trailingMissing,
            status: .calibrating
        )
    }

    // Compute robust median-based baseline
    let sorted = validValues.sorted()
    let medianValue = median(sorted: sorted)

    // Compute MAD (Median Absolute Deviation) for robust spread
    let absDeviations = validValues.map { abs($0 - medianValue) }.sorted()
    let mad = median(sorted: absDeviations)

    // Scale MAD to approximate Gaussian σ (MAD × 1.4826 ≈ σ for normal distribution)
    let robustSpread = max(cfg.floorSpread, mad * 1.4826)

    // Determine status based on valid count and staleness
    let status: BaselineStatus
    if trailingMissing > staleDays {
        status = .stale
    } else if validValues.count >= minNightsTrust {
        status = .trusted
    } else {
        status = .provisional
    }

    return BaselineState(
        baseline: medianValue,
        spread: robustSpread,
        nValid: validValues.count,
        nightsSinceUpdate: trailingMissing,
        status: status, dispersion: .gaussianSigma
    )
}

/// Compute the median of a sorted array.
private func median(sorted: [Double]) -> Double {
    let n = sorted.count
    guard n > 0 else { return 0.0 }
    if n % 2 == 0 {
        return (sorted[n/2 - 1] + sorted[n/2]) / 2.0
    } else {
        return sorted[n/2]
    }
}

// MARK: - Helpers

/// Winsorization clamp: fold only within ±WINSOR_K * spread from current baseline.
private let winsorK: Double = 3.0

/// Hard-reject gate: drop night from state update if > HARD_OUTLIER_K * spread away.
private let hardOutlierK: Double = 5.0

/// Minimum valid nights before the baseline is "provisionally" trusted.
private let minNightsSeed: Int = 4

/// Minimum valid nights before the baseline is fully trusted.
private let minNightsTrust: Int = 14

/// Number of missing nights after which the baseline is marked stale.
private let staleDays: Int = 14

/// Convert a half-life in nights to an EWMA smoothing factor.
///
/// Formula: `λ = 1 - 0.5^(1/halfLife)`.
/// For halfLife=14: λ ≈ 0.04826 (center). For halfLife=21: λ ≈ 0.03245 (spread).
private func ewmaLambda(halfLife: Double) -> Double {
    1.0 - pow(0.5, 1.0 / halfLife)
}

/// Compute the baseline confidence status from `nValid` and `nightsSinceUpdate`.
///
/// Priority order mirrors `baselines.py _compute_status()` exactly:
///  1. stale (overrides provisional/trusted when nightsSinceUpdate > STALE_DAYS)
///  2. calibrating (nValid < MIN_NIGHTS_SEED)
///  3. provisional (nValid < MIN_NIGHTS_TRUST)
///  4. trusted
private func _computeStatus(nValid: Int, nightsSinceUpdate: Int) -> BaselineStatus {
    if nightsSinceUpdate > staleDays && nValid >= minNightsSeed {
        return .stale
    }
    if nValid < minNightsSeed {
        return .calibrating
    }
    if nValid < minNightsTrust {
        return .provisional
    }
    return .trusted
}
