import Foundation

// MARK: - InBedDetection

// Stage 0 accelerometer-stillness sleep/wake spine.
// Port of sleep.py: _gravity_deltas → _classify_still → _build_runs →
// _merge_periods → _merge_mid_sleep_wakes → _confirm_sleep_with_hr → _trim_active_edges
// → detect_sleep (in-bed run extraction only).
//
// Named thresholds mirror sleep.py documented constants:
private let gravityStillThresholdG: Double = 0.01   // GRAVITY_STILL_THRESHOLD_G
private let stillWindowMin: Int                = 15   // STILL_WINDOW_MIN
private let stillFraction: Double              = 0.70 // STILL_FRACTION
private let maxGapMin: Int                     = 20   // MAX_GAP_MIN
private let mergeMins: Int                     = 15   // MERGE_MIN
private let minSleepMin: Int                   = 60   // MIN_SLEEP_MIN
private let defaultIntervalS: Double           = 60.0 // DEFAULT_INTERVAL_S
private let minWindowSamples: Int              = 3    // MIN_WINDOW_SAMPLES
private let hrSleepBaselineMult: Double        = 1.05 // HR_SLEEP_BASELINE_MULT
private let hrRefineMinSamples: Int            = 30   // HR_REFINE_MIN_SAMPLES
private let trimWindowMin: Int                 = 5    // TRIM_WINDOW_MIN
private let midSleepWakeMaxMin: Int            = 120  // MID_SLEEP_WAKE_MAX_MIN
private let midSleepWakeHRGateMult: Double     = 1.5  // MID_SLEEP_WAKE_HR_GATE_MULT


// MARK: - Public API

/// Detect in-bed periods (Stage 0) from raw gravity and HR streams.
///
/// Port of `sleep.detect_sleep` Stage 0 logic: gravity-vector delta stillness
/// classification → run detection → short-bout merge → mid-sleep wake merge →
/// HR confirmation → active-edge trimming.
///
/// - Parameters:
///   - gravTimes: Sorted Unix timestamps (s) of gravity samples.
///   - gravValues: Per-sample L2 gravity-vector magnitudes (g), same length as `gravTimes`.
///   - hrTimes: Sorted Unix timestamps (s) of HR samples.
///   - hrValues: HR in bpm, same length as `hrTimes`.
/// - Returns: Array of (start, end) Unix timestamp pairs for confirmed in-bed periods.
///   Returns `[]` if `gravValues.count < 2`.
/// A confirmed in-bed period: the HR-confirmed sleep sub-spans plus the wake gaps that bridge
/// them. Mirrors the per-period data `sleep.detect_sleep` carries into staging — each span is
/// staged independently and bridged gaps are inserted as explicit wake, so a still-but-awake
/// stretch between two confirmed spans (e.g. an evening doze before the real night) never reads
/// as sleep, and the session is bound to its true Sleep Period Time.
public struct InBedPeriod {
    public let confirmedSpans: [(start: Double, end: Double)]
    public let bridgedWakeGaps: [(start: Double, end: Double)]
}

/// Detect in-bed periods (Stage 0). Faithful port of `sleep.detect_sleep`'s pre-staging
/// pipeline: stillness → runs → short-bout merge → mid-sleep-wake merge → per-run active-edge
/// trim → per-sub-span HR confirmation. No session-duration cap: HR confirmation + the
/// downstream Sleep-Period-Time trim bound sessions exactly as Python does.
///
/// `gravValues` IS the per-record movement proxy (`gravityDeltaProxy`, = Python `_gravity_deltas`),
/// NOT the orientation-blind scalar magnitude. Returns `[]` if `gravValues.count < 2`.
public func detectInBedPeriods(
    gravTimes: [Double],
    gravValues: [Double],
    hrTimes: [Double],
    hrValues: [Double]
) -> [InBedPeriod] {
    guard gravValues.count >= 2, gravTimes.count == gravValues.count else { return [] }

    let deltas = gravValues
    let flags = classifyStill(times: gravTimes, deltas: deltas)
    var runs = buildRuns(times: gravTimes, flags: flags)
    let baseline = hrBaseline(hrTimes: hrTimes, hrValues: hrValues)
    runs = mergePeriods(runs, mergeMin: mergeMins)
    runs = mergeMidSleepWakes(runs, hrTimes: hrTimes, hrValues: hrValues, baseline: baseline)

    let minSleepS = Double(minSleepMin) * 60.0
    var result: [InBedPeriod] = []

    for var p in runs {
        guard p.stage == .sleep else { continue }
        p = trimActiveEdges(p, hrTimes: hrTimes, hrValues: hrValues, baseline: baseline)
        guard (p.end - p.start) > minSleepS else { continue }
        let confirmed = confirmedSleepSpans(
            p, hrTimes: hrTimes, hrValues: hrValues,
            baseline: baseline, minSleepS: minSleepS
        )
        guard !confirmed.isEmpty else { continue }

        // Bridged wake gaps: the merged wake gaps strictly inside the confirmed envelope,
        // each clipped to the raw moving samples that caused it (Python `_motion_span_in_gap`).
        let firstStart = confirmed.first!.0
        let lastEnd = confirmed.last!.1
        let bridged = p.wakeGaps
            .filter { firstStart < $0.0 && $0.1 < lastEnd }
            .map { motionSpanInGap($0.0, $0.1, gravTimes: gravTimes, deltas: deltas) }

        result.append(InBedPeriod(
            confirmedSpans: confirmed.map { (start: $0.0, end: $0.1) },
            bridgedWakeGaps: bridged.map { (start: $0.0, end: $0.1) }
        ))
    }

    return result
}

