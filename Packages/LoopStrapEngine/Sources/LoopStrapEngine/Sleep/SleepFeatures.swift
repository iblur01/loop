import Foundation

// MARK: - SleepFeatures

// Per-epoch cardiorespiratory feature extraction, ported from sleep_features.py.
//
// Implements the Stage 1 feature engine from the sleep staging pipeline:
//   - dogHRVariability  : Walch DoG HR-variability signal (σ1=120 s, σ2=600 s)
//   - respRateAndRRV    : respiratory rate + RRV from raw 1 Hz resp signal
//   - hrvFromRR         : time-domain HRV per epoch window (Phase 5: hf/lf/lfhf from Welch PSD)
//   - extractFeatures   : assemble EpochFeatures[] with stride-4 HRV/resp forward-fill
//
// These functions are the bridge between EpochGrid (Plan 01) and SleepClassifier (Plan 03).
// No external imports needed — NumericKit and HRV primitives are in the same SPM target.


// MARK: - EpochHRV

/// Time-domain HRV metrics for one epoch window.
///
/// Frequency-domain fields (`hf`, `lf`, `lfhf`) are filled by `hrvFrequency()` via Welch PSD
/// (Phase 5, per D-08). Fields are `.nan` when the epoch has insufficient RR intervals for
/// the frequency pipeline (fewer than FREQ_MIN_BEATS=120 filtered beats).
///
/// This struct is defined here (not in SleepTypes.swift) because it is an internal
/// implementation detail of the feature-extraction layer — not a public domain type
/// shared across the pipeline. `EpochFeatures` (in SleepTypes.swift) carries the
/// expanded per-epoch result that consumers see.
public struct EpochHRV {
    /// RMSSD in ms; `.nan` if fewer than 5 plausible RR intervals.
    public let rmssd: Double
    /// SDNN in ms; `.nan` if fewer than 5 plausible RR intervals.
    public let sdnn: Double
    /// HF power (ms²) — always `.nan` in Phase 3 per D-01; Phase 5 extends this field.
    public let hf: Double
    /// LF power (ms²) — always `.nan` in Phase 3 per D-01; Phase 5 extends this field.
    public let lf: Double
    /// LF/HF ratio — always `.nan` in Phase 3 per D-01; Phase 5 extends this field.
    public let lfhf: Double

    public init(rmssd: Double, sdnn: Double, hf: Double, lf: Double, lfhf: Double) {
        self.rmssd = rmssd
        self.sdnn = sdnn
        self.hf = hf
        self.lf = lf
        self.lfhf = lfhf
    }

    /// Convenience initialiser: all fields `.nan` (sentinel for "not enough data").
    static var allNaN: EpochHRV {
        EpochHRV(rmssd: .nan, sdnn: .nan, hf: .nan, lf: .nan, lfhf: .nan)
    }
}


// MARK: - dogHRVariability

/// Walch difference-of-Gaussians HR-variability signal (§1 feature 2).
///
/// Ports `dog_hr_variability` from `sleep_features.py`:
/// - Linear-interpolates NaN epochs (no HR samples) before filtering.
/// - Convolves the interpolated HR series with two Gaussians (σ1=120 s, σ2=600 s)
///   using reflect-pad boundary conditions, then returns G1 − G2.
/// - Returns `[]` if `hrPerEpoch` is empty; returns zeros if ALL epochs are NaN.
///
/// - Parameter hrPerEpoch: Per-epoch mean HR (bpm); `.nan` when no HR samples for that epoch.
/// - Returns: DoG-filtered signal, same length as `hrPerEpoch`.
public func dogHRVariability(hrPerEpoch: [Double]) -> [Double] {
    let n = hrPerEpoch.count
    guard n > 0 else { return [] }

    // NaN-fill via linear interpolation (matches np.interp with valid-index mask).
    let idx = (0..<n).map { Double($0) }
    let validIdx = idx.enumerated().compactMap { hrPerEpoch[$0.offset].isNaN ? nil : $0.element }
    let validHR  = (0..<n).compactMap { hrPerEpoch[$0].isNaN ? nil : hrPerEpoch[$0] }

    // If there are no valid HR samples at all, return zeros (matches Python behavior).
    guard !validHR.isEmpty else {
        return [Double](repeating: 0.0, count: n)
    }

    // Interpolate to fill NaN positions (clamp-at-boundary matches np.interp).
    let hrFilled = interp(idx, validIdx, validHR)

    // Two Gaussians: σ1 = 120 s → 4 epochs at 30 s/epoch; σ2 = 600 s → 20 epochs.
    let dtS = epochS  // 30.0 s
    let k1 = gaussianKernel(sigmaS: 120.0, dtS: dtS)
    let k2 = gaussianKernel(sigmaS: 600.0, dtS: dtS)

    let g1 = convolveReflect(hrFilled, k1)
    let g2 = convolveReflect(hrFilled, k2)

    // DoG = G1 − G2 (not abs — caller/classifier uses std of this signal).
    return zip(g1, g2).map { $0 - $1 }
}


