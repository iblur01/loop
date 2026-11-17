import Foundation

// MARK: - CleanRRResult

/// Result of the full RR-cleaning pipeline (range filter + Kubios artifact correction).
///
/// Invariant: `peaksClean.count == nnClean.count + 1`.
public struct CleanRRResult {
    /// Corrected NN intervals in milliseconds, after artifact removal.
    public let nnClean: [Double]
    /// Corrected peak sample indices (at 1000 Hz; index / 1000.0 == seconds from window start).
    public let peaksClean: [Double]
    /// Total input interval count before any filtering.
    public let nBeats: Int
    /// Number of intervals flagged or corrected by range filter plus Kubios.
    public let nArtifacts: Int
}

// MARK: - cleanRR

/// RR-cleaning pipeline: range filter → Kubios artifact correction.
///
/// Steps:
///   1. Range filter — drop intervals outside `[300, 2000]` ms.
///   2. Convert filtered intervals to synthetic peak indices at 1000 Hz.
///   3. Kubios / Lipponen–Tarvainen (2019) iterative artifact correction.
///   4. Compute NN intervals via `diff(peaksClean)`.
///
/// - Parameter rrMs: Raw RR/IBI intervals in milliseconds.
/// - Returns: `CleanRRResult` with corrected intervals, peak indices, and artifact counts.
/// - Throws: `HRVError.insufficientPlausibleIntervals` when fewer than `minBeats` (20)
///   plausible intervals remain after range filtering.
public func cleanRR(_ rrMs: [Double]) throws -> CleanRRResult {
    let nBeats = rrMs.count
    let filtered = filterRR(rrMs)
    let nRangeDropped = nBeats - filtered.count
    guard filtered.count >= minBeats else {
        throw HRVError.insufficientPlausibleIntervals(function: "cleanRR", count: filtered.count)
    }
    let peaks = intervalsToPeaks(filtered, samplingRate: 1000)
    let (peaksClean, nKubios) = _signalFixpeaksKubios(peaks, samplingRate: 1000)
    let nnClean = diff(peaksClean)
    return CleanRRResult(
        nnClean: nnClean,
        peaksClean: peaksClean,
        nBeats: nBeats,
        nArtifacts: nRangeDropped + nKubios
    )
}

// MARK: - Kubios artifact detection

// Kubios constants (Lipponen & Tarvainen 2019, verified from neurokit2==0.2.13)
private let c1: Double = 0.13
private let c2: Double = 0.17
private let alpha: Double = 5.2
private let window_width: Int = 91
private let medfilt_order: Int = 11
private let padding: Int = 2

/// Artifact categories detected by the Kubios algorithm.
private struct ArtifactIndices {
    var ectopic: [Int]
    var missed: [Int]
    var extra: [Int]
    var longshort: [Int]

    var totalCount: Int {
        ectopic.count + missed.count + extra.count + longshort.count
    }
}

/// Iterative Kubios artifact correction.
///
/// Mirrors `_signal_fixpeaks_kubios` in neurokit2 (iterative=True):
///   1. Detect and correct artifacts on the initial peak array (one pass outside the loop).
///   2. Iterate: detect artifacts on the corrected peaks → if count did not strictly
///      decrease (n_current >= n_previous), stop WITHOUT applying the new correction.
///      Otherwise apply and repeat.
///
/// This "detect-first, correct-only-when-improving" pattern differs from a naive
/// "correct-then-check" loop: the last iteration that does NOT improve is never applied.
private func _signalFixpeaksKubios(_ peaks: [Double], samplingRate: Int) -> ([Double], Int) {
    // Step 1: Initial detection + correction (always applied once).
    let (initArtifacts, initN) = _findArtifacts(peaks, samplingRate: samplingRate)
    var peaksClean = _correctArtifacts(initArtifacts, peaks: peaks)
    var nCurrent = initN

    // Step 2: Iterative refinement — stop WITHOUT correcting when count plateaus.
    while true {
        let (newArtifacts, newN) = _findArtifacts(peaksClean, samplingRate: samplingRate)
        if newN >= nCurrent { break }
        peaksClean = _correctArtifacts(newArtifacts, peaks: peaksClean)
        nCurrent = newN
    }

    return (peaksClean, nCurrent)
}

