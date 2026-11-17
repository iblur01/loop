import Foundation

// MARK: - RecoveryResult

/// Recovery score result for one night.
///
/// Mirrors the Python `RecoveryResult` frozen dataclass in `recovery.py`.
/// All fields are `let`-only — results are never mutated.
public struct RecoveryResult {
    /// Recovery score in [0, 100], or `nil` during cold-start when the HRV
    /// baseline is not yet usable (fewer than MIN_NIGHTS_SEED valid nights).
    public let score: Double?
    /// WHOOP-style color band — `"red"` < 34, `"yellow"` 34–67, `"green"` ≥ 67.
    /// `nil` when `score` is `nil` (cold-start).
    public let band: String?
    /// Confidence in the inputs: low when unavailable, medium with partial coverage
    /// or provisional references, high with trusted core references and sleep efficiency.
    public let confidence: String
    /// Signed deviations in the recovery-favorable direction for included components.
    public let zHrv: Double?
    public let zRhr: Double?
    public let zResp: Double?

    public init(score: Double?, band: String?, confidence: String,
                zHrv: Double?, zRhr: Double?, zResp: Double?) {
        self.score = score
        self.band = band
        self.confidence = confidence
        self.zHrv = zHrv
        self.zRhr = zRhr
        self.zResp = zResp
    }
}

// MARK: - Public API

/// Z-score + logistic-squash recovery score in [0, 100]. APPROXIMATE.
///
/// Requires in-range nightly RMSSD and resting HR and a usable RMSSD baseline.
/// Optional components are renormalized over their available weights.
public func recoveryScore(
    hrv: Double,
    rhr: Double,
    resp: Double?,
    sleepPerf: Double?,
    hrvBaseline: BaselineState,
    rhrBaseline: BaselineState,
    respBaseline: BaselineState?
) -> RecoveryResult {

    func standardized(_ value: Double, against state: BaselineState, cfg: MetricCfg) -> Double? {
        let range = cfg.minVal...cfg.maxVal
        guard state.usable, range.contains(state.baseline), range.contains(value) else { return nil }
        let deviation = (value - state.baseline) / state.standardDeviation
        return deviation.isFinite ? deviation : nil
    }

    guard (MetricCfg.restingHR.minVal...MetricCfg.restingHR.maxVal).contains(rhr),
          let zHrv = standardized(hrv, against: hrvBaseline, cfg: .hrv) else {
        return RecoveryResult(score: nil, band: nil, confidence: "low",
                              zHrv: nil, zRhr: nil, zResp: nil)
    }
    let zRhr = standardized(rhr, against: rhrBaseline, cfg: .restingHR).map { -$0 }
    let zResp = resp.flatMap { value in
        respBaseline.flatMap { standardized(value, against: $0, cfg: .resp) }.map { -$0 }
    }
    let zSleep = sleepPerf.flatMap { (0...1).contains($0) ? ($0 - sleepPerfCenter) / sleepPerfScale : nil }
    let terms: [(Double?, Double)] = [(zHrv, wHrv), (zRhr, wRhr), (zResp, wResp), (zSleep, wSleep)]
    var sum = 0.0
    var weight = 0.0
    for (term, coefficient) in terms {
        guard let term else { continue }
        sum += term * coefficient
        weight += coefficient
    }
    let score = logisticSquash(sum / weight, k: logisticK, z0: logisticZ0)
    // High confidence requires both core references and a sleep observation.
    let highConfidence = hrvBaseline.trusted && rhrBaseline.trusted && zRhr != nil
        && zSleep != nil && (zResp == nil || respBaseline?.trusted == true)
    return RecoveryResult(score: score, band: recoveryBand(score),
                          confidence: highConfidence ? "high" : "medium",
                          zHrv: zHrv, zRhr: zRhr, zResp: zResp)
}

// MARK: - Helpers

/// Existing model weights, redistributed across available components.
private let wHrv:   Double = 0.50
private let wRhr:   Double = 0.25
private let wResp:  Double = 0.10
private let wSleep: Double = 0.15

/// The model centers a night at its personal reference on 50 points.
/// k=1.2 gives gentler slope (less severe drops), z0=0.0 centers at 50% baseline.
private let logisticK:  Double = 1.2
private let logisticZ0: Double = 0.0

/// Sleep performance centering constants. Mirrors recovery.py SLEEP_PERF_CENTER / SLEEP_PERF_SCALE.
private let sleepPerfCenter: Double = 0.85
private let sleepPerfScale:  Double = 0.12

/// Recovery band thresholds. Mirrors recovery.py BAND_RED_MAX / BAND_YELLOW_MAX.
private let bandRedMax:    Double = 34.0
private let bandYellowMax: Double = 67.0

/// Logistic squash to [0, 100].
///
/// Formula: `100 / (1 + exp(-k * (z - z0)))`, clamped to [0, 100].
/// Mirrors `recovery.py` and `sleep_score.py` shared formula.
private func logisticSquash(_ z: Double, k: Double, z0: Double) -> Double {
    let raw = 100.0 / (1.0 + exp(-k * (z - z0)))
    return max(0.0, min(100.0, raw))
}

/// WHOOP-style color band for a recovery score.
///
/// Mirrors `recovery.py recovery_band()`.
private func recoveryBand(_ score: Double) -> String {
    if score < bandRedMax    { return "red"    }
    if score < bandYellowMax { return "yellow" }
    return "green"
}
