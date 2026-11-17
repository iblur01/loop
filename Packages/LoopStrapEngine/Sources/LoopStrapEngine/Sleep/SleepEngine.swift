import Foundation

// MARK: - SleepEngine

// Public entry point for the full sleep staging pipeline.
//
// Ports detect_sleep, _stage_session, _trim_to_sleep_period, hypnogram_metrics,
// and daily_sleep_summary from sleep.py (1033 LOC) to Swift.
//
// Pipeline overview:
//   Stage 0  In-bed detection  →  detectInBedRuns (InBedDetection.swift)
//   Stage 1  Epoch grid + features  →  buildEpochGrid / extractFeatures (EpochGrid.swift / SleepFeatures.swift)
//   Stage 2  Classification  →  classifyEpochs (SleepClassifier.swift)
//   Stage 3  Post-processing  →  smoothLabels / reimposePhhysiology (SleepClassifier.swift)
//   Session  segmentsFromLabels → trimToSleepPeriod → SleepSession
//
// No async — the pipeline is pure computation.


// MARK: - DailySleepSummary

/// Aggregated AASM sleep metrics for one calendar date.
///
/// Mirrors the `daily_sleep_summary` return dict from `sleep.py`. `date` is the
/// UTC calendar date whose main sleep cluster (session end falls on `date`) is
/// summarised. Fields are zero / nil when no matching session exists.
public struct DailySleepSummary {
    /// UTC calendar date string (ISO-8601: "YYYY-MM-DD").
    public let date: String
    /// Total sleep time in minutes (light + deep + REM), summed across sessions.
    public let totalSleepMin: Double
    /// In-bed-weighted mean sleep efficiency (TST / TIB), 0..1.
    public let efficiency: Double
    /// Deep sleep in minutes.
    public let deepMin: Double
    /// REM sleep in minutes.
    public let remMin: Double
    /// Light sleep in minutes.
    public let lightMin: Double
    /// Post-onset wake runs summed across sessions.
    public let disturbances: Int
    /// Lowest 5-min rolling-mean HR across sessions (bpm); `nil` if no HR data.
    public let restingHR: Double?
    /// In-bed-weighted mean RMSSD across sessions (ms); `nil` if no RR data.
    public let avgRmssd: Double?
    /// Start timestamp (Unix s) of earliest session in the cluster; `nil` if no sessions.
    public let sleepStart: Double?
    /// End timestamp (Unix s) of latest session in the cluster; `nil` if no sessions.
    public let sleepEnd: Double?

    /// Public memberwise init so callers (e.g. the incremental compute path) can reconstruct a
    /// summary for an already-computed "clean" day from its cached snapshot, instead of reloading
    /// raw streams and re-detecting — the only fields a history fold reads.
    public init(
        date: String,
        totalSleepMin: Double,
        efficiency: Double,
        deepMin: Double,
        remMin: Double,
        lightMin: Double,
        disturbances: Int,
        restingHR: Double?,
        avgRmssd: Double?,
        sleepStart: Double?,
        sleepEnd: Double?
    ) {
        self.date = date
        self.totalSleepMin = totalSleepMin
        self.efficiency = efficiency
        self.deepMin = deepMin
        self.remMin = remMin
        self.lightMin = lightMin
        self.disturbances = disturbances
        self.restingHR = restingHR
        self.avgRmssd = avgRmssd
        self.sleepStart = sleepStart
        self.sleepEnd = sleepEnd
    }
}


// MARK: - detectSleep

