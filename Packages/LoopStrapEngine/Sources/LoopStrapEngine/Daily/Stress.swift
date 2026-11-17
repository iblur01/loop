import Foundation

// MARK: - StressResult

/// Summary of a physiological stress timeline computed over a session.
///
/// Mirrors `stress.py stress_timeline()` summary dict: `avg_score`, `fraction_high`,
/// and the per-bucket `timeline` on a 0–3 scale.
public struct StressResult {
    /// Mean stress score across all buckets (0–3 scale).
    public let meanStress: Double
    /// Fraction of buckets with score ≥ 2.0 (0.0–1.0).
    public let fractionHigh: Double
    /// Per-bucket stress scores in chronological order.
    public let timeline: [Double]

    public init(meanStress: Double, fractionHigh: Double, timeline: [Double]) {
        self.meanStress = meanStress
        self.fractionHigh = fractionHigh
        self.timeline = timeline
    }
}

// MARK: - StressError

/// Errors thrown by the Stress module when inputs are insufficient.
public enum StressError: Error {
    /// HR series is empty — cannot compute any stress score.
    case emptyHRSeries
}

// MARK: - Constants

private let bucketSeconds: Double = 60.0
private let minBucketHR: Int = 1
private let minBucketRR: Int = 8

private let defaultRestingHR: Double = 60.0
private let defaultHRVBaselineMs: Double = 50.0

// Note: rrMinMs / rrMaxMs are already declared public in HRV/Intervals.swift
// (same SPM module — accessible directly, no re-declaration needed).

private let hrActivationOffsetBpm: Double = 5.0
private let hrActivationRangeBpm: Double = 45.0
private let hrvSuppressionRangeFrac: Double = 0.60

private let activityThreshold: Double = 0.20
private let activityStressBonus: Double = 0.15

private let hrWeight: Double = 0.65
private let hrvWeight: Double = 0.35

// MARK: - Public API

/// Compute a WHOOP-like physiological stress timeline on a 0–3 scale.
///
/// Bucketises HR/RR/gravity into 60-second windows. For each bucket:
/// - Computes an HR activation component (0–1) based on HR vs resting HR.
/// - Computes an HRV suppression component (0–1) via per-bucket RMSSD vs baseline.
/// - Blends both (65 %/35 %) then applies an activity bonus when movement intensity
///   exceeds the activity threshold.
///
/// Mirrors `stress.py stress_timeline()`. Resting HR and HRV baseline are derived
/// from the session data when not provided. `rmssdMs()` from `TimeDomain.swift` is
/// reused for per-bucket RMSSD — not re-implemented here.
///
/// - Parameters:
///   - hrSeries: Time-ordered HR samples as `(ts: Unix epoch seconds, bpm: Double)`.
///   - rrSeries: RR interval samples `(ts, rrMs)`. May be empty.
///   - gravitySeries: Gravity/accelerometer samples `(ts, v)` for movement context. May be empty.
///   - restingHR: Pre-computed resting HR override (bpm). When `nil`, derived from 10th-percentile of HR series.
///   - hrvBaselineMs: Pre-computed personal HRV baseline (ms). When `nil`, derived from full-session RMSSD.
/// - Returns: `StressResult` with meanStress (0–3), fractionHigh, and per-bucket timeline.
/// - Throws: `StressError.emptyHRSeries` when `hrSeries` is empty.
public func stressTimeline(
    hrSeries: [(ts: Double, bpm: Double)],
    rrSeries: [(ts: Double, rrMs: Double)] = [],
    gravitySeries: [(ts: Double, v: Double)] = [],
    restingHR: Double? = nil,
    hrvBaselineMs: Double? = nil
) throws -> StressResult {
    guard !hrSeries.isEmpty else {
        throw StressError.emptyHRSeries
    }

    let resting = restingHR ?? deriveRestingHR(hrSeries: hrSeries)
    let hrvBase: Double
    if let provided = hrvBaselineMs, provided > 0 {
        hrvBase = provided
    } else {
        hrvBase = deriveHRVBaseline(rrSeries: rrSeries)
    }

    // Build per-bucket collections keyed by bucket-start epoch second
    let hrBuckets  = bucketValues(series: hrSeries.map { ($0.ts, $0.bpm) })
    let rrBuckets  = rmssdByBucket(rrSeries: rrSeries)
    let movement   = movementBuckets(gravitySeries: gravitySeries)

    let bucketTimestamps = Array(hrBuckets.keys).sorted()
    var scores: [Double] = []

    for ts in bucketTimestamps {
        guard let bpms = hrBuckets[ts], bpms.count >= minBucketHR else { continue }
        let hrBpm = bpms.reduce(0.0, +) / Double(bpms.count)  // fmean equivalent
        let rmssdVal = rrBuckets[ts] ?? nil
        let movementIntensity = movement[ts] ?? 0.0
        let active = movementIntensity >= activityThreshold

        let hrComponent = clamp(
            (hrBpm - resting - hrActivationOffsetBpm) / hrActivationRangeBpm,
            lo: 0.0, hi: 1.0
        )

        let hrvComponent: Double
        if let rmssd = rmssdVal, hrvBase > 0 {
            hrvComponent = clamp(
                (hrvBase - rmssd) / (hrvBase * hrvSuppressionRangeFrac),
                lo: 0.0, hi: 1.0
            )
        } else {
            hrvComponent = 0.0
        }

        var raw = hrWeight * hrComponent + hrvWeight * hrvComponent
        if active {
            raw = min(1.0, raw + activityStressBonus)
        }
        // Python rounds to 2 dp: round(3.0 * raw, 2)
        let score = (3.0 * raw * 100.0).rounded() / 100.0
        scores.append(score)
    }

    guard !scores.isEmpty else {
        return StressResult(meanStress: 0.0, fractionHigh: 0.0, timeline: [])
    }

    let meanScore = scores.reduce(0.0, +) / Double(scores.count)
    let meanRounded = (meanScore * 100.0).rounded() / 100.0
    let highCount = scores.filter { $0 >= 2.0 }.count
    let fractionHigh = Double(highCount) / Double(scores.count)

    return StressResult(meanStress: meanRounded, fractionHigh: fractionHigh, timeline: scores)
}