// MARK: - hrvFromRR

/// Time-domain HRV metrics for one epoch window of raw RR intervals.
///
/// Ports `hrv_from_rr` from `sleep_features.py`:
/// - Applies `filterRR` (300–2000 ms physiological range filter).
/// - Requires ≥ 5 plausible intervals; returns all-NaN otherwise.
/// - Computes RMSSD (`rmssdMs`) and SDNN (`sdnn`).
///
/// Frequency-domain fields (hf, lf, lfhf) are filled by `hrvFrequency()` via Welch PSD
/// (Phase 5, per D-08). The call to `hrvFrequency(vals)` receives the already range-filtered
/// `vals` (post `filterRR`) — `hrvFrequency` internally calls `filterRR` again, which is
/// idempotent on 300–2000 ms intervals (T-05-09, accepted).
///
/// - Parameter rrMs: Raw RR intervals in milliseconds for the epoch window.
/// - Returns: `EpochHRV` with RMSSD/SDNN/LF/HF/LFHF if ≥ 5 plausible intervals, else all `.nan`.
public func hrvFromRR(_ rrMs: [Double]) -> EpochHRV {
    let vals = filterRR(rrMs)
    guard vals.count >= 5 else { return .allNaN }

    let rmssd = rmssdMs(vals)
    let sdnn   = (try? sdnn(vals)) ?? .nan

    // Phase 5: fill frequency-domain fields from Welch PSD (hrv_frequency port per D-08)
    let freq = hrvFrequency(vals)
    return EpochHRV(rmssd: rmssd, sdnn: sdnn, hf: freq.hf, lf: freq.lf, lfhf: freq.lfhf)
}


// MARK: - respRateAndRRV

/// Respiratory rate (breaths/min) and RRV (std of breath-to-breath intervals, s).
///
/// Ports `resp_rate_and_rrv` from `sleep_features.py`:
/// - Detrends by subtracting the mean.
/// - Detects peaks using `findPeaks(distance:2, height:0.0)` (minimum 2 s between
///   peaks at dt=1 s, matching a physiological ceiling of ~30 br/min).
/// - Requires ≥ 3 peaks to compute intervals; returns `(.nan, .nan)` otherwise.
/// - Filters intervals to [1.5, 12.0] s (5–40 br/min physiological window) and
///   requires ≥ 2 filtered intervals; returns `(.nan, .nan)` otherwise.
/// - Rate = 60 / median(intervals_s); RRV = std(intervals_s, population std: ddof=0).
///
/// Note: RRV `.nan` is intentional when breathing rhythm is unclear — the classifier
/// (Plan 03) treats `.nan` RRV as "regular" (pro-deep bias), NOT as irregular (Piège 6).
///
/// - Parameters:
///   - respSamples: Raw ~1 Hz respiration signal (arbitrary units).
///   - dt: Sample spacing in seconds (default 1.0 s for the WHOOP 1 Hz resp channel).
/// - Returns: `(rate: breaths/min, rrv: seconds)` or `(.nan, .nan)` on insufficient data.
public func respRateAndRRV(_ respSamples: [Double], dt: Double = 1.0) -> (rate: Double, rrv: Double) {
    guard respSamples.count >= 8 else { return (.nan, .nan) }

    // Detrend: subtract mean.
    let m = (try? mean(respSamples)) ?? 0.0
    let x = respSamples.map { $0 - m }

    // Check for zero/constant signal (allclose → NaN).
    let signalStd = (try? std(x)) ?? 0.0
    guard signalStd > 0 else { return (.nan, .nan) }

    // Peak detection matching Python's find_peaks params:
    //   distance = max(2, int(round(2.0 / dt_s))) — at dt=1 s → distance = 2
    //   height   = 0.0 (peaks must be above the detrended mean = 0)
    let distance = max(2, Int((2.0 / dt).rounded()))
    let peaks = findPeaks(x, distance: distance, height: 0.0)

    guard peaks.indices.count >= 3 else { return (.nan, .nan) }

    // Inter-peak intervals in seconds.
    let peakIdx = peaks.indices.map { Double($0) }
    let intervals = diff(peakIdx).map { $0 * dt }

    // Filter to physiological respiratory interval range: [1.5 s, 12.0 s] (5–40 br/min).
    let filtered = intervals.filter { $0 >= 1.5 && $0 <= 12.0 }
    guard filtered.count >= 2 else { return (.nan, .nan) }

    // Rate = 60 / median(intervals_s).
    let med = (try? median(filtered)) ?? .nan
    guard med.isFinite, med > 0 else { return (.nan, .nan) }
    let rate = 60.0 / med

    // RRV = population std of intervals (np.std uses ddof=0 by default).
    // std() uses ddof=1; for RRV we match Python np.std(ddof=0):
    let n = Double(filtered.count)
    let meanIntervals = filtered.reduce(0.0, +) / n
    let variance = filtered.reduce(0.0) { $0 + ($1 - meanIntervals) * ($1 - meanIntervals) } / n
    let rrv = variance.squareRoot()

    return (rate: rate, rrv: rrv)
}