/// Legacy convenience wrapper: collapse each period to its `[first span start, last span end]`
/// envelope. Retained for the Stage-0 unit tests; the staging pipeline uses `detectInBedPeriods`.
public func detectInBedRuns(
    gravTimes: [Double],
    gravValues: [Double],
    hrTimes: [Double],
    hrValues: [Double]
) -> [(start: Double, end: Double)] {
    detectInBedPeriods(gravTimes: gravTimes, gravValues: gravValues,
                       hrTimes: hrTimes, hrValues: hrValues)
        .compactMap { p in
            guard let f = p.confirmedSpans.first, let l = p.confirmedSpans.last else { return nil }
            return (start: f.start, end: l.end)
        }
}

/// Clip a smoothed active run to the raw moving samples that caused it.
/// Port of `sleep._motion_span_in_gap`.
private func motionSpanInGap(_ gapStart: Double, _ gapEnd: Double,
                             gravTimes: [Double], deltas: [Double]) -> (Double, Double) {
    var firstMove: Double?, lastMove: Double?
    var i = lowerBound(gravTimes, gapStart)
    while i < gravTimes.count && gravTimes[i] <= gapEnd {
        if deltas[i] >= gravityStillThresholdG {
            if firstMove == nil { firstMove = gravTimes[i] }
            lastMove = gravTimes[i]
        }
        i += 1
    }
    guard let fm = firstMove, let lm = lastMove else { return (gapStart, gapEnd) }
    let interval = medianIntervalS(gravTimes)
    let start = (fm - gapStart) <= interval ? gapStart : fm
    let end = min(gapEnd, lm)
    if end <= start { return (gapStart, gapEnd) }
    return (start, end)
}

/// DEBUG-ONLY (additive, no behaviour change): dump the pipeline's intermediate runs and
/// per-run confirmed spans for parity diffing against the Python oracle. Not used by the
/// staging pipeline.
public func debugInBedPipeline(
    gravTimes: [Double], gravValues: [Double], hrTimes: [Double], hrValues: [Double]
) -> [(start: Double, end: Double, stage: String, nWakeGaps: Int, confirmed: [(Double, Double)])] {
    guard gravValues.count >= 2, gravTimes.count == gravValues.count else { return [] }
    let deltas = gravValues
    let flags = classifyStill(times: gravTimes, deltas: deltas)
    var runs = buildRuns(times: gravTimes, flags: flags)
    let baseline = hrBaseline(hrTimes: hrTimes, hrValues: hrValues)
    runs = mergePeriods(runs, mergeMin: mergeMins)
    runs = mergeMidSleepWakes(runs, hrTimes: hrTimes, hrValues: hrValues, baseline: baseline)
    let minSleepS = Double(minSleepMin) * 60.0
    return runs.map { p in
        let conf: [(Double, Double)] = p.stage == .sleep
            ? confirmedSleepSpans(p, hrTimes: hrTimes, hrValues: hrValues, baseline: baseline, minSleepS: minSleepS)
            : []
        return (start: p.start, end: p.end,
                stage: p.stage == .sleep ? "sleep" : "active",
                nWakeGaps: p.wakeGaps.count, confirmed: conf)
    }
}


// MARK: - Helpers

// A run of contiguous samples classified as sleep or active.
private struct Run {
    enum Stage { case sleep, active }
    var stage: Stage
    var start: Double
    var end: Double
    // Wake gaps embedded inside merged sleep runs (for mid-sleep wake tracking).
    var wakeGaps: [(Double, Double)]