/// Detect sleep sessions from raw multi-stream sensor data.
///
/// Entry point for the full sleep pipeline:
/// Stage 0 (in-bed detection) → Stage 1 (epoch grid + features) →
/// Stage 2 (classifier) → Stage 3 (post-processing) → session segmentation.
///
/// Returns `[]` if `streams.gravity.count < 2` (insufficient data).
///
/// - Parameter streams: Named arrays of timestamped samples (`hr`, `rr`, `resp`, `gravity`).
/// - Returns: Detected sleep sessions with AASM metrics. Empty if no sleep detected.
public func detectSleep(streams: SleepStreams) -> [SleepSession] {
    guard streams.gravity.count >= 2 else { return [] }

    // Unpack streams into parallel time+value arrays (the pipeline's internal convention).
    let gravTimes  = streams.gravity.map { $0.t }
    let gravValues = streams.gravity.map { $0.v }
    let hrTimes    = streams.hr.map { $0.t }
    let hrValues   = streams.hr.map { $0.v }
    let rrTimes    = streams.rr.map { $0.t }
    let rrValues   = streams.rr.map { $0.v }
    let respTimes  = streams.resp.map { $0.t }
    let respValues = streams.resp.map { $0.v }

    // Stage 0: gravity-stillness detection → per-period HR-confirmed sleep spans + bridged
    // wake gaps (faithful port of sleep.detect_sleep's pre-staging pipeline).
    let periods = detectInBedPeriods(
        gravTimes: gravTimes, gravValues: gravValues,
        hrTimes: hrTimes, hrValues: hrValues
    )

    // Stage 1–3 + session building: one session per period. Each confirmed span is staged
    // independently and the bridged gaps are inserted as explicit wake, so a still-but-awake
    // stretch between two confirmed spans (e.g. an evening doze) never reads as sleep. The
    // session is then anchored to its Sleep Period Time (leading/trailing wake trimmed).
    var sessions: [SleepSession] = []
    for period in periods {
        var stages: [StageSegment] = []
        for span in period.confirmedSpans {
            stages.append(contentsOf: stageSession(
                start: span.start, end: span.end,
                gravTimes: gravTimes, gravValues: gravValues,
                hrTimes: hrTimes, hrValues: hrValues,
                rrTimes: rrTimes, rrValues: rrValues,
                respTimes: respTimes, respValues: respValues
            ))
        }
        for gap in period.bridgedWakeGaps {
            stages.append(StageSegment(start: gap.start, end: gap.end, stage: .wake))
        }
        stages.sort { $0.start < $1.start }
        // Piège 3: anchor the session to its Sleep Period Time — drop leading/trailing wake.
        stages = trimToSleepPeriod(stages)
        guard !stages.isEmpty else { continue }

        let sptStart = stages[0].start
        let sptEnd   = stages[stages.count - 1].end
        let metrics  = hypnogramMetrics(stages)

        // Per-session resting HR and mean RMSSD.
        let restingHR = sessionRestingHR(start: sptStart, end: sptEnd,
                                          hrTimes: hrTimes, hrValues: hrValues)
        let avgRmssd  = sessionAvgRmssd(start: sptStart, end: sptEnd,
                                         rrTimes: rrTimes, rrValues: rrValues)

        sessions.append(SleepSession(
            start: sptStart,
            end: sptEnd,
            stages: stages,
            efficiency: metrics.efficiency,
            tst: metrics.tst / 60.0,
            sol: metrics.sol / 60.0,
            waso: metrics.waso / 60.0,
            restingHR: restingHR ?? .nan,
            avgRmssd: avgRmssd ?? .nan,
            nDisturbances: metrics.nDisturbances
        ))
    }

    sessions.sort { $0.start < $1.start }
    return sessions
}


// MARK: - detectSleepBatch

/// Detect sleep for several independent windows concurrently.
///
/// Each `SleepStreams` is staged by a fully independent, pure `detectSleep` call, so the batch
/// fans them out across the global concurrent executor (off any calling actor) and gathers the
/// results back in input order. Used by the incremental compute path to stage a chunk of nights
/// in parallel instead of one-at-a-time. Results are bit-identical to calling `detectSleep` on
/// each element serially — only the scheduling changes.
///
/// - Parameter streamsList: One `SleepStreams` per window to stage.
/// - Returns: Sessions per window, aligned to `streamsList` order.
public func detectSleepBatch(_ streamsList: [SleepStreams]) async -> [[SleepSession]] {
    guard !streamsList.isEmpty else { return [] }
    return await withTaskGroup(of: (Int, [SleepSession]).self) { group in
        for (i, streams) in streamsList.enumerated() {
            group.addTask { (i, detectSleep(streams: streams)) }
        }
        var out = [[SleepSession]](repeating: [], count: streamsList.count)
        for await (i, result) in group { out[i] = result }
        return out
    }
}