// MARK: - extractFeatures

/// Assemble per-epoch `EpochFeatures` from an `EpochGrid` and pre-computed DoG HR-variability.
///
/// Ports `extract_features` from `sleep_features.py`:
/// - Rolls a feature window of ±half_w epochs (half_w = FEATURE_WINDOW_S / EPOCH_S / 2 ≈ 5 epochs)
///   centered on each epoch, clamped to [0, nEpochs).
/// - HRV and resp features use the pooled RR/resp samples from the window.
/// - **HRV/resp forward-fill:** These are computed only at "anchor" epochs
///   (`epochIdx % hrvStrideEpochs == 0`) and carried forward to the epochs in between
///   (4 epochs = 2-minute stride — window content changes negligibly over one 30 s step).
/// - Per-epoch HR: mean of `grid.hr[i]` scalar (NaN if epoch has no HR samples).
/// - `hrVar`: taken from the pre-computed `hrVar` array passed by the caller.
/// - `clock`: normalized time since sleep onset, `(i - onsetIdx) / span`, clamped [0, 1].
///   Used by `reimposePhhysiology` for the deep-late downgrade rule.
///
/// - Parameters:
///   - grid: The 30 s epoch grid from `buildEpochGrid`.
///   - hrVar: DoG HR-variability signal from `dogHRVariability`, same length as `grid.nEpochs`.
///   - onsetIdx: Zero-based epoch index of sleep onset (default 0; used for `clock` calculation).
///   - finalWakeIdx: Zero-based epoch index of final awakening (default `grid.nEpochs - 1`; used for `clock`).
/// - Returns: Array of `EpochFeatures`, one per epoch; empty if `grid.nEpochs == 0`.
public func extractFeatures(grid: EpochGrid, hrVar: [Double],
                             onsetIdx: Int = 0, finalWakeIdx: Int? = nil) -> [EpochFeatures] {
    guard grid.nEpochs > 0 else { return [] }

    let n = grid.nEpochs
    // Feature window: FEATURE_WINDOW_S = 300 s / EPOCH_S = 30 s → 10 epochs total, ±5.
    let featureWindowEpochs = 300.0 / epochS  // 10.0
    let halfW = Int((featureWindowEpochs / 2.0).rounded())  // 5

    // Clock normalization: (i - onsetIdx) / span, clamped [0, 1].
    let resolvedFinalWake = finalWakeIdx ?? (n - 1)
    let clockSpan = max(1, resolvedFinalWake - onsetIdx)

    // Forward-fill cache: HRV and resp are expensive — compute only at stride anchors.
    let stride = max(1, hrvStrideEpochs)  // 4
    var hrvCache = EpochHRV.allNaN
    var respCache: (rate: Double, rrv: Double) = (.nan, .nan)

    var feats: [EpochFeatures] = []
    feats.reserveCapacity(n)

    for i in 0..<n {
        let lo = max(0, i - halfW)
        let hi = min(n, i + halfW + 1)

        // --- Per-epoch HR: take from grid.hr scalar (NaN if no samples) ---
        let hrVal = grid.hr[i]

        // --- hrVar: taken from caller's pre-computed DoG array ---
        let hrVarVal: Double
        if i < hrVar.count {
            hrVarVal = hrVar[i]
        } else {
            hrVarVal = .nan
        }

        // --- Stride anchor: recompute HRV and resp for this window ---
        if i % stride == 0 {
            // Pool RR samples from the window.
            var winRR: [Double] = []
            for j in lo..<hi {
                winRR.append(contentsOf: grid.rrBuckets[j])
            }
            hrvCache = hrvFromRR(winRR)

            // Pool resp samples from the window.
            var winResp: [Double] = []
            for j in lo..<hi {
                winResp.append(contentsOf: grid.respBuckets[j])
            }
            respCache = respRateAndRRV(winResp)
        }
        // Non-anchor epochs forward-fill hrvCache and respCache from the last anchor.

        let clock = min(1.0, max(0.0, Double(i - onsetIdx) / Double(clockSpan)))
        feats.append(EpochFeatures(
            epochIdx:  i,
            hr:        hrVal,
            hrVar:     hrVarVal,
            rmssd:     hrvCache.rmssd,
            sdnn:      hrvCache.sdnn,
            hf:        hrvCache.hf,    // Phase 5: Welch PSD HF band power (D-08)
            lf:        hrvCache.lf,    // Phase 5: Welch PSD LF band power (D-08)
            lfhf:      hrvCache.lfhf,  // Phase 5: Welch PSD LF/HF ratio (D-08)
            respRate:  respCache.rate,
            rrv:       respCache.rrv,
            moveFrac:  grid.moveFrac[i],
            ckSleep:   grid.ckSleep[i],
            clock:     clock
        ))
    }
    return feats
}