/// Detect artifact beats in a peak array using the Kubios decision tree.
///
/// Port of `_find_artifacts` from neurokit2 `signal_fixpeaks.py` (Lipponen & Tarvainen 2019).
/// Returns detected indices grouped by artifact type, plus total count.
private func _findArtifacts(_ peaks: [Double], samplingRate: Int) -> (ArtifactIndices, Int) {
    let n = peaks.count
    guard n >= 2 else {
        return (ArtifactIndices(ectopic: [], missed: [], extra: [], longshort: []), 0)
    }
    let sr = Double(samplingRate)

    // Compute RR series (same length as peaks, first element = mean of rest).
    // Mirrors: rr = np.ediff1d(peaks, to_begin=0) / sampling_rate
    var rr = [0.0] + diff(peaks).map { $0 / sr }
    if rr.count > 1 {
        let tail = Array(rr[1...])
        let meanTail = tail.reduce(0.0, +) / Double(tail.count)
        rr[0] = meanTail
    }
    // rr.count == peaks.count

    // Compute dRRs (difference series, same length as peaks).
    // Mirrors: drrs = np.ediff1d(rr, to_begin=0)
    var drrs = [0.0] + diff(rr)
    if drrs.count > 1 {
        let tail = Array(drrs[1...])
        let meanTail = tail.reduce(0.0, +) / Double(tail.count)
        drrs[0] = meanTail
    }
    // drrs.count == peaks.count

    // Normalize drrs by threshold th1.
    // th1[i] = alpha * ((Q3 - Q1) / 2) of |drrs| in rolling window of width 91.
    let th1 = rollingIQR(drrs.map { abs($0) }, window: window_width)
    var drrsNorm = drrs
    for i in 0..<drrs.count {
        if th1[i] != 0 {
            drrsNorm[i] = drrs[i] / th1[i]
        } else {
            drrsNorm[i] = Double.nan
        }
    }

    // Reflect-pad drrsNorm and compute subspace vectors s12, s22.
    let drrs_pad = reflectPad(drrsNorm, padding)
    let (s12, s22) = computeS12S22(drrs: drrsNorm, drrs_pad: drrs_pad, n: drrsNorm.count)

    // Compute mRRs: deviation of each RR from rolling median, scaled.
    let medrr = rollingMedian(rr, window: medfilt_order)
    var mrrs = zip(rr, medrr).map { r, m in r - m }
    for i in 0..<mrrs.count where mrrs[i] < 0 {
        mrrs[i] *= 2
    }

    // Normalize mrrs by threshold th2.
    let th2 = rollingIQR(mrrs.map { abs($0) }, window: window_width)
    var mrrsNorm = mrrs
    for i in 0..<mrrs.count {
        if th2[i] != 0 {
            mrrsNorm[i] = mrrs[i] / th2[i]
        } else {
            mrrsNorm[i] = Double.nan
        }
    }

    // Artifact classification — decision tree (Figure 1 in Lipponen & Tarvainen 2019).
    var ectopicIdcs: [Int] = []
    var missedIdcs: [Int] = []
    var extraIdcs: [Int] = []
    var longshortIdcs: [Int] = []

    var i = 0
    while i < rr.count - 2 {
        let absDrrs = abs(drrsNorm[i])
        // NaN comparisons return false, so absDrrs <= 1 is false for NaN — correct per pitfall 2.
        if absDrrs <= 1 {
            i += 1
            continue
        }

        // Ectopic conditions (eq1, eq2).
        let eq1 = drrsNorm[i] > 1 && s12[i] < (-c1 * drrsNorm[i] - c2)
        let eq2 = drrsNorm[i] < -1 && s12[i] > (-c1 * drrsNorm[i] + c2)

        if eq1 || eq2 {
            ectopicIdcs.append(i)
            i += 1
            continue
        }

        // Check if we should even enter the long/short classification.
        let absMrrs = abs(mrrsNorm[i])
        if !(absDrrs > 1 || absMrrs > 3) {
            i += 1
            continue
        }

        // Long/short candidates: current index, possibly also i+1.
        var longshortCandidates = [i]
        let absDrrsNext1 = abs(drrsNorm[i + 1])
        let absDrrsNext2 = abs(drrsNorm[i + 2])
        if absDrrsNext1 < absDrrsNext2 {
            longshortCandidates.append(i + 1)
        }

        for j in longshortCandidates {
            let eq3 = drrsNorm[j] > 1 && s22[j] < -1   // long beat
            let eq4 = abs(mrrsNorm[j]) > 3               // long or short
            let eq5 = drrsNorm[j] < -1 && s22[j] > 1    // short beat

            if !(eq3 || eq4 || eq5) {
                // Not a long/short candidate — skip this j, continue to next candidate.
                continue
            }

            // Check missing (eq6) and extra (eq7).
            let eq6 = abs(rr[j] / 2 - medrr[j]) < th2[j] // missing beat
            // Guard eq7: j+1 must be in-bounds (j may be the last valid index).
            let eq7: Bool
            if j + 1 < rr.count {
                eq7 = abs(rr[j] + rr[j + 1] - medrr[j]) < th2[j] // extra beat
            } else {
                eq7 = false
            }

            if eq5 && eq7 {
                extraIdcs.append(j)
                break  // Classified — emit single i += 1 after the for-j loop.
            }
            if eq3 && eq6 {
                missedIdcs.append(j)
                break  // Classified — emit single i += 1 after the for-j loop.
            }
            longshortIdcs.append(j)
            break  // Classified — emit single i += 1 after the for-j loop.
        }
        i += 1
    }

    let artifacts = ArtifactIndices(
        ectopic: ectopicIdcs,
        missed: missedIdcs,
        extra: extraIdcs,
        longshort: longshortIdcs
    )
    return (artifacts, artifacts.totalCount)
}