// MARK: - hypnogramMetrics

/// AASM-style metrics from a session's stage segments.
///
/// Ports `hypnogram_metrics` from `sleep.py` (§5).
///
/// Definitions (AASM scoring manual, JCSM 2017):
///   TST = Σ (light + deep + REM) segment seconds.
///   SOL = first sleep start − session start.
///   WASO = wake seconds after onset and before final sleep.
///   efficiency = TST / TIB, in [0, 1].
///   disturbances = count of distinct WAKE runs after sleep onset.
///
/// - Parameter stages: Sorted `StageSegment` array from a `SleepSession`.
/// - Returns: Named metric tuple. All durations in seconds except where noted.
///   Returns zeros if `stages` is empty or all-wake.
public func hypnogramMetrics(
    _ stages: [StageSegment]
) -> (tst: Double, sol: Double, waso: Double, efficiency: Double,
      lightSecs: Double, deepSecs: Double, remSecs: Double, wakeSecs: Double,
      nDisturbances: Int) {

    guard !stages.isEmpty else {
        return (tst: 0, sol: 0, waso: 0, efficiency: 0,
                lightSecs: 0, deepSecs: 0, remSecs: 0, wakeSecs: 0, nDisturbances: 0)
    }

    let sortedSegs = stages.sorted { $0.start < $1.start }
    let sessionStart = sortedSegs[0].start
    let sessionEnd   = sortedSegs[sortedSegs.count - 1].end
    let tib = max(0.0, sessionEnd - sessionStart)

    let lightSecs = sortedSegs.filter { $0.stage == .light }.reduce(0.0) { $0 + $1.end - $1.start }
    let deepSecs  = sortedSegs.filter { $0.stage == .deep  }.reduce(0.0) { $0 + $1.end - $1.start }
    let remSecs   = sortedSegs.filter { $0.stage == .rem   }.reduce(0.0) { $0 + $1.end - $1.start }
    let wakeSecs  = sortedSegs.filter { $0.stage == .wake  }.reduce(0.0) { $0 + $1.end - $1.start }
    let tst = lightSecs + deepSecs + remSecs

    let sleepSegs = sortedSegs.filter { $0.stage != .wake }
    let onset: Double
    let sptEnd: Double
    if let first = sleepSegs.first, let last = sleepSegs.last {
        onset  = first.start
        sptEnd = last.end
    } else {
        onset  = sessionEnd
        sptEnd = sessionEnd
    }
    let sol = max(0.0, onset - sessionStart)

    // WASO: wake time strictly after onset and before sptEnd.
    var waso = 0.0
    var nDisturbances = 0
    for seg in sortedSegs {
        guard seg.stage == .wake else { continue }
        let w0 = max(seg.start, onset)
        let w1 = min(seg.end, sptEnd)
        if w1 > w0 {
            waso += (w1 - w0)
            nDisturbances += 1
        }
    }

    let efficiency = tib > 0 ? min(1.0, tst / tib) : 0.0
    return (tst: tst, sol: sol, waso: waso, efficiency: efficiency,
            lightSecs: lightSecs, deepSecs: deepSecs, remSecs: remSecs,
            wakeSecs: wakeSecs, nDisturbances: nDisturbances)
}


// MARK: - dailySleepSummary

