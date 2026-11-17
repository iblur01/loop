import Foundation

// MARK: - HRVFrequencyResult

/// Frequency-domain HRV metrics for one epoch window.
///
/// Computed from the Welch PSD of the quadratically-interpolated RR signal.
/// All fields are `.nan` when input is below `FREQ_MIN_BEATS` or welchPSD returns empty.
public struct HRVFrequencyResult {
    /// LF band power (0.04–0.15 Hz), normalized. `.nan` on guard failure.
    public let lf: Double
    /// HF band power (0.15–0.40 Hz), normalized. `.nan` on guard failure.
    public let hf: Double
    /// LF/HF ratio. `.nan` when `hf` is zero, NaN, or infinite.
    public let lfhf: Double

    public init(lf: Double, hf: Double, lfhf: Double) {
        self.lf = lf
        self.hf = hf
        self.lfhf = lfhf
    }

    /// Sentinel value returned on guard failures (empty input, below threshold, etc.).
    public static var allNaN: HRVFrequencyResult {
        HRVFrequencyResult(lf: .nan, hf: .nan, lfhf: .nan)
    }
}

// MARK: - HRV frequency constants

// Minimum number of valid (post-filterRR) RR intervals required to compute
// frequency-domain HRV. Mirrors FREQ_MIN_BEATS = 120 in sleep_features.py line 74.
private let freqMinBeats: Int = 120

// Target sampling rate for the RR interpolation grid (Hz).
// Matches hrv_frequency(interpolation_rate=100) default in neurokit2.
private let interpolationRate: Double = 100.0

// MARK: - hrvFrequency

/// Compute LF, HF band powers and LF/HF ratio from raw RR intervals.
///
/// Replicates the `hrv_from_rr` + `hrv_frequency` pipeline from neurokit2:
///
/// 1. `filterRR` — remove physiologically implausible intervals (300–2000 ms)
/// 2. Guard `vals.count >= FREQ_MIN_BEATS` (120) — return `.allNaN` if below
/// 3. `intervalsToPeaks` — convert filtered RR intervals to 1000 Hz peak indices
/// 4. RRI re-extraction via `diff(peaks)` — produces RRI in ms with cumsum timestamps
/// 5. Quadratic interpolation to 100 Hz grid
/// 6. `welchPSD` — Welch periodogram (detrended, periodic Hann, normalized)
/// 7. `bandPower` — trapezoidal integration over LF [0.04, 0.15] and HF [0.15, 0.40]
///
/// - Parameter rrMs: Raw RR intervals in milliseconds (caller may pass unfiltered).
/// - Returns: `HRVFrequencyResult` with finite lf/hf/lfhf, or `.allNaN` on guard failure.
public func hrvFrequency(_ rrMs: [Double]) -> HRVFrequencyResult {
    // Step 1: Apply physiological range filter (D-06, Pitfall 5).
    // FREQ_MIN_BEATS guard uses the post-filter count, not the raw count.
    let vals = filterRR(rrMs)

    // Step 2: FREQ_MIN_BEATS guard — avoids calling Welch on insufficient data (D-07, T-05-04).
    guard vals.count >= freqMinBeats else { return .allNaN }

    // Step 3: Convert filtered RR intervals to 1000 Hz peak indices.
    let peaks = intervalsToPeaks(vals, samplingRate: 1000)

    // Step 4: RRI re-extraction (Pitfall 4 — mirrors _hrv_get_rri behavior).
    // peaks are at 1000 Hz → diff(peaks) / 1000 * 1000 = same ms values as vals.
    // Timestamps in seconds = cumsum(rri_ms / 1000), starting at rri_ms[0] / 1000.
    let rriMs = _diff(peaks).map { $0 / 1000.0 * 1000.0 }
    let rriTimeS = _cumsum(rriMs.map { $0 / 1000.0 })

    guard !rriTimeS.isEmpty else { return .allNaN }

    // Step 5: Quadratic interpolation to 100 Hz.
    // x_new = arange(tStart, tEnd + dt, dt) at dt = 0.01 s (100 Hz grid).
    let dt = 1.0 / interpolationRate          // 0.01 s
    let tStart = rriTimeS.first!
    let tEnd   = rriTimeS.last!
    var xNew: [Double] = []
    var t = tStart
    while t <= tEnd + dt * 0.5 {             // + 0.5*dt tolerance to match Python arange
        xNew.append(t)
        t += dt
    }
    guard !xNew.isEmpty else { return .allNaN }

    let interpolated = _quadraticInterp(xp: rriTimeS, fp: rriMs, xNew: xNew)

    // Step 6: Welch PSD.
    // Do NOT detrend here — welchPSD detrends internally (mean detrend at entry).
    // Pre-detrending would cause a double-detrend.
    let (freqs, power) = welchPSD(interpolated, samplingRate: interpolationRate)
    guard !freqs.isEmpty else { return .allNaN }

    // Step 7: Band integration.
    let lf   = bandPower(frequencies: freqs, power: power, lo: 0.04, hi: 0.15)
    let hf   = bandPower(frequencies: freqs, power: power, lo: 0.15, hi: 0.40)
    // Guard hf > 0 before computing ratio (T-05-06 — prevents division by zero).
    let lfhf = (hf > 0.0 && hf.isFinite) ? lf / hf : Double.nan

    return HRVFrequencyResult(lf: lf, hf: hf, lfhf: lfhf)
}

