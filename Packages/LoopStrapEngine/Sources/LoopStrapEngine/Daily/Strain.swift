import Foundation

/// Input screening policy shared by strain and source reconciliation. These broad
/// ranges match the app's HealthPlausibility contract; they detect corrupt values,
/// do not establish sensor accuracy or an individual's physiological limits.
public enum CardioInputPolicy {
    public static let heartRateBPM: ClosedRange<Double> = 25...250
    public static let restingHeartRateBPM: ClosedRange<Double> = 25...150
}

/// Session-RPE load in arbitrary units (CR-10 perceived exertion × minutes).
/// This is a separate self-reported training-load proxy; it is not added to the
/// cardiovascular strain score and does not estimate muscular damage.
public func sessionRPELoad(perceivedExertion: Double?, durationMinutes: Double) -> Double? {
    guard let perceivedExertion, perceivedExertion.isFinite,
          (0...10).contains(perceivedExertion), durationMinutes.isFinite,
          durationMinutes > 0 else { return nil }
    let load = perceivedExertion * durationMinutes
    return load.isFinite ? load : nil
}

// MARK: - Sex

/// Biological sex for TRIMP coefficient selection.
///
/// Matches `strain.py` sex-string conventions exactly — used as a raw value
/// in fixture JSON and `daily.py` calls.
public enum Sex: String, Codable {
    case male   = "male"
    case female = "female"
}

// MARK: - StrainError

/// Errors thrown by the Strain module when inputs are insufficient.
public enum StrainError: Error {
    /// The HR series does not contain enough samples to compute strain.
    case insufficientData(function: String, count: Int)
    /// Max HR is not greater than resting HR — heart-rate reserve is invalid.
    case invalidHRReserve(maxHR: Double, restingHR: Double)
    case invalidDifficulty(Double)
}

// MARK: - StrainResult

/// Loop cardiovascular load on a bounded 0–21 log-mapped scale.
///
/// Mirrors `strain.py strain_with_evidence()` return semantics: returns the
/// log-mapped strain scalar, raw TRIMP accumulator, per-zone Karvonen minutes,
/// and the estimated HRmax (when derived from history).
public struct StrainResult {
    /// Cardiovascular strain on the 0–21 log-mapped scale (2 dp, weighted zone load).
    public let strain: Double
    /// Raw Banister TRIMP accumulator (before log-mapping). Always ≥ 0.
    public let trimp: Double
    /// Minutes spent in each of the 5 Karvonen %HRR zones (index 0 = zone 1, lowest).
    /// Count is always exactly 5.
    public let hrZoneMinutes: [Double]
    /// Personalized HRmax used to compute HRR, when available from history.
    public let estimatedHRmax: Double?

    /// Supported observation time, including rest; not the elapsed window duration.
    public let observedMinutes: Double
    /// Supported minutes below the first declared zone (50% HRR), including rest.
    public let belowZoneMinutes: Double

    public init(strain: Double, trimp: Double, hrZoneMinutes: [Double], estimatedHRmax: Double?, observedMinutes: Double = 0, belowZoneMinutes: Double = 0) {
        self.observedMinutes = observedMinutes
        self.belowZoneMinutes = belowZoneMinutes
        self.strain = strain
        self.trimp = trimp
        self.hrZoneMinutes = hrZoneMinutes
        self.estimatedHRmax = estimatedHRmax
    }
}

// MARK: - Constants

/// Log-map denominator D in `strain = 21 × ln(TRIMP+1) / ln(D)`.
/// Historical Loop display normalization; not a calibrated WHOOP equivalent.
private let strainDenominator: Double = 5000.0

/// Pre-computed `ln(strainDenominator)` — avoids repeated log calls.
private let lnStrainDenominator: Double = log(5000.0)

/// Top of the strain scale.
private let maxStrain: Double = 21.0

/// Banister TRIMP exponential coefficient for men (Banister 1991).
private let banisterBMen: Double = 1.92

/// Banister TRIMP exponential coefficient for women (Banister 1991).
private let banisterBWomen: Double = 1.67

/// Pre-exponential scale factor (both sexes) on the intensity weight.
private let banisterScale: Double = 0.64

/// Edwards TRIMP zone weights (index 0 = zone 1, lowest intensity).
/// Historical Loop multipliers; these are not the canonical Edwards weights.
private let edwardsZoneWeights: [Double] = [0.5, 1.0, 1.5, 2.0, 3.0]

/// Minimum %HRR for a sample to count toward strain (activity detection).
/// Samples below this threshold are considered rest/inactive.
private let minActivityPctHRR: Double = 20.0