    init(stage: Stage, start: Double, end: Double, wakeGaps: [(Double, Double)] = []) {
        self.stage = stage
        self.start = start
        self.end = end
        self.wakeGaps = wakeGaps
    }
}

/// Per-record movement proxy = L2 norm of the gravity CHANGE vector vs the previous record.
/// Faithful port of Python `sleep._gravity_deltas`.
///
/// The first record has no predecessor → 0.0. Any non-finite axis (a dropout) → `.infinity`
/// so a gap is never mistaken for stillness. This is the value the sleep pipeline expects in
/// `SleepStreams.gravity` and `detectInBedRuns(gravValues:)` — NOT the scalar magnitude, which
/// is orientation-blind (a rotation at constant |g| would read as zero movement).
public func gravityDeltaProxy(_ samples: [(t: Double, x: Double, y: Double, z: Double)]) -> [(t: Double, v: Double)] {
    guard !samples.isEmpty else { return [] }
    var out: [(t: Double, v: Double)] = []
    out.reserveCapacity(samples.count)
    out.append((t: samples[0].t, v: 0.0))
    for i in 1..<samples.count {
        let c = samples[i], p = samples[i - 1]
        if !c.x.isFinite || !c.y.isFinite || !c.z.isFinite
            || !p.x.isFinite || !p.y.isFinite || !p.z.isFinite {
            out.append((t: c.t, v: .infinity))
            continue
        }
        let dx = p.x - c.x, dy = p.y - c.y, dz = p.z - c.z
        out.append((t: c.t, v: (dx * dx + dy * dy + dz * dz).squareRoot()))
    }
    return out
}

/// Median gap between consecutive timestamps (restricted to 0–300 s); falls back to
/// `defaultIntervalS`. Never returns < 1 s.
private func medianIntervalS(_ times: [Double]) -> Double {
    guard times.count > 1 else { return defaultIntervalS }
    var gaps: [Double] = []
    for i in 0..<times.count - 1 {
        let g = times[i + 1] - times[i]
        if g > 0 && g < 300 { gaps.append(g) }
    }
    guard !gaps.isEmpty else { return defaultIntervalS }
    let sorted = gaps.sorted()
    return max(sorted[sorted.count / 2], 1.0)
}

/// Centred rolling-window size in samples that covers `stillWindowMin` minutes.
private func windowSize(_ times: [Double]) -> Int {
    let interval = medianIntervalS(times)
    return max(minWindowSamples, Int(Double(stillWindowMin * 60) / interval))
}

/// Per-sample sleep classification using a rolling stillness fraction.
///
/// An epoch is flagged as sleep when at least `stillFraction` (0.70) of samples
/// in the centred window have gravity delta < `gravityStillThresholdG`.
private func classifyStill(times: [Double], deltas: [Double]) -> [Bool] {
    let n = times.count
    guard n >= 2 else { return [Bool](repeating: false, count: n) }
    let half = windowSize(times) / 2
    // Perf (P4): the centred window recomputed a full `filter.count` over ~`2*half`
    // samples for EVERY sample — O(n·window), i.e. ~700M ops on 1 Hz day-streams.
    // Use a prefix sum of "still" flags so each window count is O(1). Bit-for-bit
    // identical to the previous per-window count → sleep parity is preserved.
    var prefix = [Int](repeating: 0, count: n + 1)
    for i in 0..<n {
        prefix[i + 1] = prefix[i] + (deltas[i] < gravityStillThresholdG ? 1 : 0)
    }
    var flags = [Bool](repeating: false, count: n)
    for i in 0..<n {
        let lo = max(0, i - half)
        let hi = min(n, i + half + 1)
        let stillCount = prefix[hi] - prefix[lo]
        flags[i] = Double(stillCount) / Double(hi - lo) >= stillFraction
    }
    return flags
}

/// Collapse per-sample flags into contiguous runs.
///
/// A run ends on class change or when the gap to the next sample exceeds `maxGapMin`.
private func buildRuns(times: [Double], flags: [Bool]) -> [Run] {
    let n = times.count
    guard n > 0 else { return [] }
    let maxGapS = Double(maxGapMin) * 60.0
    var periods: [Run] = []
    var runStart = 0
    for i in 1...n {
        let atEnd = i == n
        let close: Bool
        if atEnd {
            close = true
        } else {
            let classChanged = flags[i] != flags[runStart]
            let gapExceeded = (times[i] - times[i - 1]) > maxGapS
            close = classChanged || gapExceeded
        }
        if close {
            let stage: Run.Stage = flags[runStart] ? .sleep : .active
            periods.append(Run(stage: stage, start: times[runStart], end: times[i - 1]))
            runStart = i
        }
    }
    return periods
}