/// Aggregate sleep metrics for one calendar date.
///
/// Ports `daily_sleep_summary` from `sleep.py`. Matches sessions whose `end`
/// timestamp falls on `date` (ISO-8601 string "YYYY-MM-DD" in `timeZone`). When multiple
/// separate sleeps end on that date, uses the session with the most TST.
///
/// Returns a `DailySleepSummary` with zeros / nils when no session matches.
///
/// - Parameters:
///   - sessions: All detected sessions from `detectSleep`.
///   - date: Calendar date string in ISO-8601 format ("YYYY-MM-DD").
///   - timeZone: Time zone used to attribute sessions to calendar days. Defaults to UTC.
/// - Returns: Aggregated daily metrics for the main sleep cluster ending on `date`.
public func dailySleepSummary(sessions: [SleepSession], date: String,
                              timeZone: TimeZone = TimeZone(secondsFromGMT: 0)!) -> DailySleepSummary {
    summarizeSleep(sessions.filter { endDate($0, in: timeZone) == date }, date: date)
}

/// Local-day variant: attributes a session to `date` when its `end` lies in `[from, to)`
/// (Unix seconds), i.e. the exact bounds of the local day, including 23 h / 25 h DST days and
/// travel days. This is the policy used by the app pipeline.
public func dailySleepSummary(sessions: [SleepSession], date: String,
                              endWindow: (from: Double, to: Double)) -> DailySleepSummary {
    summarizeSleep(sessions.filter { $0.end >= endWindow.from && $0.end < endWindow.to }, date: date)
}

private func summarizeSleep(_ sessions: [SleepSession], date: String) -> DailySleepSummary {
    let matched = sessions.sorted { $0.start < $1.start }

    guard !matched.isEmpty else {
        return DailySleepSummary(
            date: date, totalSleepMin: 0, efficiency: 0,
            deepMin: 0, remMin: 0, lightMin: 0, disturbances: 0,
            restingHR: nil, avgRmssd: nil, sleepStart: nil, sleepEnd: nil
        )
    }

    // Cluster sessions separated by ≤ 180 min (MAIN_SLEEP_CLUSTER_MAX_GAP_MIN).
    let maxGapS: Double = 180.0 * 60.0
    var clusters: [[SleepSession]] = []
    var current: [SleepSession] = [matched[0]]
    for session in matched.dropFirst() {
        if session.start - current[current.count - 1].end <= maxGapS {
            current.append(session)
        } else {
            clusters.append(current)
            current = [session]
        }
    }
    clusters.append(current)

    // Pick cluster with most total TST.
    let mainCluster = clusters.max(by: { clusterTST($0) < clusterTST($1) }) ?? matched

    var deepS = 0.0, remS = 0.0, lightS = 0.0, tstS = 0.0, inBedS = 0.0
    var effWeighted = 0.0
    var disturbances = 0

    for s in mainCluster {
        let m = hypnogramMetrics(s.stages)
        let inBed = s.end - s.start
        inBedS       += inBed
        effWeighted  += s.efficiency * inBed
        deepS        += m.deepSecs
        remS         += m.remSecs
        lightS       += m.lightSecs
        tstS         += m.tst
        disturbances += m.nDisturbances
    }

    let efficiency = inBedS > 0 ? effWeighted / inBedS : 0.0

    // Resting HR: lowest per-session value.
    let restingHRs = mainCluster.map { $0.restingHR }.filter { $0.isFinite }
    let restingHR: Double? = restingHRs.isEmpty ? nil : restingHRs.min()

    // Avg RMSSD: in-bed-weighted mean.
    let rmssdPairs = mainCluster.compactMap { s -> (Double, Double)? in
        guard s.avgRmssd.isFinite else { return nil }
        return (s.avgRmssd, s.end - s.start)
    }
    let avgRmssd: Double?
    if rmssdPairs.isEmpty {
        avgRmssd = nil
    } else {
        let totalW = rmssdPairs.reduce(0.0) { $0 + $1.1 }
        avgRmssd = totalW > 0 ? rmssdPairs.reduce(0.0) { $0 + $1.0 * $1.1 } / totalW : nil
    }

    return DailySleepSummary(
        date: date,
        totalSleepMin: tstS / 60.0,
        efficiency: efficiency,
        deepMin: deepS / 60.0,
        remMin: remS / 60.0,
        lightMin: lightS / 60.0,
        disturbances: disturbances,
        restingHR: restingHR,
        avgRmssd: avgRmssd,
        sleepStart: mainCluster.map { $0.start }.min(),
        sleepEnd: mainCluster.map { $0.end }.max()
    )
}