// MARK: - Helpers

/// Differences between consecutive elements: result[i] = x[i+1] - x[i].
///
/// Returns an empty array when `x.count < 2`.
private func _diff(_ x: [Double]) -> [Double] {
    guard x.count >= 2 else { return [] }
    return (1..<x.count).map { x[$0] - x[$0 - 1] }
}

/// Cumulative sum: result[i] = sum(x[0..<i+1]).
private func _cumsum(_ x: [Double]) -> [Double] {
    var result = [Double](repeating: 0.0, count: x.count)
    var running = 0.0
    for (i, v) in x.enumerated() {
        running += v
        result[i] = running
    }
    return result
}

/// Piecewise quadratic interpolation, mimicking `scipy.interpolate.interp1d(kind="quadratic")`.
///
/// For each query point in `xNew`:
/// - If outside [xp[0], xp[last]]: clamp to the boundary fill value (fp[0] or fp[last]).
/// - Otherwise: find the 3 nearest original points, fit a quadratic through them, evaluate.
///   Falls back to linear interpolation when fewer than 3 original points are available.
///
/// Mirrors the `fill_value=(fp[0], fp[-1]), bounds_error=False` defaults of interp1d.
private func _quadraticInterp(xp: [Double], fp: [Double], xNew: [Double]) -> [Double] {
    let n = xp.count
    guard n >= 1 else { return [Double](repeating: 0.0, count: xNew.count) }
    guard n >= 2 else {
        // Single-point: return constant fp[0] everywhere
        return [Double](repeating: fp[0], count: xNew.count)
    }

    if n < 3 {
        // Fall back to linear interpolation for degenerate case
        return _linearInterp(xp: xp, fp: fp, xNew: xNew)
    }

    return xNew.map { x in
        // Boundary clamping (T-05-05 — prevents NaN propagation from extrapolation)
        if x <= xp[0] { return fp[0] }
        if x >= xp[n - 1] { return fp[n - 1] }

        // Find the index j such that xp[j] <= x < xp[j+1]
        var lo = 0, hi = n - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if xp[mid] <= x { lo = mid } else { hi = mid }
        }

        // Choose a 3-point window centered around the interval [lo, lo+1].
        // scipy interp1d(kind="quadratic") uses the 3 nearest points.
        let i1: Int
        if lo == 0 {
            i1 = 0       // first window: [0, 1, 2]
        } else if lo >= n - 2 {
            i1 = n - 3   // last window: [n-3, n-2, n-1]
        } else {
            i1 = lo - 1  // interior: [lo-1, lo, lo+1]
        }
        let i2 = i1 + 1
        let i3 = i1 + 2

        let x1 = xp[i1], y1 = fp[i1]
        let x2 = xp[i2], y2 = fp[i2]
        let x3 = xp[i3], y3 = fp[i3]

        // Lagrange quadratic interpolation through (x1,y1), (x2,y2), (x3,y3)
        let l1 = (x - x2) * (x - x3) / ((x1 - x2) * (x1 - x3))
        let l2 = (x - x1) * (x - x3) / ((x2 - x1) * (x2 - x3))
        let l3 = (x - x1) * (x - x2) / ((x3 - x1) * (x3 - x2))
        return y1 * l1 + y2 * l2 + y3 * l3
    }
}

/// Linear interpolation fallback (used when xp has fewer than 3 points).
private func _linearInterp(xp: [Double], fp: [Double], xNew: [Double]) -> [Double] {
    let n = xp.count
    return xNew.map { x in
        if x <= xp[0] { return fp[0] }
        if x >= xp[n - 1] { return fp[n - 1] }
        var lo = 0, hi = n - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if xp[mid] <= x { lo = mid } else { hi = mid }
        }
        let t = (x - xp[lo]) / (xp[lo + 1] - xp[lo])
        return fp[lo] + t * (fp[lo + 1] - fp[lo])
    }
}