// MARK: - Helpers

/// Reflect-pad convolution matching Python's `_convolve_reflect`.
///
/// Pads `x` symmetrically with reflected copies (radius = kernel.count / 2), then applies
/// `convolve(padded, kernel, mode: "valid")` and trims the result to `x.count`.
/// This matches `np.pad(x, r, mode="reflect") + np.convolve(padded, kernel, mode="valid")`.
///
/// - Returns: Array of same length as `x`; returns `x` unchanged when `r == 0` or `x` is empty.
private func convolveReflect(_ x: [Double], _ kernel: [Double]) -> [Double] {
    let r = kernel.count / 2
    guard r > 0, !x.isEmpty else { return x }

    // Build the reflect-padded signal.
    // numpy's mode="reflect" mirrors the signal at the edge:
    // Left pad:  x[1], x[2], ..., x[r]  (note: NOT x[0] — "reflect" excludes the edge point)
    //   → for i in 1..r: prepend x[i] in reverse order.
    //   When x is shorter than r, we clamp to valid indices (x has indices 0..n-1).
    // Right pad: x[n-2], ..., x[n-1-r]
    //   When x is shorter than r, we clamp to valid indices.
    let n = x.count
    var padded = [Double]()
    padded.reserveCapacity(n + 2 * r)

    // Left reflect pad: indices [min(r,n-1)..1] (reversed)
    let leftStart = min(r, n - 1)
    for i in stride(from: leftStart, through: 1, by: -1) {
        padded.append(x[i])
    }
    // If n == 1, reflect only provides x[0] repeatedly (no mirror point available)
    // Fill remaining left pad with x[0] when n < r+1.
    if leftStart < r {
        let extra = r - leftStart
        for _ in 0..<extra {
            padded.append(x[0])
        }
    }

    padded.append(contentsOf: x)

    // Right reflect pad: indices [n-2..max(0, n-1-r)] (in descending order)
    let rightEnd = max(0, n - 1 - r)
    let rightStart = n - 2
    if rightStart >= rightEnd && n >= 2 {
        for i in stride(from: rightStart, through: rightEnd, by: -1) {
            padded.append(x[i])
        }
    }
    // Fill remaining right pad with x[n-1] when n < r+1.
    let actualRight = rightStart >= rightEnd && n >= 2 ? rightStart - rightEnd + 1 : 0
    if actualRight < r {
        let extra = r - actualRight
        for _ in 0..<extra {
            padded.append(x[n - 1])
        }
    }

    // mode:"valid" convolution, then trim to original length.
    let result = convolve(padded, kernel, mode: "valid")
    return Array(result.prefix(n))
}

/// Normalised 1-D Gaussian kernel with σ given in seconds, sampled at `dtS`.
///
/// Ports `_gaussian_kernel` from `sleep_features.py`:
/// - Converts σ from seconds to epochs: `sigma = sigmaS / dtS`
/// - Radius: `max(1, Int(ceil(3 * sigma)))` — Piège 2: must use `ceil`, not `floor`.
/// - Kernel length = `2 * radius + 1`; sum-normalised to 1.
///
/// - Parameters:
///   - sigmaS: Gaussian standard deviation in seconds.
///   - dtS: Epoch spacing in seconds (default: `epochS` = 30.0 s).
/// - Returns: Sum-normalised kernel array of length `2 * radius + 1`.
private func gaussianKernel(sigmaS: Double, dtS: Double = epochS) -> [Double] {
    let sigma = max(sigmaS / dtS, 1e-6)  // σ in epochs
    let radius = max(1, Int(ceil(3 * sigma)))  // Piège 2: ceil, not floor
    let len = 2 * radius + 1
    var k = [Double](repeating: 0.0, count: len)
    for i in 0..<len {
        let x = Double(i - radius)
        k[i] = exp(-0.5 * (x / sigma) * (x / sigma))
    }
    let sum = k.reduce(0, +)
    if sum > 0 {
        return k.map { $0 / sum }
    }
    return k
}
