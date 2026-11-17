import Foundation

/// A measured value with its stable producer identity. Observations from different
/// metrics or producers must never share a personalized reference distribution.
public struct RecoveryObservation: Codable, Equatable, Sendable {
    public let value: Double
    public let sourceID: String
    /// Number of source samples represented by this observation; not independent nights.
    public let sampleCount: Int

    public init(value: Double, sourceID: String, sampleCount: Int) {
        self.value = value
        self.sourceID = sourceID
        self.sampleCount = sampleCount
    }

    fileprivate func isValid(for cfg: MetricCfg) -> Bool {
        value.isFinite && (cfg.minVal...cfg.maxVal).contains(value)
            && !sourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && sampleCount > 0
    }
}

// MARK: - DailyInputs

/// All inputs required to compute one day's metrics via `DailyEngine.compute()`.
///
/// Mirrors the data contract of `daily.py compute_day()`: streams and pre-computed
/// sleep outputs for a single day, plus the trailing HR history for HRmax estimation.
/// `DailyEngine` is a pure assembler — it never reads from GRDB directly.
public struct DailyInputs {
    /// UTC calendar date string in ISO-8601 format ("YYYY-MM-DD").
    public let date: String

    /// Aggregated AASM sleep summary for this day (from `SleepEngine.dailySleepSummary`).
    public let sleepSummary: DailySleepSummary

    /// Optional sleep session for sleep-score computation (the primary night session).
    /// `nil` when no sleep session was detected ending on this day.
    public let sleepSession: SleepSession?

    /// Time-ordered 1 Hz HR samples over the waking period (ts: Unix seconds, bpm).
    public let hrSeries: [(ts: Double, bpm: Double)]

    /// Time-ordered RR intervals (ts: Unix seconds, rrMs: milliseconds).
    /// `nil` when the band did not record RR data for this day.
    public let rrSeries: [(ts: Double, rrMs: Double)]?

    /// Time-ordered gravity magnitude samples (ts: Unix seconds, v: g).
    /// `nil` when gravity stream is unavailable.
    public let gravitySeries: [(ts: Double, v: Double)]?

    /// Anthropometric profile for calorie estimation. `nil` when not set.
    public let userProfile: UserProfile?

    /// Trailing ≈90 days of HR bpm values (any order) for personalized HRmax estimation.
    /// When empty, HRmax estimation falls back to age-predicted Tanaka or `nil`.
    public let hrHistory: [Double]

    /// Pre-computed HRmax (bpm) to use verbatim instead of estimating from `hrHistory`.
    /// When non-nil, `compute()` skips `estimateHRmax(hrHistory:)` entirely — the caller has
    /// already derived the 99.5-pctile pool max once and reuses it across days. This both
    /// removes a redundant 60× sort of the full HR pool and lets the incremental path skip
    /// re-reading the whole-range HR just for HRmax (see `LocalMetricsEngine.computeCore`).
    public let hrmaxOverride: Double?

    /// Strain difficulty multiplier. 1.0 = normal, <1.0 = easier, >1.0 = harder.
    /// `nil` uses the default (0.6).
    public let strainDifficulty: Double?

    /// Fenêtres temporelles (Unix s) à EXCLURE du calcul de strain — séances rejetées par
    /// l'utilisateur (faux positifs / HR aberrant). Le HR de ces créneaux est ignoré par le TRIMP,
    /// donc le strain du jour baisse. N'affecte QUE le strain (le HR reste intact ailleurs).
    public let strainExcludeRanges: [(start: Double, end: Double)]

    // ── Entrées Apple Santé (optionnelles, additives) ────────────────────────
    // Vides/nil = calcul strictement identique au flux bracelet seul.

    /// FC externe (Apple Watch / Apple Santé, hors écritures de Loop) du jour. N'alimente QUE le
    /// strain, et uniquement sur les secondes non couvertes par `hrSeries` (voir
    /// `mergeSupplementalHR`). N'entre ni dans HRmax, ni dans le stress, ni dans les baselines.
    public let supplementalHRSeries: [(ts: Double, bpm: Double)]