/// Difficulty multiplier for strain calculation.
/// 1.0 = normal, <1.0 = easier (lower strain), >1.0 = harder (higher strain).
/// Default is 0.6 to make strain less aggressive at rest.
private let defaultDifficulty: Double = 0.6

/// Minimum HR readings required before strain is reliable (≈10 min at 1 Hz).
private let minReadings: Int = 600

/// Lower %HRR boundaries of the 5 Karvonen zones (percent, lowest first).
/// Zone i spans [karvZoneLower[i], karvZoneLower[i+1]) with zone 5 open-ended.
let karvZoneLower: [Double] = [50.0, 60.0, 70.0, 80.0, 90.0]

/// Minimum HR samples in history before the 99.5th-percentile estimate is trusted.
private let hrmaxMinSamples: Int = 600

/// Percentile used for observed-HRmax estimation.
private let hrmaxPercentile: Double = 99.5

// MARK: - Public API

/// Tanaka et al. (2001) age-predicted HRmax: `208 − 0.7 × age`.
///
/// Gender-independent. Accurate across a wide adult age range.
///
/// - Parameter age: User age in years.
/// - Returns: Predicted HRmax in bpm.
public func tanakHRmax(age: Double) -> Double {
    208.0 - 0.7 * age
}

/// Estimate a personalized HRmax from a trailing HR series.
///
/// Selection logic mirrors `strain.py estimate_hrmax()`:
/// - With ≥ 600 samples, take the 99.5th percentile of history. If age is
///   also known, return the LARGER of observed and Tanaka (thin windows never
///   under-cap zones).
/// - With thin history but a known age, return the Tanaka estimate.
/// - With neither, return `nil`.
///
/// - Parameters:
///   - hrHistory: Trailing HR samples (bpm), any order.
///   - age: User age in years, or `nil` if unknown.
/// - Returns: Estimated HRmax in bpm, or `nil` when insufficient data.
public func estimateHRmax(hrHistory: [Double], age: Double? = nil) -> Double? {
    let tanaka = age.flatMap { $0.isFinite && $0 > 0 && CardioInputPolicy.heartRateBPM.contains(tanakHRmax(age: $0)) ? tanakHRmax(age: $0) : nil }
    let hrHistory = hrHistory.filter { $0.isFinite && CardioInputPolicy.heartRateBPM.contains($0) }
    let n = hrHistory.count

    if n >= hrmaxMinSamples {
        let sorted = hrHistory.sorted()
        let observed = percentile99_5(sorted: sorted)
        if let t = tanaka {
            return max(observed, t)
        }
        return observed
    }

    return tanaka
}

/// Cardiovascular strain (0–21) from the historical Loop weighted-zone model.
///
/// Computes strain over whatever HR window it is given — the caller selects the
/// physiologically meaningful window (waking period, workout bout, etc.).
///
/// Uses Edwards step-zone TRIMP with configurable difficulty multiplier.
///
/// - Parameters:
///   - hrSeries: Time-ordered HR samples as `(ts: Unix seconds, bpm: Double)`.
///   - restingHR: Resting HR (bpm) for the Karvonen denominator.
///   - hrmaxEstimate: Max HR (bpm) for the HRR denominator. Use `estimateHRmax()`.
///   - sex: Biological sex (unused with Edwards TRIMP, kept for API compatibility).
///   - difficulty: Optional multiplier for strain sensitivity. 1.0 = normal,
///     <1.0 = easier (lower strain), >1.0 = harder (higher strain). Default 0.6.
/// - Returns: `StrainResult` with 0–21 strain, raw TRIMP, 5 zone-minutes, nil estimatedHRmax.
/// - Throws: `StrainError.insufficientData` when `hrSeries.count < 600`.
///           `StrainError.invalidHRReserve` when `hrmaxEstimate ≤ restingHR`.
public func strain(
    hrSeries: [(ts: Double, bpm: Double)],
    restingHR: Double,
    hrmaxEstimate: Double,
    sex: Sex,
    difficulty: Double? = nil
) throws -> StrainResult {
    let hrSeries = normalizedHR(hrSeries)
    guard hrSeries.count >= minReadings else {
        throw StrainError.insufficientData(function: "strain", count: hrSeries.count)
    }
    guard hrmaxEstimate.isFinite, CardioInputPolicy.heartRateBPM.contains(hrmaxEstimate), restingHR.isFinite, CardioInputPolicy.restingHeartRateBPM.contains(restingHR), hrmaxEstimate > restingHR, (hrmaxEstimate - restingHR).isFinite else {
        throw StrainError.invalidHRReserve(maxHR: hrmaxEstimate, restingHR: restingHR)
    }

    let hrReserve = hrmaxEstimate - restingHR
    let durations = sampleDurations(hrSeries: hrSeries)
    let difficultyMultiplier = difficulty ?? defaultDifficulty
    guard difficultyMultiplier.isFinite, difficultyMultiplier >= 0 else {
        throw StrainError.invalidDifficulty(difficultyMultiplier)
    }

    let rawTrimp = edwardsTRIMP(
        hrSeries: hrSeries,
        restingHR: restingHR,
        hrReserve: hrReserve,
        durations: durations
    )
    let adjustedTrimp = rawTrimp * difficultyMultiplier
    guard adjustedTrimp.isFinite else {
        throw StrainError.invalidDifficulty(difficultyMultiplier)
    }
    let strainValue = trimpToStrain(adjustedTrimp)
    let zoneMinutes = karvZoneMinutes(
        hrSeries: hrSeries,
        restingHR: restingHR,
        hrReserve: hrReserve,
        durations: durations
    )

    return StrainResult(
        strain: strainValue,
        trimp: adjustedTrimp,
        hrZoneMinutes: zoneMinutes,
        estimatedHRmax: nil,
        observedMinutes: durations.reduce(0, +),
        belowZoneMinutes: zip(hrSeries, durations).reduce(0) { total, entry in
            total + (pctHRR(bpm: entry.0.bpm, restingHR: restingHR, hrReserve: hrReserve) < karvZoneLower[0] ? entry.1 : 0)
        }
    )
}

