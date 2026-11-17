import Foundation

// MARK: - EpochGrid functions

// Port of sleep_features.py: build_epoch_grid, rescale_counts, cole_kripke.
//
// Cole–Kripke te Lindert 30 s coefficients (CK_WEIGHTS, pinned — DO NOT change):
//   [A₋₄, A₋₃, A₋₂, A₋₁, A₀, A₊₁, A₊₂]
//   SI = 0.001 × Σ wᵢ·Aᵢ ; epoch is SLEEP if SI < 1.
// Source: dipetkov/actigraph.sleepr apply_cole_kripke.R, te Lindert 2013.
private let ckWeights: [Double] = [106.0, 54.0, 58.0, 76.0, 230.0, 74.0, 67.0]
private let ckScale: Double = 0.001
private let ckBack: Int = 4   // epochs before current
// CK_FWD = 2 (ckWeights.count - ckBack - 1 = 7 - 4 - 1 = 2)

// Activity count rescaling constants (te Lindert 30 s, §2.0):
private let ckCountDivisor: Double  = 100.0
private let ckCountClip: Double     = 300.0
private let moveDeltaThresholdG: Double = 0.01  // mirrors MOVE_DELTA_THRESHOLD_G

// BIG sentinel: any non-finite gravity delta contributes this much to the count so
// the epoch reads as maximum motion (mirrors Python: BIG = CK_COUNT_CLIP * CK_COUNT_DIVISOR).
private let bigCount: Double = ckCountClip * ckCountDivisor  // 30_000.0


// MARK: - rescaleCounts

/// Rescale raw per-epoch activity counts for Cole–Kripke: ÷100, clip to 300.
///
/// Port of `sleep_features.rescale_counts`. `counts` are the per-epoch summed
/// |Δgravity| activity proxies. Returns the rescaled, clipped counts used by
/// `coleKripke`.
///
/// - Parameter counts: Raw per-epoch summed gravity deltas.
/// - Returns: Rescaled counts (÷100, clamped to [0, 300]).
public func rescaleCounts(_ counts: [Double]) -> [Double] {
    counts.map { min($0 / ckCountDivisor, ckCountClip) }
}


// MARK: - coleKripke

/// Per-epoch sleep flags via Cole–Kripke (te Lindert 30 s form, §2.1).
///
///     SI = 0.001 × (106·A₋₄ + 54·A₋₃ + 58·A₋₂ + 76·A₋₁ + 230·A₀ + 74·A₊₁ + 67·A₊₂)
///     epoch is SLEEP if SI < 1, else WAKE
///
/// `rescaledCounts` must already be ÷100/clip-300 (use `rescaleCounts`).
/// Out-of-range neighbours contribute 0 (standard edge handling).
///
/// This implementation uses a manual weighted sum — NOT NumericKit's `convolve` —
/// to guarantee exact boundary handling matching the Python oracle.
///
/// - Parameter rescaledCounts: Pre-scaled activity counts from `rescaleCounts`.
/// - Returns: Per-epoch sleep flag (true = sleep).
public func coleKripke(_ rescaledCounts: [Double]) -> [Bool] {
    let n = rescaledCounts.count
    guard n > 0 else { return [] }
    var flags = [Bool](repeating: false, count: n)
    for i in 0..<n {
        var si = 0.0
        for (k, w) in ckWeights.enumerated() {
            let j = i - ckBack + k  // k=0 → i-4 ... k=6 → i+2
            let a = (j >= 0 && j < n) ? rescaledCounts[j] : 0.0
            si += w * a
        }
        si *= ckScale
        flags[i] = si < 1.0
    }
    return flags
}


// MARK: - buildEpochGrid