    /// External readings explicitly preferred to the band during recorded activities.
    /// Other external readings remain a fallback and never override the band.
    public let preferredHRSeries: [(ts: Double, bpm: Double)]
    public let preferredHRRanges: [(start: Double, end: Double)]

    /// FC de repos externe (bpm). Utilisée UNIQUEMENT comme dénominateur Karvonen du strain quand
    /// la nuit du bracelet n'a pas donné de FC repos. Jamais utilisée pour la récupération ni les
    /// baselines (appareil et méthode de mesure différents).
    public let supplementalRestingHR: Double?

    /// HealthKit SDNN and daily resting HR are kept separate from band RMSSD and
    /// nocturnal resting HR. The caller supplies one source and one comparable window.
    public let healthSDNN: RecoveryObservation?
    public let healthRestingHR: RecoveryObservation?
    /// Stable bracelet identity; prior data from another device cannot seed this baseline.
    public let bandSourceID: String

    public init(
        date: String,
        sleepSummary: DailySleepSummary,
        sleepSession: SleepSession? = nil,
        hrSeries: [(ts: Double, bpm: Double)],
        rrSeries: [(ts: Double, rrMs: Double)]? = nil,
        gravitySeries: [(ts: Double, v: Double)]? = nil,
        userProfile: UserProfile? = nil,
        hrHistory: [Double] = [],
        hrmaxOverride: Double? = nil,
        strainDifficulty: Double? = nil,
        strainExcludeRanges: [(start: Double, end: Double)] = [],
        supplementalHRSeries: [(ts: Double, bpm: Double)] = [],
        supplementalRestingHR: Double? = nil,
        preferredHRSeries: [(ts: Double, bpm: Double)] = [],
        preferredHRRanges: [(start: Double, end: Double)] = [],
        healthSDNN: RecoveryObservation? = nil,
        healthRestingHR: RecoveryObservation? = nil,
        bandSourceID: String = "band"
    ) {
        self.date = date
        self.sleepSummary = sleepSummary
        self.sleepSession = sleepSession
        self.hrSeries = hrSeries
        self.rrSeries = rrSeries
        self.gravitySeries = gravitySeries
        self.userProfile = userProfile
        self.hrHistory = hrHistory
        self.hrmaxOverride = hrmaxOverride
        self.strainDifficulty = strainDifficulty
        self.strainExcludeRanges = strainExcludeRanges
        self.supplementalHRSeries = supplementalHRSeries
        self.supplementalRestingHR = supplementalRestingHR
        self.preferredHRSeries = preferredHRSeries
        self.preferredHRRanges = preferredHRRanges
        self.healthSDNN = healthSDNN
        self.healthRestingHR = healthRestingHR
        self.bandSourceID = bandSourceID
    }
}

// MARK: - DailyResult

/// Assembled daily metrics for one calendar day.
///
/// Mirrors the `daily_metrics` row columns persisted by `daily.py compute_day()`,
/// restricted to fields covered by the Phase 6 modules. Fields not yet ported
/// (exercises, advice, spo2_pct, skin_temp_dev_c, resp_rate_bpm) are intentionally
/// excluded from this struct (per CONTEXT.md scope limits D-03).
public struct DailyResult {
    /// UTC calendar date string in ISO-8601 format ("YYYY-MM-DD").
    public let date: String

    // ── Sleep fields (from DailySleepSummary) ────────────────────────────────

    /// Total sleep time in minutes (light + deep + REM).
    public let totalSleepMin: Double?
    /// In-bed-weighted mean sleep efficiency (TST / TIB), 0..1.
    public let efficiency: Double?
    /// Deep sleep in minutes.
    public let deepMin: Double?
    /// REM sleep in minutes.
    public let remMin: Double?
    /// Light sleep in minutes.
    public let lightMin: Double?
    /// Post-onset wake disturbance count.
    public let disturbances: Int?
    /// Start timestamp (Unix s) of the primary sleep session; `nil` if no session.
    public let sleepStart: Double?
    /// End timestamp (Unix s) of the primary sleep session; `nil` if no session.
    public let sleepEnd: Double?