// MARK: - Helpers

/// Build a 30 s epoch hypnogram for a single in-bed span `[start, end)`.
///
/// Ports `_stage_session` from `sleep.py`. Steps:
///   Stage 1: build epoch grid + DoG HR-var + feature extraction.
///   Stage 2: classify epochs.
///   Stage 3: smooth + reimpose physiology; force pre-onset/post-final to wake.
///   Finally: merge consecutive same-stage labels into `StageSegment` array.
///
/// Returns a single `.light` segment covering `[start, end)` when the epoch grid is
/// empty (too few samples), matching the Python oracle fallback.
private func stageSession(
    start: Double,
    end: Double,
    gravTimes: [Double],
    gravValues: [Double],
    hrTimes: [Double],
    hrValues: [Double],
    rrTimes: [Double],
    rrValues: [Double],
    respTimes: [Double],
    respValues: [Double]
) -> [StageSegment] {
    // Perf (P4): buildEpochGrid bucket-scans every passed sample, but only those in
    // [start, end) land in a bucket. Feeding the full multi-day arrays meant re-scanning
    // ~777k samples per stream for EACH run (×12 runs). Slice each stream to the run window
    // first via binary search. Gravity keeps one pre-start sample so the first in-window
    // delta (|v[i]-v[i-1]|) stays exact — that out-of-range sample buckets to nil.
    let (gT, gV) = sliceStream(gravTimes, gravValues, start, end, includePrev: true)
    let (hT, hV) = sliceStream(hrTimes, hrValues, start, end, includePrev: false)
    let (rT, rV) = sliceStream(rrTimes, rrValues, start, end, includePrev: false)
    let (pT, pV) = sliceStream(respTimes, respValues, start, end, includePrev: false)

    // Build the epoch grid over [start, end) — single run.
    let grid = buildEpochGrid(
        inBedRuns: [(start, end)],
        hrTimes: hT, hrValues: hV,
        rrTimes: rT, rrValues: rV,
        respTimes: pT, respValues: pV,
        gravTimes: gT, gravValues: gV
    )

    guard grid.nEpochs > 0 else {
        return [StageSegment(start: start, end: end, stage: .light)]
    }

    // Cole–Kripke onset/final indices (already embedded in EpochGrid.ckSleep).
    let (onsetIdx, finalWakeIdx) = onsetAndFinalWake(grid.ckSleep)

    // Stage 1b: extract cardiorespiratory features.
    let hrVar = dogHRVariability(hrPerEpoch: grid.hr)
    let features = extractFeatures(grid: grid, hrVar: hrVar,
                                   onsetIdx: onsetIdx, finalWakeIdx: finalWakeIdx)

    // Stage 2: classify.
    var labels = classifyEpochs(features)

    // Stage 3: smooth + reimpose physiology.
    labels = smoothLabels(labels, window: 5)
    labels = reimposePhhysiology(labels, features: features,
                                  onsetIdx: onsetIdx, finalWakeIdx: finalWakeIdx)

    // Pre-onset and post-final-wake epochs are forced to wake.
    for i in 0..<labels.count where i < onsetIdx || i > finalWakeIdx {
        labels[i] = .wake
    }

    // Stage 3c: min bout-duration smoothing (LOCAL DIVERGENCE — see enforceMinBout).
    // Run after edge-forcing so the long pre-onset/post-wake blocks anchor the boundaries
    // and only short interior flips get absorbed.
    labels = enforceMinBout(labels)

    // Merge consecutive same-stage labels into StageSegments tiling [start, end].
    return segmentsFromLabels(labels, grid: grid, end: end)
}