/// Short-bout filter: absorb runs shorter than `mergeMin` minutes into neighbours.
///
/// - A too-short run between two same-class runs bridges them into one.
/// - A too-short head run extends into the following run.
/// - A too-short tail run extends the preceding run.
/// - A lone too-short run with no usable neighbours is dropped.
private func mergePeriods(_ periods: [Run], mergeMin: Int) -> [Run] {
    guard !periods.isEmpty else { return [] }
    var pending = periods
    let thresholdS = Double(mergeMin) * 60.0
    var merged: [Run] = []
    var i = 0
    while i < pending.count {
        let current = pending[i]
        let tooShort = (current.end - current.start) < thresholdS

        if !tooShort {
            merged.append(current)
            i += 1
            continue
        }

        let hasPrev = i > 0 && !merged.isEmpty
        let hasNext = i + 1 < pending.count
        let bridgesSameClass = hasPrev && hasNext
            && (i > 0 ? pending[i - 1].stage : merged.last!.stage) == pending[i + 1].stage

        if bridgesSameClass {
            // Fuse prev + current + next
            var prev = merged.removeLast()
            prev.end = pending[i + 1].end
            merged.append(prev)
            i += 2
        } else if hasNext {
            // Extend next run backward
            pending[i + 1] = Run(
                stage: pending[i + 1].stage,
                start: current.start,
                end: pending[i + 1].end,
                wakeGaps: pending[i + 1].wakeGaps
            )
            i += 1
        } else if hasPrev {
            // Extend preceding run forward
            var prev = merged.removeLast()
            prev.end = current.end
            merged.append(prev)
            i += 1
        } else {
            i += 1
        }
    }
    return merged
}

/// Fuse tolerated active gaps into adjacent sleep runs (mid-sleep wake merge).
///
/// Guard (Piège 4): only absorbs a gap that has sleep on **both** sides (`hasPrev AND hasNext`).
/// A one-sided active gap is pre-sleep settling or post-wake, not a mid-sleep awakening.
private func mergeMidSleepWakes(
    _ runs: [Run],
    hrTimes: [Double],
    hrValues: [Double],
    baseline: Double?
) -> [Run] {
    guard !runs.isEmpty else { return [] }
    var pending = runs
    let thresholdS = Double(midSleepWakeMaxMin) * 60.0

    var changed = true
    while changed {
        changed = false
        for i in 0..<pending.count {
            let run = pending[i]
            guard run.stage == .active else { continue }
            guard (run.end - run.start) < thresholdS else { continue }

            // Guard Piège 4: only absorb if sleep on BOTH sides
            let hasPrev = i > 0 && pending[i - 1].stage == .sleep
            let hasNext = i + 1 < pending.count && pending[i + 1].stage == .sleep
            guard hasPrev && hasNext else { continue }
            guard tolerantHRGate(run, hrTimes: hrTimes, hrValues: hrValues, baseline: baseline) else { continue }

            let gap = (run.start, run.end)
            let prev = pending[i - 1]
            let nxt = pending[i + 1]
            let merged = Run(
                stage: .sleep,
                start: prev.start,
                end: nxt.end,
                wakeGaps: prev.wakeGaps + [gap] + nxt.wakeGaps
            )
            pending.replaceSubrange((i - 1)...(i + 1), with: [merged])
            changed = true
            break
        }
    }
    return pending
}

/// Compute median HR from all samples (day baseline). Returns `nil` if no samples.
private func hrBaseline(hrTimes: [Double], hrValues: [Double]) -> Double? {
    guard !hrValues.isEmpty else { return nil }
    let sorted = hrValues.sorted()
    return sorted[sorted.count / 2]
}

/// First index in the sorted `times` whose value is ≥ `target` (binary lower bound).
private func lowerBound(_ times: [Double], _ target: Double) -> Int {
    var lo = 0, hi = times.count
    while lo < hi {
        let mid = (lo + hi) / 2
        if times[mid] < target { lo = mid + 1 } else { hi = mid }
    }
    return lo
}

/// HR samples between `start` and `end` (inclusive).
///
/// Perf (P4): `hrTimes` is sorted ascending (store reads by (deviceId, ts) PK), so we
/// binary-search the start and walk to `end` — O(log n + k) instead of scanning the full
/// multi-day array on every call (rowsBetween is hit repeatedly inside trimActiveEdges and
/// the per-span HR confirmations). Same membership test (`t >= start && t <= end`).
private func rowsBetween(hrTimes: [Double], hrValues: [Double], start: Double, end: Double) -> [Double] {
    guard !hrTimes.isEmpty else { return [] }
    var result: [Double] = []
    var i = lowerBound(hrTimes, start)
    while i < hrTimes.count && hrTimes[i] <= end {
        result.append(hrValues[i])
        i += 1
    }
    return result
}