// MARK: - Kubios artifact correction

/// Correct artifact beats: delete extras, interpolate missed, realign ectopic/longshort.
///
/// Port of `_correct_artifacts` from neurokit2. Strict order: extra → missed → ectopic/longshort.
/// After each deletion or insertion batch, all remaining index lists are updated via `updateIndices`.
private func _correctArtifacts(_ artifacts: ArtifactIndices, peaks: [Double]) -> [Double] {
    var peaks = peaks
    let extraIdcs = artifacts.extra
    var missedIdcs = artifacts.missed
    var ectopicIdcs = artifacts.ectopic
    var longshortIdcs = artifacts.longshort

    // 1. Delete extra peaks.
    if !extraIdcs.isEmpty {
        peaks = _correctExtra(extraIdcs, peaks: peaks)
        missedIdcs = updateIndices(source: extraIdcs, update: missedIdcs, delta: -1)
        ectopicIdcs = updateIndices(source: extraIdcs, update: ectopicIdcs, delta: -1)
        longshortIdcs = updateIndices(source: extraIdcs, update: longshortIdcs, delta: -1)
    }

    // 2. Add missing peaks.
    if !missedIdcs.isEmpty {
        peaks = _correctMissed(missedIdcs, peaks: peaks)
        ectopicIdcs = updateIndices(source: missedIdcs, update: ectopicIdcs, delta: 1)
        longshortIdcs = updateIndices(source: missedIdcs, update: longshortIdcs, delta: 1)
    }

    // 3. Realign ectopic and longshort (no count change).
    if !ectopicIdcs.isEmpty {
        peaks = _correctMisaligned(ectopicIdcs, peaks: peaks)
    }
    if !longshortIdcs.isEmpty {
        peaks = _correctMisaligned(longshortIdcs, peaks: peaks)
    }

    return peaks
}

/// Delete extra peaks at the given indices.
private func _correctExtra(_ extraIdcs: [Int], peaks: [Double]) -> [Double] {
    let deleteSet = Set(extraIdcs)
    return peaks.enumerated().compactMap { idx, val in
        deleteSet.contains(idx) ? nil : val
    }
}

/// Insert midpoint peaks at each missed index.
private func _correctMissed(_ missedIdcs: [Int], peaks: [Double]) -> [Double] {
    var corrected = peaks
    // Filter valid indices (> 0 and < count, mirroring Python's logical_and guard).
    let validIdcs = missedIdcs.filter { $0 > 0 && $0 < corrected.count }

    // Process in reverse order so earlier insertions don't shift subsequent indices.
    for idx in validIdcs.sorted().reversed() {
        let prev = corrected[idx - 1]
        let next = corrected[idx]
        let added = prev + (next - prev) / 2.0
        corrected.insert(added, at: idx)
    }
    return corrected
}

/// Realign misaligned peaks (ectopic or longshort) to the midpoint between neighbors.
private func _correctMisaligned(_ misalignedIdcs: [Int], peaks: [Double]) -> [Double] {
    var corrected = peaks
    // Valid: index > 1 and < count - 1 (same guard as Python).
    let validIdcs = misalignedIdcs.filter { $0 > 1 && $0 < corrected.count - 1 }
    guard !validIdcs.isEmpty else { return corrected }

    var deleteSet: [Int] = []
    var newPeaks: [Double] = []

    for j in validIdcs {
        let prev = corrected[j - 1]
        let next = corrected[j + 1]
        let halfIBI = (next - prev) / 2.0
        let interpolated = prev + halfIBI
        // Python: astype(int) — truncate toward zero (Int() in Swift).
        newPeaks.append(Double(Int(interpolated)))
        deleteSet.append(j)
    }

    // Delete misaligned, append interpolated, then sort (mergesort semantics).
    let deleteSet2 = Set(deleteSet)
    corrected = corrected.enumerated().compactMap { idx, val in
        deleteSet2.contains(idx) ? nil : val
    }
    corrected.append(contentsOf: newPeaks)
    corrected.sort()
    return corrected
}