/// Resample all four streams onto a common 30 s epoch grid over [start, end).
///
/// Covers a single in-bed run `[start, end)`. When multiple runs are provided,
/// the function uses the union span (min start, max end). Prefer calling once per
/// run and compositing results for multi-run nights.
///
/// Special case (Piège 1): a gravity sample with `ts == end` is assigned to the
/// last bucket (`nEpochs - 1`) rather than being ignored. This matches the Python
/// `_idx` implementation which treats the normally-half-open upper bound as a
/// special inclusive case for the exact end timestamp.
///
/// Guard: if `inBedRuns` is empty, returns an empty `EpochGrid` (nEpochs = 0).
///
/// - Parameters:
///   - inBedRuns: Sorted (start, end) Unix timestamp pairs from `detectInBedRuns`.
///   - hrTimes: Sorted Unix timestamps of HR samples.
///   - hrValues: HR in bpm; parallel to `hrTimes`.
///   - rrTimes: Sorted Unix timestamps of RR samples.
///   - rrValues: RR intervals in ms; parallel to `rrTimes`.
///   - respTimes: Sorted Unix timestamps of respiration samples.
///   - respValues: Raw respiration values; parallel to `respTimes`.
///   - gravTimes: Sorted Unix timestamps of gravity samples.
///   - gravValues: Per-sample gravity magnitudes (g) or pre-computed L2 deltas; parallel to `gravTimes`.
/// - Returns: `EpochGrid` with 30 s buckets; `nEpochs = 0` when `inBedRuns` is empty.
public func buildEpochGrid(
    inBedRuns: [(Double, Double)],
    hrTimes: [Double],
    hrValues: [Double],
    rrTimes: [Double],
    rrValues: [Double],
    respTimes: [Double],
    respValues: [Double],
    gravTimes: [Double],
    gravValues: [Double]
) -> EpochGrid {
    guard !inBedRuns.isEmpty else {
        return EpochGrid(
            start: 0, end: 0, nEpochs: 0,
            counts: [], moveFrac: [], ckSleep: [],
            hr: [], rrBuckets: [], respBuckets: []
        )
    }

    let start = inBedRuns.map { $0.0 }.min()!
    let end   = inBedRuns.map { $0.1 }.max()!

    guard end > start else {
        return EpochGrid(
            start: start, end: end, nEpochs: 0,
            counts: [], moveFrac: [], ckSleep: [],
            hr: [], rrBuckets: [], respBuckets: []
        )
    }

    let nEpochs = max(1, Int(ceil((end - start) / epochS)))

    // gravValues IS the per-record movement proxy (Python `_gravity_deltas`, see
    // `gravityDeltaProxy`) — already the L2 change vector per record. Use as-is; do NOT
    // re-difference (that was the orientation-blind magnitude bug).
    let gravDeltas = gravValues

    // Per-epoch accumulators
    var rawCounts  = [Double](repeating: 0.0, count: nEpochs)
    var moveN      = [Int](repeating: 0, count: nEpochs)
    var gravN      = [Int](repeating: 0, count: nEpochs)
    var hrSum      = [Double](repeating: 0.0, count: nEpochs)
    var hrCnt      = [Int](repeating: 0, count: nEpochs)
    var rrBuckets  = [[Double]](repeating: [], count: nEpochs)
    var respBuckets = [[Double]](repeating: [], count: nEpochs)

    // Gravity → activity counts + scale-robust move-fraction
    for (i, ts) in gravTimes.enumerated() {
        guard let idx = epochIdx(ts, start: start, end: end, nEpochs: nEpochs) else { continue }
        let d = gravDeltas[i]
        let moving = !d.isFinite || d >= moveDeltaThresholdG
        rawCounts[idx] += d.isFinite ? d : bigCount
        gravN[idx] += 1
        if moving { moveN[idx] += 1 }
    }

    // HR → per-epoch mean
    for (i, ts) in hrTimes.enumerated() {
        guard let idx = epochIdx(ts, start: start, end: end, nEpochs: nEpochs) else { continue }
        hrSum[idx] += hrValues[i]
        hrCnt[idx] += 1
    }

    // RR → per-epoch buckets
    for (i, ts) in rrTimes.enumerated() {
        guard let idx = epochIdx(ts, start: start, end: end, nEpochs: nEpochs) else { continue }
        rrBuckets[idx].append(rrValues[i])
    }

    // Resp → per-epoch buckets
    for (i, ts) in respTimes.enumerated() {
        guard let idx = epochIdx(ts, start: start, end: end, nEpochs: nEpochs) else { continue }
        respBuckets[idx].append(respValues[i])
    }

    let hrMean: [Double] = (0..<nEpochs).map { i in
        hrCnt[i] > 0 ? hrSum[i] / Double(hrCnt[i]) : Double.nan
    }
    // Move-fraction: epochs with no gravity coverage default to 1.0 (conservative — treat as moving).
    let moveFrac: [Double] = (0..<nEpochs).map { i in
        gravN[i] > 0 ? Double(moveN[i]) / Double(gravN[i]) : 1.0
    }
    let scaledCounts = rescaleCounts(rawCounts)
    let ckFlags = coleKripke(scaledCounts)

    return EpochGrid(
        start: start, end: end, nEpochs: nEpochs,
        counts: scaledCounts, moveFrac: moveFrac, ckSleep: ckFlags,
        hr: hrMean, rrBuckets: rrBuckets, respBuckets: respBuckets
    )
}


// MARK: - Helpers

/// Map a timestamp to an epoch index in [0, nEpochs - 1].
///
/// - Returns: `nil` if `ts < start` or `ts > end` (outside grid).
///   `nEpochs - 1` when `ts == end` (Piège 1: inclusive upper boundary).
///   Normal bucket otherwise: `Int((ts - start) / epochS)`, clamped.
private func epochIdx(_ ts: Double, start: Double, end: Double, nEpochs: Int) -> Int? {
    if ts < start { return nil }
    // Special case (Piège 1): ts exactly at end → last bucket
    if ts == end { return nEpochs - 1 }
    if ts > end { return nil }
    let i = Int((ts - start) / epochS)
    return min(i, nEpochs - 1)
}