/// Cardiovascular strain and raw TRIMP, for callers that need both values.
///
/// Equivalent to `strain.py strain_with_evidence()`. Returns the same strain
/// scalar as `strain()` plus the raw TRIMP accumulator needed for evidence rows.
///
/// - Parameters:
///   - hrSeries: Time-ordered HR samples as `(ts: Unix seconds, bpm: Double)`.
///   - restingHR: Resting HR (bpm) for the Karvonen denominator.
///   - hrmaxEstimate: Max HR (bpm) for the HRR denominator.
///   - sex: Biological sex (unused with Edwards TRIMP, kept for API compatibility).
///   - difficulty: Optional multiplier for strain sensitivity. Default 0.6.
/// - Returns: `StrainResult` with `estimatedHRmax` set to `nil`.
/// - Throws: Same as `strain()`.
public func strainWithEvidence(
    hrSeries: [(ts: Double, bpm: Double)],
    restingHR: Double,
    hrmaxEstimate: Double,
    sex: Sex,
    difficulty: Double? = nil
) throws -> StrainResult {
    return try strain(
        hrSeries: hrSeries,
        restingHR: restingHR,
        hrmaxEstimate: hrmaxEstimate,
        sex: sex,
        difficulty: difficulty
    )
}

// MARK: - Helpers

/// Each sample represents the interval until the next reading. Large gaps are
/// capped at the typical cadence: absence of data is not evidence of sustained HR.
/// The final sample receives one typical interval, preserving regular-series behavior.
/// Support is capped at the existing external-HR hold limit (10 s), a data-support
/// policy rather than a physiological claim. Sparse background points cannot
/// establish sustained intensity between observations.
/// Deterministic tie policy for conflicting readings at the same instant: median.
/// Duplicate observations never increase supported duration or sample sufficiency.
private func normalizedHR(_ series: [(ts: Double, bpm: Double)]) -> [(ts: Double, bpm: Double)] {
    let sorted = series.filter { $0.ts.isFinite && $0.bpm.isFinite && CardioInputPolicy.heartRateBPM.contains($0.bpm) }
        .sorted { $0.ts == $1.ts ? $0.bpm < $1.bpm : $0.ts < $1.ts }
    var result: [(ts: Double, bpm: Double)] = []
    var i = 0
    while i < sorted.count {
        var end = i + 1
        while end < sorted.count && sorted[end].ts == sorted[i].ts { end += 1 }
        let middle = i + (end - i) / 2
        let bpm = (end - i) % 2 == 0
            ? sorted[middle - 1].bpm / 2 + sorted[middle].bpm / 2 : sorted[middle].bpm
        result.append((sorted[i].ts, bpm))
        i = end
    }
    return result
}

private func sampleDurations(hrSeries: [(ts: Double, bpm: Double)]) -> [Double] {
    let deltas = zip(hrSeries, hrSeries.dropFirst()).map { $1.ts - $0.ts }
    let positive = deltas.filter { $0.isFinite && $0 > 0 }.sorted()
    let cadence = min(SupplementalHR.maxHoldSeconds, positive.isEmpty ? 1.0 : positive[positive.count / 2])
    let durations = deltas.map { delta -> Double in
        guard delta.isFinite, delta > 0 else { return 0 }
        return min(SupplementalHR.maxHoldSeconds, delta > cadence * 3 ? cadence : delta) / 60.0
    }
    return durations + [cadence / 60.0]
}