/// Update a list of indices after peaks were inserted or deleted at `source` positions.
///
/// For each index s in `source`, every index u in `update` that is greater than s
/// is shifted by `delta`. Result is deduplicated and sorted (matches `np.unique`).
private func updateIndices(source: [Int], update: [Int], delta: Int) -> [Int] {
    guard !update.isEmpty else { return update }
    var result = update
    for s in source {
        result = result.map { u in u > s ? u + delta : u }
    }
    return Array(Set(result)).sorted()
}

// MARK: - Rolling window helpers

/// Rolling IQR-based threshold with center=True, min_periods=1.
///
/// Returns `alpha * (Q3 - Q1) / 2` for a window of `window` elements centered at each index,
/// matching neurokit2's `_compute_threshold` which computes `alpha * ((q3 - q1) / 2)`.
/// Uses naive O(n×w) sort per D-05 — no vDSP.
private func rollingIQR(_ xs: [Double], window: Int) -> [Double] {
    let n = xs.count
    let half = window / 2
    return (0..<n).map { i in
        let lo = max(0, i - half)
        let hi = min(n - 1, i + half)
        let slice = Array(xs[lo...hi])
        let q1 = (try? percentile(slice, 25.0)) ?? 0.0
        let q3 = (try? percentile(slice, 75.0)) ?? 0.0
        return alpha * ((q3 - q1) / 2.0)
    }
}

/// Rolling median with center=True, min_periods=1.
///
/// Uses naive O(n×w) sort per D-05 — no vDSP.
private func rollingMedian(_ xs: [Double], window: Int) -> [Double] {
    let n = xs.count
    let half = window / 2
    return (0..<n).map { i in
        let lo = max(0, i - half)
        let hi = min(n - 1, i + half)
        let slice = Array(xs[lo...hi])
        return (try? median(slice)) ?? xs[i]
    }
}

/// Reflect-pad an array using numpy's "reflect" mode (excludes boundary element).
///
/// For `pad=2`: prepends `xs[2], xs[1]`; appends `xs[n-2], xs[n-3]`.
private func reflectPad(_ xs: [Double], _ pad: Int) -> [Double] {
    guard xs.count > pad else {
        // Insufficient elements for reflect mode: fill prefix/suffix with zeros
        // to maintain expected length (xs.count + 2 * pad) and avoid out-of-bounds
        // accesses in computeS12S22. Callers in the main path are protected by the
        // minBeats guard in cleanRR; this handles direct internal calls defensively.
        let zeroPad = [Double](repeating: 0.0, count: pad)
        return zeroPad + xs + zeroPad
    }
    var result = [Double]()
    result.reserveCapacity(xs.count + 2 * pad)
    // Left reflect: xs[pad], xs[pad-1], ..., xs[1] (not xs[0]).
    for k in stride(from: pad, through: 1, by: -1) {
        result.append(xs[k])
    }
    result.append(contentsOf: xs)
    // Right reflect: xs[n-2], xs[n-3], ..., xs[n-1-pad].
    let n = xs.count
    for k in stride(from: n - 2, through: n - 1 - pad, by: -1) {
        result.append(xs[k])
    }
    return result
}

/// Compute subspaces s12 and s22 from a drrs array and its reflect-padded version.
///
/// Port of the s12/s22 computation in signal_fixpeaks.py L283–295.
private func computeS12S22(drrs: [Double], drrs_pad: [Double], n: Int) -> (s12: [Double], s22: [Double]) {
    var s12 = [Double](repeating: 0.0, count: n)
    var s22 = [Double](repeating: 0.0, count: n)
    let pad = 2
    for d in pad..<(pad + n) {
        let orig = d - pad
        let curr = drrs_pad[d]
        if curr > 0 {
            s12[orig] = max(drrs_pad[d - 1], drrs_pad[d + 1])
        } else if curr < 0 {
            s12[orig] = min(drrs_pad[d - 1], drrs_pad[d + 1])
        }
        if curr >= 0 {
            s22[orig] = min(drrs_pad[d + 1], drrs_pad[d + 2])
        } else {
            s22[orig] = max(drrs_pad[d + 1], drrs_pad[d + 2])
        }
    }
    return (s12, s22)
}
