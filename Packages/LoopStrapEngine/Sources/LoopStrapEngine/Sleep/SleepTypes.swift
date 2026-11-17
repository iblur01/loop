// MARK: - Sleep domain types

// Module-level constants — mirrors sleep.py / sleep_features.py named thresholds.
// These are public so downstream plans (SLEEP-02..04) can reference them directly.

/// Duration of one sleep epoch in seconds. AASM / Walch / sleepecg all use 30 s.
public let epochS: Double = 30.0

/// HRV/respiration feature stride: compute expensive features every N epochs and
/// forward-fill to epochs in between. 4 epochs = 2 min stride.
public let hrvStrideEpochs: Int = 4

/// Per-sample gravity-vector L2 change (g) at/above which a sample is "moving".
/// Mirrors sleep_features.MOVE_DELTA_THRESHOLD_G = 0.013 (note: Python uses 0.01
/// for the stillness spine threshold and 0.013 is used in classifier move gates).
/// Used by EpochGrid bucketing and InBedDetection classifier gates.
public let gravThreshold: Double = 0.013

/// Move-fraction at/below which an epoch is classified as "still" (deep/REM candidate).
/// Mirrors sleep_features.STAGE_STILL_MOVE_FRAC = 0.10.
public let moveFracStillMax: Double = 0.10

/// Move-fraction at/above which an epoch is classified as "moving" (wake candidate).
/// Mirrors sleep_features.STAGE_WAKE_MOVE_FRAC = 0.15.
public let moveFracMovingMin: Double = 0.15

/// Minimum bout duration per stage, in epochs (Stage 3c — `enforceMinBout`).
///
/// **LOCAL DIVERGENCE** from the Python oracle: there is no equivalent step server-side.
/// Accepted under the local-first principle (the on-device engine is the source of truth).
///
/// Real sleep stages occur in multi-minute bouts. The 30 s epoch classifier + 5-epoch
/// majority window still leaves short, implausible runs that make the hypnogram look
/// noisy (rapid deep↔light↔rem↔wake flips). Any run shorter than its stage's threshold
/// is absorbed into the dominant neighbour. Deep/REM bouts are physiologically longer,
/// so they get a higher floor; wake keeps a low floor so brief real awakenings (WASO)
/// survive. Tune these to trade hypnogram smoothness against stage granularity.
public let minBoutEpochs: [SleepStage: Int] = [
    .deep:  10,  // 5 min
    .rem:   10,  // 5 min
    .light: 6,   // 3 min
    .wake:  4    // 2 min
]


// MARK: - SleepStage

/// The four sleep stages produced by the staging classifier.
///
/// `rawValue` strings match exactly the Python oracle labels: "wake", "light",
/// "deep", "rem" — used for JSON serialisation / fixture comparison.
public enum SleepStage: String, Codable, Equatable, CaseIterable, Sendable {
    case wake  = "wake"
    case light = "light"
    case deep  = "deep"
    case rem   = "rem"
}


// MARK: - EpochGrid

/// A fixed 30 s epoch grid over [start, end) with the four raw streams bucketed.
///
/// Built by `buildEpochGrid`. The per-stream arrays are aligned to epoch index
/// (index 0 = epoch [start, start+30s), etc.).
///
/// - `counts`: rescaled Cole–Kripke activity count per epoch.
/// - `moveFrac`: scale-robust fraction of gravity samples above the still threshold.
/// - `ckSleep`: per-epoch sleep flag from `coleKripke`.
/// - `hr`: per-epoch mean HR (bpm); `Double.nan` if no samples in that epoch.
/// - `rrBuckets`: per-epoch list of raw RR intervals (ms).
/// - `respBuckets`: per-epoch list of raw respiration samples.
public struct EpochGrid {
    public let start: Double
    public let end: Double
    public let nEpochs: Int
    /// Rescaled activity count per epoch (feeds Cole–Kripke; pre-divided by 100, clipped to 300).
    public let counts: [Double]
    /// Fraction of gravity samples above `MOVE_DELTA_THRESHOLD_G` per epoch.
    public let moveFrac: [Double]
    /// Per-epoch sleep/wake flag from Cole–Kripke (true = sleep).
    public let ckSleep: [Bool]
    /// Per-epoch mean HR in bpm; `.nan` when no HR samples fall in the epoch.
    public let hr: [Double]
    /// Per-epoch raw RR intervals in milliseconds.
    public let rrBuckets: [[Double]]
    /// Per-epoch raw respiration samples.
    public let respBuckets: [[Double]]
}


// MARK: - EpochFeatures