/// Split [start, end) at wake gaps → list of sub-spans.
/// Mirrors Python `_split_at_gaps`.
private func splitAtGaps(start: Double, end: Double, wakeGaps: [(Double, Double)]) -> [(Double, Double)] {
    var spans: [(Double, Double)] = []
    var cursor = start
    for (gapStart, gapEnd) in wakeGaps.sorted(by: { $0.0 < $1.0 }) {
        let clippedStart = max(start, gapStart)
        let clippedEnd = min(end, gapEnd)
        if cursor < clippedStart { spans.append((cursor, clippedStart)) }
        cursor = max(cursor, clippedEnd)
    }
    if cursor < end { spans.append((cursor, end)) }
    return spans
}

/// Return HR-confirmed sub-spans of a possibly wake-gapped sleep run.
/// Mirrors Python `_confirmed_sleep_spans`: keeps spans that pass the HR gate,
/// drops the rest (a high-HR false-start dozing span does not kill the real night).
private func confirmedSleepSpans(
    _ run: Run,
    hrTimes: [Double],
    hrValues: [Double],
    baseline: Double?,
    minSleepS: Double
) -> [(Double, Double)] {
    let spans: [(Double, Double)] = run.wakeGaps.isEmpty
        ? [(run.start, run.end)]
        : splitAtGaps(start: run.start, end: run.end, wakeGaps: run.wakeGaps)
    return spans.compactMap { spanStart, spanEnd in
        guard (spanEnd - spanStart) > minSleepS else { return nil }
        let tmp = Run(stage: .sleep, start: spanStart, end: spanEnd)
        return confirmSleepWithHR(tmp, hrTimes: hrTimes, hrValues: hrValues, baseline: baseline)
            ? (spanStart, spanEnd) : nil
    }
}

/// Confirm a sleep run via its mean HR (≤ baseline × 1.05).
/// Trusts gravity if baseline is nil or too few HR samples.
private func confirmSleepWithHR(
    _ run: Run,
    hrTimes: [Double],
    hrValues: [Double],
    baseline: Double?
) -> Bool {
    guard let baseline else { return true }
    let seg = rowsBetween(hrTimes: hrTimes, hrValues: hrValues, start: run.start, end: run.end)
    guard seg.count >= hrRefineMinSamples else { return true }
    let meanHR = seg.reduce(0.0, +) / Double(seg.count)
    return meanHR <= baseline * hrSleepBaselineMult
}

/// Tolerant HR gate for mid-sleep wake merge (allows up to 1.5× baseline elevation).
private func tolerantHRGate(
    _ gap: Run,
    hrTimes: [Double],
    hrValues: [Double],
    baseline: Double?
) -> Bool {
    guard let baseline else { return true }
    let seg = rowsBetween(hrTimes: hrTimes, hrValues: hrValues, start: gap.start, end: gap.end)
    guard seg.count >= hrRefineMinSamples else { return true }
    let meanHR = seg.reduce(0.0, +) / Double(seg.count)
    return meanHR <= baseline * midSleepWakeHRGateMult
}

/// Trim leading/trailing HR-elevated windows off a sleep run.
///
/// Stops at the first window (from each edge) that is at/below the gate or has too
/// few HR samples. No-op without an HR baseline.
private func trimActiveEdges(
    _ run: Run,
    hrTimes: [Double],
    hrValues: [Double],
    baseline: Double?
) -> Run {
    guard let baseline else { return run }
    let gate = baseline * hrSleepBaselineMult
    let windowS = Double(trimWindowMin) * 60.0
    var start = run.start
    var end = run.end

    while end - start > windowS {
        let seg = rowsBetween(hrTimes: hrTimes, hrValues: hrValues, start: start, end: start + windowS)
        if seg.count < hrRefineMinSamples { break }
        let mean = seg.reduce(0.0, +) / Double(seg.count)
        if mean <= gate { break }
        start += windowS
    }

    while end - start > windowS {
        let seg = rowsBetween(hrTimes: hrTimes, hrValues: hrValues, start: end - windowS, end: end)
        if seg.count < hrRefineMinSamples { break }
        let mean = seg.reduce(0.0, +) / Double(seg.count)
        if mean <= gate { break }
        end -= windowS
    }

    if start == run.start && end == run.end { return run }
    return Run(stage: run.stage, start: start, end: end, wakeGaps: run.wakeGaps.filter {
        $0.1 > start && $0.0 < end
    })
}