// MARK: - Helpers

/// Derive resting HR as the 10th-percentile of sorted bpm values.
///
/// Mirrors `stress.py _derive_resting_hr()`: sort ascending, take
/// `bpms[ceil(0.10 * n) - 1]` (rank-1 index).
private func deriveRestingHR(hrSeries: [(ts: Double, bpm: Double)]) -> Double {
    let bpms = hrSeries.compactMap { $0.bpm }.filter { $0.isFinite }.sorted()
    guard !bpms.isEmpty else { return defaultRestingHR }
    let rank = max(1, Int(ceil(0.10 * Double(bpms.count))))
    return bpms[rank - 1]
}

/// Derive HRV baseline from full-session RR intervals.
///
/// Mirrors `stress.py _derive_hrv_baseline()`: filter to physiological range,
/// require at least `minBucketRR` intervals, return `rmssdMs()`.
private func deriveHRVBaseline(rrSeries: [(ts: Double, rrMs: Double)]) -> Double {
    let clean = rrSeries
        .map { $0.rrMs }
        .filter { $0 >= rrMinMs && $0 <= rrMaxMs }
    guard clean.count >= minBucketRR else { return defaultHRVBaselineMs }
    let value = rmssdMs(clean)
    guard value.isFinite && value > 0 else { return defaultHRVBaselineMs }
    return value
}

/// Group time-series values into 60-second buckets.
///
/// Mirrors `stress.py _bucket_values()`. Key = floor(ts / 60) × 60.
private func bucketValues(series: [(Double, Double)]) -> [Double: [Double]] {
    var buckets: [Double: [Double]] = [:]
    for (ts, value) in series {
        guard value.isFinite else { continue }
        let key = floor(ts / bucketSeconds) * bucketSeconds
        buckets[key, default: []].append(value)
    }
    return buckets
}

/// Per-bucket RMSSD from RR intervals.
///
/// Mirrors `stress.py _rmssd_by_bucket()`. Buckets with < `minBucketRR` clean
/// intervals map to `nil`.
private func rmssdByBucket(rrSeries: [(ts: Double, rrMs: Double)]) -> [Double: Double?] {
    var rawBuckets: [Double: [Double]] = [:]
    for (ts, rrMs) in rrSeries {
        guard rrMs.isFinite else { continue }
        let key = floor(ts / bucketSeconds) * bucketSeconds
        rawBuckets[key, default: []].append(rrMs)
    }
    var out: [Double: Double?] = [:]
    for (ts, vals) in rawBuckets {
        let clean = vals.filter { $0 >= rrMinMs && $0 <= rrMaxMs }
        guard clean.count >= minBucketRR else {
            out[ts] = nil
            continue
        }
        let value = rmssdMs(clean)
        out[ts] = value.isFinite ? value : nil
    }
    return out
}

/// Per-bucket mean movement intensity from gravity samples.
///
/// Computes the inter-sample L2 change magnitude (actigraphy proxy), then
/// groups by 60-second bucket and averages finite values.
///
/// Inlines `activity.py activity_series()` + `stress.py _movement_buckets()`.
/// Timestamps are assumed to already be Unix epoch seconds (Float/Int coercion
/// already done by the time data reaches LoopStrapEngine).
private func movementBuckets(gravitySeries: [(ts: Double, v: Double)]) -> [Double: Double] {
    guard !gravitySeries.isEmpty else { return [:] }

    // Sort by timestamp (mirrors Python's `.sort(key=lambda r: r["ts"])`)
    let sorted = gravitySeries.sorted { $0.ts < $1.ts }

    // Compute per-sample intensity = |Δv| between consecutive samples.
    // The first sample always gets intensity 0.0 (no predecessor).
    var intensities: [(ts: Double, intensity: Double)] = []
    intensities.reserveCapacity(sorted.count)

    for (i, sample) in sorted.enumerated() {
        let intensity: Double
        if i == 0 {
            intensity = 0.0
        } else {
            let prev = sorted[i - 1]
            intensity = abs(sample.v - prev.v)
        }
        intensities.append((ts: sample.ts, intensity: intensity))
    }

    // Group into 60-second buckets and average finite intensities
    var rawBuckets: [Double: [Double]] = [:]
    for point in intensities {
        guard point.intensity.isFinite else { continue }
        let key = floor(point.ts / bucketSeconds) * bucketSeconds
        rawBuckets[key, default: []].append(point.intensity)
    }

    var out: [Double: Double] = [:]
    for (ts, vals) in rawBuckets where !vals.isEmpty {
        out[ts] = vals.reduce(0.0, +) / Double(vals.count)
    }
    return out
}

/// Clamp `value` to the range `[lo, hi]`.
private func clamp(_ value: Double, lo: Double, hi: Double) -> Double {
    max(lo, min(hi, value))
}