/// Clip leading and trailing `.wake` segments so the session is anchored to its
/// Sleep Period Time (AASM: onset → final awakening).
///
/// Ports `_trim_to_sleep_period` from `sleep.py`.
///
/// Returns `[]` when there is no non-wake epoch at all (an all-wake run is not a
/// session). Threat T-03-15: if after trim the result is empty, the caller must
/// skip this run.
private func trimToSleepPeriod(_ stages: [StageSegment]) -> [StageSegment] {
    let sleepIndices = stages.enumerated().compactMap { (i, seg) in seg.stage != .wake ? i : nil }
    guard let first = sleepIndices.first, let last = sleepIndices.last else {
        return []
    }
    return Array(stages[first...last])
}

/// Merge consecutive same-stage epoch labels into `StageSegment` array.
///
/// Each epoch occupies `epochS` seconds starting at `grid.start + i * epochS`.
/// The last segment's `end` is snapped to `end` to match `_stage_session`'s
/// exact boundary behaviour.
private func segmentsFromLabels(_ labels: [SleepStage], grid: EpochGrid, end: Double) -> [StageSegment] {
    guard !labels.isEmpty else { return [] }
    var segments: [StageSegment] = []
    for (i, stage) in labels.enumerated() {
        let segStart = grid.start + Double(i) * epochS
        let segEnd   = grid.start + Double(i + 1) * epochS
        if let last = segments.last, last.stage == stage {
            // Extend the last segment (mutable trick via re-append).
            let extended = StageSegment(start: last.start, end: segEnd, stage: stage)
            segments[segments.count - 1] = extended
        } else {
            segments.append(StageSegment(start: segStart, end: segEnd, stage: stage))
        }
    }
    // Snap last segment's end to the exact run end.
    if !segments.isEmpty {
        let last = segments[segments.count - 1]
        segments[segments.count - 1] = StageSegment(start: last.start, end: end, stage: last.stage)
    }
    return segments
}

/// First persistent-sleep onset index and last sleep epoch index from CK flags.
///
/// Ports `_onset_and_final_wake` from `sleep.py`:
///   - Onset requires `ONSET_PERSIST_EPOCHS` (= 3) consecutive sleep epochs.
///   - Falls back to (0, n-1) when no clear onset / final exists.
private func onsetAndFinalWake(_ ckFlags: [Bool]) -> (onsetIdx: Int, finalWakeIdx: Int) {
    let n = ckFlags.count
    guard n > 0 else { return (0, 0) }

    // Find onset: first run of ONSET_PERSIST_EPOCHS consecutive sleep epochs.
    let persistEpochs = 3
    var onset: Int? = nil
    var run = 0
    for (i, s) in ckFlags.enumerated() {
        run = s ? run + 1 : 0
        if run >= persistEpochs {
            onset = i - persistEpochs + 1
            break
        }
    }

    // Find final: last sleep epoch.
    var final_: Int? = nil
    for i in stride(from: n - 1, through: 0, by: -1) {
        if ckFlags[i] { final_ = i; break }
    }

    let onsetIdx    = onset ?? 0
    var finalWakeIdx = final_ ?? (n - 1)
    if finalWakeIdx < onsetIdx { finalWakeIdx = n - 1 }
    return (onsetIdx, finalWakeIdx)
}

/// Slice a sorted (times, values) stream to the window `[start, end]` via binary search.
///
/// `includePrev` keeps one sample just before `start` so a downstream consecutive-delta
/// (|v[i]-v[i-1]|) on the first in-window sample stays exact; that out-of-range sample
/// maps to a nil epoch bucket and so contributes nothing else. The upper bound is inclusive
/// of `end` to match `epochIdx`'s inclusive-end (Piège 1) handling.
private func sliceStream(_ times: [Double], _ values: [Double],
                         _ start: Double, _ end: Double, includePrev: Bool) -> ([Double], [Double]) {
    guard !times.isEmpty else { return ([], []) }
    var lo = seLowerBound(times, start)
    if includePrev && lo > 0 { lo -= 1 }
    var hi = seLowerBound(times, end)
    while hi < times.count && times[hi] <= end { hi += 1 }
    guard lo < hi else { return ([], []) }
    return (Array(times[lo..<hi]), Array(values[lo..<hi]))
}