    // ── Nightly biometrics ────────────────────────────────────────────────────

    /// Resting heart rate (bpm) from the sleep session; `nil` if no HR data.
    public let restingHR: Double?
    /// Average nightly HRV (RMSSD, ms) from the sleep session; `nil` if no RR data.
    public let avgHrv: Double?

    // ── Recovery ──────────────────────────────────────────────────────────────

    /// Recovery score [0, 100]; `nil` during cold-start (HRV baseline not yet usable).
    public let recovery: Double?
    /// Recovery confidence tier: "low" (calibrating), "medium" (provisional/stale),
    /// "high" (trusted).
    public let recoveryStatus: String
    /// WHOOP-style color band: "red" < 34, "yellow" 34–67, "green" ≥ 67.
    /// `nil` when `recovery` is `nil` (cold-start).
    public let recoveryBand: String?
    /// Standardized contributing observations, with confidence and absent terms preserved.
    public let recoveryEvidence: RecoveryResult
    /// Selected inputs and metric identify the score's independent personal baselines.
    /// Raw Health observations are also returned for reconstructing incremental history.
    public let recoveryHRVMetric: String?
    public let recoveryHRVObservation: RecoveryObservation?
    public let recoveryRHRObservation: RecoveryObservation?
    public let healthSDNN: RecoveryObservation?
    public let healthRestingHR: RecoveryObservation?

    // ── Sleep score ───────────────────────────────────────────────────────────

    /// Sleep quality score [0, 100] from `sleepScore()`; `nil` if no sleep summary data.
    public let sleepScore: Double?

    // ── Strain ────────────────────────────────────────────────────────────────

    /// Cardiovascular strain on the 0–21 Banister TRIMP log-mapped scale.
    /// `nil` when HR data is insufficient (< 600 samples) or HRmax unavailable.
    public let strain: Double?
    /// Coverage and load components used to derive the daily cardiovascular score.
    public let strainEvidence: StrainResult?
    public let strainHRmaxUsed: Double?
    public let strainRestingHRUsed: Double?
}

// MARK: - DailyEngine

/// Orchestrates all Phase 6 Daily modules to assemble a `DailyResult` for one day.
///
/// `DailyEngine` is the single entry point for Phase 7 (offline cutover). It calls
/// each module in the same order as `daily.py compute_day()`:
///   1. `Baselines.foldHistory()` — recompute `BaselineState` from history
///   2. `Recovery.recoveryScore()` — z-score + logistic-squash recovery
///   3. `Strain.strain()` — Banister TRIMP log-mapped strain
///   4. `Stress.stressTimeline()` — per-bucket physiological stress (optional)
///   5. `Calories.estimateBoutCalories()` — Keytel/Harris-Benedict energy (optional)
///   6. `SleepScore.sleepScore()` — logistic sub-score composite (optional)
///
/// All `throws` calls use `try?` — the assembler never propagates errors from modules.
/// Callers receive `nil` fields when a module cannot compute (cold-start, missing data).
///
/// - Note: `DailyEngine` does NOT read from GRDB or make network calls. All inputs
///   must be pre-assembled by the caller from the device database (Phase 7).
public enum DailyEngine {