/// Karvonen %HRR for one sample, clamped to [0, 100].
func pctHRR(bpm: Double, restingHR: Double, hrReserve: Double) -> Double {
    let pct = (bpm - restingHR) / hrReserve * 100.0
    return max(0.0, min(100.0, pct))
}

/// Returns the zone index (0-4) for a given %HRR value.
/// Zone boundaries: [50, 60, 70, 80, 90]. Samples below 50% are zone 0.
func zoneIndex(forPctHRR pct: Double) -> Int {
    for i in stride(from: 4, through: 0, by: -1) {
        if pct >= karvZoneLower[i] { return i }
    }
    return 0
}

/// Historical Loop weighted-zone accumulator, not canonical Edwards TRIMP.
///
/// Each sample is assigned to a Karvonen zone, then contributes
/// `duration × zoneWeight`. Only samples with %HRR > minActivityPctHRR
/// count toward strain (activity detection gate).
private func edwardsTRIMP(
    hrSeries: [(ts: Double, bpm: Double)],
    restingHR: Double,
    hrReserve: Double,
    durations: [Double]
) -> Double {
    var accumulated = 0.0
    for (sample, duration) in zip(hrSeries, durations) {
        let pct = pctHRR(bpm: sample.bpm, restingHR: restingHR, hrReserve: hrReserve)
        if pct < minActivityPctHRR { continue }
        let zoneIdx = zoneIndex(forPctHRR: pct)
        accumulated += duration * edwardsZoneWeights[zoneIdx]
    }
    return accumulated
}

/// Banister exponential TRIMP accumulator (legacy, kept for reference).
///
/// Each sample contributes `duration × x × 0.64 × e^{b·x}` where `x` is the
/// fractional %HRR (0..1). Only samples with x > 0 contribute (resting samples
/// are excluded as in `strain.py _banister_trimp()`).
private func banisterTRIMP(
    hrSeries: [(ts: Double, bpm: Double)],
    restingHR: Double,
    hrReserve: Double,
    sampleDurationMin: Double,
    b: Double
) -> Double {
    var accumulated = 0.0
    for sample in hrSeries {
        let x = pctHRR(bpm: sample.bpm, restingHR: restingHR, hrReserve: hrReserve) / 100.0
        if x > 0.0 {
            accumulated += sampleDurationMin * x * banisterScale * exp(b * x)
        }
    }
    return accumulated
}

/// Map accumulated TRIMP onto [0, 21] via `21 × ln(TRIMP+1) / ln(D)`.
///
/// TRIMP ≤ 0 maps to 0.0. Result rounded to 2 dp.
private func trimpToStrain(_ trimp: Double) -> Double {
    guard trimp > 0.0 else { return 0.0 }
    let value = maxStrain * log(trimp + 1.0) / lnStrainDenominator
    return min(maxStrain, (value * 100.0).rounded() / 100.0)
}

/// Minutes spent in each of the 5 Karvonen %HRR zones.
///
/// Zone i (0-indexed) covers %HRR ≥ karvZoneLower[i]. A sample is counted in
/// the highest zone its %HRR qualifies for. Returns exactly 5 elements.
/// Samples below 50% HRR are reported separately as below-zone minutes.
private func karvZoneMinutes(
    hrSeries: [(ts: Double, bpm: Double)],
    restingHR: Double,
    hrReserve: Double,
    durations: [Double]
) -> [Double] {
    var zones = [Double](repeating: 0.0, count: 5)
    for (sample, duration) in zip(hrSeries, durations) {
        let pct = pctHRR(bpm: sample.bpm, restingHR: restingHR, hrReserve: hrReserve)
        if pct < karvZoneLower[0] { continue }
        let zoneIdx = zoneIndex(forPctHRR: pct)
        zones[zoneIdx] += duration
    }
    return zones
}

/// Linear-interpolated percentile of a sorted sequence (numpy-style).
///
/// Used only for the 99.5th percentile HRmax estimate.
private func percentile99_5(sorted: [Double]) -> Double {
    let n = sorted.count
    guard n > 1 else { return sorted.isEmpty ? 0.0 : sorted[0] }
    let position = (hrmaxPercentile / 100.0) * Double(n - 1)
    let lower = Int(position)
    let upper = min(lower + 1, n - 1)
    let frac = position - Double(lower)
    return sorted[lower] + frac * (sorted[upper] - sorted[lower])
}