/// First index in sorted `times` whose value is ≥ `target` (binary lower bound).
private func seLowerBound(_ times: [Double], _ target: Double) -> Int {
    var lo = 0, hi = times.count
    while lo < hi {
        let mid = (lo + hi) / 2
        if times[mid] < target { lo = mid + 1 } else { hi = mid }
    }
    return lo
}

/// Lowest 5-min rolling-mean HR during a session (bpm); `nil` if no HR samples.
///
/// Ports `_session_resting_hr` from `sleep.py`.
///
/// Perf (P4): single forward pass over the binary-searched session slice with tumbling
/// 5-min windows aligned to `start`, instead of two full-array scans plus a per-window
/// re-filter. Same window definition (`[t, t+windowS)`) → identical result.
private func sessionRestingHR(start: Double, end: Double,
                               hrTimes: [Double], hrValues: [Double]) -> Double? {
    let windowS = 5.0 * 60.0  // _RESTING_HR_WINDOW_S = 5 min
    var i = seLowerBound(hrTimes, start)
    guard i < hrTimes.count && hrTimes[i] <= end else { return nil }

    var minMean = Double.infinity
    var sawWindow = false
    var allSum = 0.0, allCnt = 0
    var winStart = start, winSum = 0.0, winCnt = 0
    while i < hrTimes.count && hrTimes[i] <= end {
        let t = hrTimes[i]
        while t >= winStart + windowS {
            if winCnt > 0 { minMean = min(minMean, winSum / Double(winCnt)); sawWindow = true }
            winStart += windowS; winSum = 0; winCnt = 0
        }
        winSum += hrValues[i]; winCnt += 1
        allSum += hrValues[i]; allCnt += 1
        i += 1
    }
    if winCnt > 0 { minMean = min(minMean, winSum / Double(winCnt)); sawWindow = true }
    guard allCnt > 0 else { return nil }
    return sawWindow ? minMean : allSum / Double(allCnt)
}

/// Mean RMSSD over 5-min tumbling windows across the session (ms); `nil` if no RR.
///
/// Ports `_session_avg_hrv` from `sleep.py`. Perf (P4): single sorted pass instead of
/// a full-array scan plus per-window re-filter; same tumbling windows aligned to `start`.
private func sessionAvgRmssd(start: Double, end: Double,
                              rrTimes: [Double], rrValues: [Double]) -> Double? {
    let windowS = 5.0 * 60.0  // _HRV_WINDOW_S = 5 min
    var i = seLowerBound(rrTimes, start)
    guard i < rrTimes.count && rrTimes[i] <= end else { return nil }

    var vals: [Double] = []
    var winStart = start
    var bucket: [Double] = []
    func flush() {
        let r = rmssdMs(filterRR(bucket))
        if r.isFinite { vals.append(r) }
        bucket.removeAll(keepingCapacity: true)
    }
    while i < rrTimes.count && rrTimes[i] <= end {
        let t = rrTimes[i]
        while t >= winStart + windowS { flush(); winStart += windowS }
        bucket.append(rrValues[i]); i += 1
    }
    flush()
    guard !vals.isEmpty else { return nil }
    return vals.reduce(0.0, +) / Double(vals.count)
}

/// Calendar date string for a session's end under the caller's day-bucketing policy.
private func endDate(_ session: SleepSession, in timeZone: TimeZone) -> String {
    let date = Date(timeIntervalSince1970: session.end)
    let cal = Calendar(identifier: .gregorian)
    let comps = cal.dateComponents(in: timeZone, from: date)
    let year  = comps.year  ?? 1970
    let month = comps.month ?? 1
    let day   = comps.day   ?? 1
    return String(format: "%04d-%02d-%02d", year, month, day)
}

/// Total TST (seconds) across a cluster of sessions.
private func clusterTST(_ cluster: [SleepSession]) -> Double {
    cluster.reduce(0.0) { $0 + hypnogramMetrics($1.stages).tst }
}