    /// Assemble a full `DailyResult` for `day` by orchestrating all Phase 6 modules.
    ///
    /// - Parameters:
    ///   - day: The day's inputs (streams, sleep summary, HR history, profile).
    ///   - history: Trailing ≈30 days of prior `DailyInputs` (oldest → newest).
    ///     Used to recompute `BaselineState` via `Baselines.foldHistory()`.
    ///   - baseline: Pre-computed HRV `BaselineState` passed for convenience; the
    ///     method also recomputes fresh baselines from `history` internally.
    /// - Returns: Fully assembled `DailyResult`.
    public static func compute(
        day: DailyInputs,
        history: [DailyInputs],
        baseline: BaselineState
    ) -> DailyResult {

        let summary = day.sleepSummary
        // Some HealthKit sources know total sleep without classifying all stages.
        // Partial stage totals must not become a complete hypnogram or a stage-based score.
        func hasCompleteStages(_ s: DailySleepSummary) -> Bool {
            guard s.totalSleepMin > 0 else { return false }
            let classified = s.deepMin + s.remMin + s.lightMin
            return abs(classified - s.totalSleepMin) <= 1.0 / 60.0
        }
        let stagesComplete = hasCompleteStages(summary)

        // ── 1. Recompute personal baselines from history ──────────────────────
        // Mirrors daily.py _build_baselines(): fold nightly HRV and RHR series
        // from the prior days' computed metrics.
        let hrvHistory: [Double?] = history.map { $0.bandSourceID == day.bandSourceID ? $0.sleepSummary.avgRmssd : nil }
        let rhrHistory: [Double?] = history.map { $0.bandSourceID == day.bandSourceID ? $0.sleepSummary.restingHR : nil }
        let durHistory: [Double?] = history.map {
            $0.sleepSummary.totalSleepMin > 0 ? $0.sleepSummary.totalSleepMin : nil
        }
        let deepPctHistory: [Double?] = history.map { h -> Double? in
            let total = h.sleepSummary.totalSleepMin
            guard total > 0, hasCompleteStages(h.sleepSummary) else { return nil }
            return h.sleepSummary.deepMin / total * 100.0
        }
        let remPctHistory: [Double?] = history.map { h -> Double? in
            let total = h.sleepSummary.totalSleepMin
            guard total > 0, hasCompleteStages(h.sleepSummary) else { return nil }
            return h.sleepSummary.remMin / total * 100.0
        }
        let lightPctHistory: [Double?] = history.map { h -> Double? in
            let total = h.sleepSummary.totalSleepMin
            guard total > 0, hasCompleteStages(h.sleepSummary) else { return nil }
            return h.sleepSummary.lightMin / total * 100.0
        }

        let hrvBaseline  = history.isEmpty ? baseline : foldHistory(hrvHistory, cfg: .hrv)
        let rhrBaseline  = foldHistory(rhrHistory,   cfg: .restingHR)
        let healthSDNN = day.healthSDNN.flatMap { $0.isValid(for: .hrv) ? $0 : nil }
        let healthRHR = day.healthRestingHR.flatMap { $0.isValid(for: .restingHR) ? $0 : nil }
        // Keep a slot for every calendar day. Removing missing days would make stale
        // observations look current and contaminate other devices' baselines.
        let healthHRVBaseline: BaselineState? = healthSDNN.map { current in
            foldHistory(history.map { previous in
                guard let sample = previous.healthSDNN, sample.sourceID == current.sourceID,
                      sample.isValid(for: .hrv) else { return nil }
                return sample.value
            }, cfg: .hrv)
        }
        let healthRHRBaseline: BaselineState? = healthRHR.map { current in
            foldHistory(history.map { previous in
                guard let sample = previous.healthRestingHR, sample.sourceID == current.sourceID,
                      sample.isValid(for: .restingHR) else { return nil }
                return sample.value
            }, cfg: .restingHR)
        }
        let durBaseline  = foldHistory(durHistory,   cfg: .sleepDuration)
        let deepBaseline = foldHistory(deepPctHistory, cfg: .deepPct)
        let remBaseline  = foldHistory(remPctHistory,  cfg: .remPct)
        let lightBaseline = foldHistory(lightPctHistory, cfg: .lightPct)

        let stageBaselines: [String: BaselineState] = [
            "deep_pct":  deepBaseline,
            "rem_pct":   remBaseline,
            "light_pct": lightBaseline,
        ]

        // ── 2. Extract tonight's biometrics from the sleep summary ────────────
        let restingHR = summary.restingHR.flatMap {
            (MetricCfg.restingHR.minVal...MetricCfg.restingHR.maxVal).contains($0) ? $0 : nil
        }
        let avgHrv = summary.avgRmssd.flatMap {
            (MetricCfg.hrv.minVal...MetricCfg.hrv.maxVal).contains($0) ? $0 : nil
        }

        // ── 3. Recovery score ─────────────────────────────────────────────────
        // Missing or invalid measurements must never be interpreted as zero: doing so
        // produces a plausible-looking but misleading recovery score.
        let rhrVal = restingHR ?? 0.0
        let sleepPerf: Double? = summary.totalSleepMin > 0 && summary.efficiency > 0 && summary.efficiency <= 1 ? summary.efficiency : nil
        let bandHRV = avgHrv.map { RecoveryObservation(value: $0, sourceID: "\(day.bandSourceID).rmssd", sampleCount: 1) }
        let bandRHR = restingHR.map { RecoveryObservation(value: $0, sourceID: "\(day.bandSourceID).nightly-rhr", sampleCount: 1) }
        let selectedHRV: (metric: String, observation: RecoveryObservation, baseline: BaselineState)? = {
            if let bandHRV, hrvBaseline.usable { return ("rmssd", bandHRV, hrvBaseline) }
            if let healthSDNN, let healthHRVBaseline, healthHRVBaseline.usable { return ("sdnn", healthSDNN, healthHRVBaseline) }
            if let bandHRV { return ("rmssd", bandHRV, hrvBaseline) }
            if let healthSDNN, let healthHRVBaseline { return ("sdnn", healthSDNN, healthHRVBaseline) }
            return nil
        }()
        let selectedRHR: (observation: RecoveryObservation, baseline: BaselineState)? = {
            if let bandRHR, rhrBaseline.usable { return (bandRHR, rhrBaseline) }
            if let healthRHR, let healthRHRBaseline, healthRHRBaseline.usable { return (healthRHR, healthRHRBaseline) }
            if let bandRHR { return (bandRHR, rhrBaseline) }
            if let healthRHR, let healthRHRBaseline { return (healthRHR, healthRHRBaseline) }
            return nil
        }()
        let recoveryResult: RecoveryResult
        if let hrv = selectedHRV, let rhr = selectedRHR {
            let result = recoveryScore(hrv: hrv.observation.value, rhr: rhr.observation.value,
                resp: nil, sleepPerf: sleepPerf, hrvBaseline: hrv.baseline,
                rhrBaseline: rhr.baseline, respBaseline: nil)
            // SDNN and external nightly-median HR are experimental proxies, not
            // interchangeable with the band's measurements or clinically validated.
            recoveryResult = (hrv.metric == "sdnn" || rhr.observation.sourceID != "\(day.bandSourceID).nightly-rhr") && result.confidence == "high"
                ? RecoveryResult(score: result.score, band: result.band, confidence: "medium",
                                 zHrv: result.zHrv, zRhr: result.zRhr, zResp: result.zResp)
                : result
        } else {
            recoveryResult = RecoveryResult(score: nil, band: nil, confidence: "low",
                                            zHrv: nil, zRhr: nil, zResp: nil)
        }

        // ── 4. Strain ─────────────────────────────────────────────────────────
        // Estimate HRmax from the trailing HR history, then compute Edwards TRIMP
        // with user-configurable difficulty multiplier.
        let age = day.userProfile.map { $0.ageYears }
        let hrmaxOpt = day.hrmaxOverride ?? estimateHRmax(hrHistory: day.hrHistory, age: age)
        let sex = day.userProfile?.sex ?? .male
        // Exclut les créneaux rejetés du strain : on retire les échantillons HR tombant dans une
        // fenêtre d'exclusion avant le TRIMP. N'impacte que le strain (hrSeries reste intact pour
        // le reste du calcul).
        // FC Apple Santé : comble seulement les secondes sans bracelet (pas de double comptage).
        // Sans FC externe, `baseHR` EST `day.hrSeries` (même tableau, même ordre).
        let baseHR: [(ts: Double, bpm: Double)] = !day.preferredHRSeries.isEmpty && !day.preferredHRRanges.isEmpty
            ? mergePrioritizedHR(band: day.hrSeries, supplemental: day.supplementalHRSeries,
                                 preferred: day.preferredHRSeries, preferredRanges: day.preferredHRRanges)
            : day.supplementalHRSeries.isEmpty
            ? day.hrSeries
            : mergeSupplementalHR(band: day.hrSeries, supplemental: day.supplementalHRSeries)
        // Les exclusions s'appliquent APRÈS la fusion : une séance rejetée l'est pour toutes les sources.
        let strainHR: [(ts: Double, bpm: Double)] = day.strainExcludeRanges.isEmpty
            ? baseHR
            : baseHR.filter { s in !day.strainExcludeRanges.contains { s.ts >= $0.start && s.ts <= $0.end } }
        // FC repos du strain : celle de la nuit du bracelet ; à défaut, celle d'Apple Santé.
        let strainRHR: Double = {
            if rhrVal > 0 { return rhrVal }
            if let ext = day.supplementalRestingHR, ext.isFinite, ext > 0 { return ext }
            return rhrVal
        }()
        var strainEvidence: StrainResult? = nil
        if let hrmax = hrmaxOpt, strainRHR > 0, !strainHR.isEmpty {
            strainEvidence = try? strain(
                hrSeries: strainHR,
                restingHR: strainRHR,
                hrmaxEstimate: hrmax,
                sex: sex,
                difficulty: day.strainDifficulty
            )
        }

        // ── 5. Stress timeline (optional — requires rrSeries + gravitySeries) ─
        // Result not included in DailyResult fields (out of DailyResult scope),
        // but computed here following daily.py's pipeline order to maintain parity.
        // (Stress fields are deferred to a later DailyResult extension if needed.)
        _ = { () -> StressResult? in
            guard let rr = day.rrSeries, let grav = day.gravitySeries,
                  !day.hrSeries.isEmpty else { return nil }
            return try? stressTimeline(
                hrSeries: day.hrSeries,
                rrSeries: rr,
                gravitySeries: grav
            )
        }()

        // ── 6. Calories (optional — requires userProfile) ─────────────────────
        // Result not included in DailyResult fields (out of DailyResult scope).
        // Computed following pipeline order.
        _ = { () -> CaloriesResult? in
            guard let profile = day.userProfile, !day.hrSeries.isEmpty else { return nil }
            return estimateBoutCalories(hrSeries: day.hrSeries, profile: profile)
        }()

        // ── 7. Sleep score ────────────────────────────────────────────────────
        let sleepScoreVal = personalizedSleepScore(summary: summary,
                                                    durationBaseline: durBaseline.usable ? durBaseline : nil,
                                                    stageBaselines: stageBaselines)?.score

        // ── 8. Assemble DailyResult ───────────────────────────────────────────
        return DailyResult(
            date: day.date,
            totalSleepMin: summary.totalSleepMin > 0 ? summary.totalSleepMin : nil,
            efficiency: summary.efficiency > 0 ? summary.efficiency : nil,
            deepMin: stagesComplete ? summary.deepMin : nil,
            remMin: stagesComplete ? summary.remMin : nil,
            lightMin: stagesComplete ? summary.lightMin : nil,
            disturbances: summary.disturbances,
            sleepStart: summary.sleepStart,
            sleepEnd: summary.sleepEnd,
            restingHR: restingHR,
            avgHrv: avgHrv,
            recovery: recoveryResult.score,
            recoveryStatus: recoveryResult.confidence,
            recoveryBand: recoveryResult.band,
            recoveryEvidence: recoveryResult,
            recoveryHRVMetric: selectedHRV?.metric,
            recoveryHRVObservation: selectedHRV?.observation,
            recoveryRHRObservation: selectedRHR?.observation,
            healthSDNN: healthSDNN,
            healthRestingHR: healthRHR,
            sleepScore: sleepScoreVal,
            strain: strainEvidence?.strain,
            strainEvidence: strainEvidence,
            strainHRmaxUsed: strainEvidence == nil ? nil : hrmaxOpt,
            strainRestingHRUsed: strainEvidence == nil ? nil : strainRHR
        )
    }
}