/// Per-epoch cardiorespiratory features extracted over a rolling 5-min window.
///
/// Mirrors `sleep_features.EpochFeatures`. Frequency-domain fields (`hf`, `lf`,
/// `lfhf`) are always `.nan` in Phase 3 per decision D-01; Phase 5 extends
/// `hrvFromRR` to fill them via Welch PSD.
public struct EpochFeatures {
    /// Zero-based index of this epoch in the grid.
    public let epochIdx: Int
    /// Mean HR (bpm) for this epoch; `.nan` if no HR samples.
    public let hr: Double
    /// Walch DoG HR-variability (local std of DoG-filtered HR); `.nan` if insufficient HR.
    public let hrVar: Double
    /// RMSSD in ms over the 5-min window; `.nan` if < 5 plausible RR intervals.
    public let rmssd: Double
    /// SDNN in ms over the 5-min window; `.nan` if < 5 plausible RR intervals.
    public let sdnn: Double
    /// HF power (ms²) — always `.nan` in Phase 3 (D-01; filled by Phase 5 Welch PSD).
    public let hf: Double
    /// LF power (ms²) — always `.nan` in Phase 3 (D-01; filled by Phase 5 Welch PSD).
    public let lf: Double
    /// LF/HF ratio — always `.nan` in Phase 3 (D-01; filled by Phase 5 Welch PSD).
    public let lfhf: Double
    /// Respiratory rate in breaths/min; `.nan` if no clear breathing rhythm.
    public let respRate: Double
    /// Respiratory rate variability (std of breath-to-breath intervals, s); `.nan` if insufficient resp.
    public let rrv: Double
    /// Fraction of gravity samples above the still threshold in this epoch.
    public let moveFrac: Double
    /// Cole–Kripke sleep flag for this epoch (true = sleep).
    public let ckSleep: Bool
    /// Normalized time since sleep onset within the sleep period [0, 1].
    ///
    /// `clock = (epochIdx - onsetIdx) / max(1, finalWakeIdx - onsetIdx)`, clamped to [0, 1].
    /// Used by `reimposePhhysiology` to apply the deep-late downgrade rule (`DEEP_LATE_FRACTION = 0.95`).
    /// Mirrors `sleep_features.EpochFeatures.clock`.
    public let clock: Double
}


// MARK: - StageSegment

/// A contiguous sleep-stage segment within a session.
///
/// `start` and `end` are Unix epoch seconds. `stage` is one of the four
/// sleep stages; "wake" segments represent WASO or SOL within the SPT.
public struct StageSegment: Equatable, Sendable {
    public let start: Double
    public let end: Double
    public let stage: SleepStage

    public init(start: Double, end: Double, stage: SleepStage) {
        self.start = start
        self.end = end
        self.stage = stage
    }
}


// MARK: - SleepSession

/// A detected sleep session anchored to its Sleep Period Time (onset → final awakening).
///
/// `start`/`end` are SPT bounds: leading SOL wake and trailing post-wake segments are
/// trimmed by `_trimToSleepPeriod`, so the span begins at sleep onset.
///
/// `efficiency` = TST / (end - start) in [0, 1].
public struct SleepSession: Sendable {
    public let start: Double
    public let end: Double
    public let stages: [StageSegment]
    /// TST / SPT in [0, 1].
    public let efficiency: Double
    /// Total sleep time in minutes (sum of non-wake stage durations).
    public let tst: Double
    /// Sleep-onset latency in minutes (time from first in-bed sample to first sleep epoch).
    public let sol: Double
    /// Wake-after-sleep-onset in minutes (sum of "wake" stage durations after onset).
    public let waso: Double
    /// Lowest 5-min rolling-mean HR during the session (bpm); `.nan` if insufficient HR.
    public let restingHR: Double
    /// Mean RMSSD across 5-min windows during the session (ms); `.nan` if insufficient RR.
    public let avgRmssd: Double
    /// Number of post-onset wake segments (disturbances).
    public let nDisturbances: Int
}


// MARK: - SleepStreams

/// The four raw sensor streams fed into the sleep pipeline.
///
/// Each tuple array contains `(t: Double, v: Double)` pairs where `t` is a Unix
/// timestamp (epoch seconds) and `v` is the stream-specific value:
/// - `hr`: HR in bpm
/// - `rr`: RR interval in ms
/// - `resp`: raw respiration signal (a.u.)
/// - `gravity`: L2 magnitude of the gravity vector (g); or pre-computed per-sample delta
///
/// Any stream may be empty — the pipeline degrades gracefully.
public struct SleepStreams: Sendable {
    public let hr: [(t: Double, v: Double)]
    public let rr: [(t: Double, v: Double)]
    public let resp: [(t: Double, v: Double)]
    public let gravity: [(t: Double, v: Double)]

    public init(
        hr: [(t: Double, v: Double)],
        rr: [(t: Double, v: Double)],
        resp: [(t: Double, v: Double)],
        gravity: [(t: Double, v: Double)]
    ) {
        self.hr = hr
        self.rr = rr
        self.resp = resp
        self.gravity = gravity
    }
}
