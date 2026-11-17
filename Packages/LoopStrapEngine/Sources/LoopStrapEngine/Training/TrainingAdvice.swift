import Foundation

// MARK: - Insight types

public enum TrainingInsightState: String, Codable, Sendable, Hashable {
    case ok
    case insufficientData
    case contradictory
}

/// A number cited by an insight. `value` is expressed in the display unit; `decimals`
/// fixes how it is rendered, so the rendered text and the fact always agree.
public struct TrainingFact: Codable, Equatable, Sendable {
    public let key: String
    public let value: Double
    public let decimals: Int
    public let unit: String

    public init(key: String, value: Double, decimals: Int = 0, unit: String = "") {
        self.key = key
        self.value = value
        self.decimals = decimals
        self.unit = unit
    }

    /// French rendering (decimal comma) of the value, rounded to `decimals`.
    public var formatted: String {
        let d = max(0, decimals)
        let text = String(format: "%.\(d)f", value)
        return text.replacingOccurrences(of: ".", with: ",")
    }
}

/// One deterministic, explainable insight.
public struct TrainingInsight: Codable, Equatable, Sendable, Identifiable {
    /// Stable code, e.g. `TRAINING_LOAD_RATIO`.
    public let code: String
    public let state: TrainingInsightState
    public let confidence: TrainingConfidence
    /// Every number the texts may cite.
    public let facts: [TrainingFact]
    /// Stable identifiers of the factors that contributed to the insight.
    public let contributors: [String]
    /// Localisation keys. Placeholders `{fact_key}` are filled from `facts`.
    public let shortKey: String
    public let detailKey: String
    /// Extra sentences appended to the detail text, in order.
    public let detailNoteKeys: [String]
    /// True when the insight relies on an experimental score.
    public let isExperimental: Bool

    public var id: String { code }

    public func fact(_ key: String) -> TrainingFact? {
        facts.first { $0.key == key }
    }
}

public enum TrainingInsightCode {
    public static let loadRatio = "TRAINING_LOAD_RATIO"
    public static let monotony = "TRAINING_MONOTONY"
    public static let regularity = "TRAINING_REGULARITY"
    public static let sleepTrend = "TRAINING_SLEEP_TREND"
    public static let sleepRecoveryConflict = "TRAINING_SLEEP_RECOVERY_CONFLICT"
    public static let feelingRecoveryConflict = "TRAINING_FEELING_RECOVERY_CONFLICT"
    public static let volumeRun = "TRAINING_VOLUME_RUN"
    public static let volumeSwim = "TRAINING_VOLUME_SWIM"
    public static let volumeStrength = "TRAINING_VOLUME_STRENGTH"
    public static let changeLoad = "TRAINING_CHANGE_LOAD"
    public static let changeSleep = "TRAINING_CHANGE_SLEEP"
    public static let changeRecovery = "TRAINING_CHANGE_RECOVERY"
    public static let linkLoadSleep = "TRAINING_LINK_LOAD_SLEEP"
    public static let linkLoadRecovery = "TRAINING_LINK_LOAD_RECOVERY"
    public static let linkSleepRecovery = "TRAINING_LINK_SLEEP_RECOVERY"
    public static let linkEfficiencyRecovery = "TRAINING_LINK_EFFICIENCY_RECOVERY"
}

// MARK: - Engine

/// Deterministic rules turning `TrainingStatsReport` into `TrainingInsight`s.
/// No recommendation is ever categorical about an experimental score, and nothing
/// here is a diagnosis or a medical statement.
public enum TrainingAdviceEngine {
    // Thresholds ([ASSUMED], tunable, not validated on personal data).
    public static let ratioHigh = 1.5
    public static let ratioRising = 1.3
    public static let ratioLow = 0.8
    public static let monotonyHigh = 2.0
    public static let volumeUpFactor = 1.3
    public static let volumeDownFactor = 0.7
    public static let recoveryRedMax = 34.0
    public static let recoveryGreenMin = 67.0
    public static let lowSleepCoverage = 0.7
    public static let volumeRequiredTrackedDays = 28
    public static let linkMinimumAbsRho = 0.3

    public static func insights(for inputs: TrainingInputs) -> [TrainingInsight] {
        let data = TrainingDataset(inputs)
        return insights(data: data, report: TrainingStats.compute(data))
    }

    /// Variant reusing an already computed report. `report` must come from the same `inputs`.
    public static func insights(for inputs: TrainingInputs, report: TrainingStatsReport) -> [TrainingInsight] {
        insights(data: TrainingDataset(inputs), report: report)
    }

    static func insights(data: TrainingDataset, report: TrainingStatsReport) -> [TrainingInsight] {
        var out: [TrainingInsight] = []
        let candidates: [TrainingInsight?] = [
            loadRatio(data, report),
            monotony(data, report),
            regularity(data, report),
            sleepTrend(data, report),
            sleepRecoveryConflict(data),
            feelingRecoveryConflict(data),
            volume(.run, data, code: TrainingInsightCode.volumeRun),
            volume(.swim, data, code: TrainingInsightCode.volumeSwim),
            volume(.strength, data, code: TrainingInsightCode.volumeStrength),
            change(.cardioLoad, report, code: TrainingInsightCode.changeLoad, name: "load", data: data),
            change(.sleepDuration, report, code: TrainingInsightCode.changeSleep, name: "sleep", data: data),
            change(.recoveryScore, report, code: TrainingInsightCode.changeRecovery, name: "recovery", data: data)
        ]
        out.append(contentsOf: candidates.compactMap { $0 })
        out.append(contentsOf: TrainingLinkPair.allCases.compactMap { link($0, report, data) })
        return out
    }

    // MARK: Helpers

    private static func fact(_ key: String, _ value: Double, _ decimals: Int = 0, _ unit: String = "") -> TrainingFact {
        TrainingFact(key: key, value: value, decimals: decimals, unit: unit)
    }

    private static func insight(_ code: String, _ state: TrainingInsightState, _ confidence: TrainingConfidence,
                                facts: [TrainingFact], contributors: [String], variant: String,
                                notes: [String] = [], experimental: Bool = false) -> TrainingInsight {
        TrainingInsight(code: code, state: state, confidence: confidence, facts: facts,
                        contributors: contributors,
                        shortKey: "training.\(variant).short", detailKey: "training.\(variant).detail",
                        detailNoteKeys: notes, isExperimental: experimental)
    }

    private static func latestRecovery(_ data: TrainingDataset, withinDays days: Int) -> TrainingRecoveryDay? {
        data.recovery.filter { $0.key > data.asOfDay - days && $0.value.score != nil }
            .max { $0.key < $1.key }?.value
    }

    // MARK: Load ratio

    private static func loadRatio(_ data: TrainingDataset, _ report: TrainingStatsReport) -> TrainingInsight? {
        let load = report.load
        let code = TrainingInsightCode.loadRatio
        let contributors = ["acute_ewma_7d", "chronic_ewma_28d"]
        switch load.status {
        case .noData:
            return nil
        case .noRecentData:
            return insight(code, .insufficientData, .low,
                           facts: [fact("days_since_last", Double(load.daysSinceLastLoad ?? 0), 0, "j"),
                                   fact("acute_days", Double(LoadStats.acuteDays), 0, "j")],
                           contributors: ["recent_load_missing"], variant: "load_ratio.norecent")
        case .calibration:
            return insight(code, .insufficientData, .low,
                           facts: [fact("data_days", Double(load.dataDays), 0, "j"),
                                   fact("required_days", Double(LoadStats.requiredDays), 0, "j"),
                                   fact("chronic_days", Double(LoadStats.chronicDays), 0, "j")],
                           contributors: ["calibration"], variant: "load_ratio.calibration")
        case .chronicNearZero:
            return insight(code, .insufficientData, .low,
                           facts: [fact("chronic", load.chronicEWMA ?? 0, 1)],
                           contributors: ["chronic_ewma_28d"], variant: "load_ratio.unavailable")
        case .available:
            guard let ratio = load.ratio, let acute = load.acuteEWMA, let chronic = load.chronicEWMA else { return nil }
            let variant: String
            if ratio >= ratioHigh { variant = "high" }
            else if ratio >= ratioRising { variant = "rising" }
            else if ratio >= ratioLow { variant = "stable" }
            else { variant = "low" }
            var confidence: TrainingConfidence = load.dataDays >= LoadStats.chronicDays ? .high : .medium
            var notes: [String] = []
            var facts = [fact("acute", acute, 1), fact("chronic", chronic, 1), fact("ratio", ratio, 2),
                         fact("data_days", Double(load.dataDays), 0, "j"),
                         fact("acute_days", Double(LoadStats.acuteDays), 0, "j"),
                         fact("chronic_days", Double(LoadStats.chronicDays), 0, "j")]
            var contrib = contributors
            if let share = load.lowConfidenceShare, share >= 0.5 {
                confidence = .low
                notes.append("training.note.low_confidence_inputs")
                facts.append(fact("low_confidence_pct", (share * 100).rounded(), 0, "%"))
                contrib.append("low_confidence_inputs")
            }
            return insight(code, .ok, confidence, facts: facts, contributors: contrib,
                           variant: "load_ratio.\(variant)", notes: notes)
        }
    }

    // MARK: Monotony

    private static func monotony(_ data: TrainingDataset, _ report: TrainingStatsReport) -> TrainingInsight? {
        let m = report.monotony
        let code = TrainingInsightCode.monotony
        guard m.knownDays > 0 else { return nil }
        let window = fact("window_days", Double(MonotonyStats.windowDays), 0, "j")
        switch m.status {
        case .insufficientData:
            return insight(code, .insufficientData, .low,
                           facts: [fact("known_days", Double(m.knownDays), 0, "j"),
                                   fact("required_days", Double(MonotonyStats.minimumKnownDays), 0, "j"), window],
                           contributors: ["daily_load_coverage"], variant: "monotony.insufficient")
        case .undefined:
            return insight(code, .insufficientData, .low,
                           facts: [fact("known_days", Double(m.knownDays), 0, "j"), window],
                           contributors: ["daily_load_constant"], variant: "monotony.undefined")
        case .ok:
            guard let mono = m.monotony else { return nil }
            var facts = [fact("monotony", mono, 2), fact("threshold", monotonyHigh, 1),
                         fact("known_days", Double(m.knownDays), 0, "j"), window]
            if let cv = m.coefficientOfVariation { facts.append(fact("cv_pct", cv * 100, 0, "%")) }
            let confidence: TrainingConfidence = m.knownDays >= MonotonyStats.windowDays ? .high : .medium
            return insight(code, .ok, confidence, facts: facts,
                           contributors: ["daily_load_mean", "daily_load_dispersion"],
                           variant: mono >= monotonyHigh ? "monotony.high" : "monotony.normal")
        }
    }

    // MARK: Regularity

    private static func regularity(_ data: TrainingDataset, _ report: TrainingStatsReport) -> TrainingInsight? {
        let r = report.regularity
        let code = TrainingInsightCode.regularity
        guard !data.sessions.isEmpty else { return nil }
        if r.status == .insufficientData {
            return insight(code, .insufficientData, .low,
                           facts: [fact("tracked_days", Double(r.trackedDays), 0, "j"),
                                   fact("required_days", Double(TrainingStats.regularityMinimumTrackedDays), 0, "j")],
                           contributors: ["history_length"], variant: "regularity.insufficient")
        }
        var facts = [fact("active_days", Double(r.activeDays), 0, "j"),
                     fact("tracked_days", Double(r.trackedDays), 0, "j")]
        if let last = r.daysSinceLastSession { facts.append(fact("days_since_last", Double(last), 0, "j")) }
        let variant: String
        if r.activeDays == 0 {
            variant = "none"
        } else if let maxGap = r.maxInterval {
            facts.append(fact("max_gap_days", Double(maxGap), 0, "j"))
            variant = "ok"
        } else {
            variant = "single"
        }
        let confidence: TrainingConfidence = r.trackedDays >= TrainingStats.regularityWindowDays ? .high : .medium
        return insight(code, .ok, confidence, facts: facts,
                       contributors: ["active_days", "session_spacing"], variant: "regularity.\(variant)")
    }

    // MARK: Sleep trend

    private static func sleepTrend(_ data: TrainingDataset, _ report: TrainingStatsReport) -> TrainingInsight? {
        guard !data.sleep.isEmpty, let t = report.trend(.sleepDuration) else { return nil }
        let code = TrainingInsightCode.sleepTrend
        guard t.status == .ok, let recent = t.recentMedian, let center = t.referenceCenter,
              let delta = t.delta, let dev = t.deltaInMAD, let dir = t.direction else {
            return insight(code, .insufficientData, .low,
                           facts: [fact("recent_n", Double(t.recentCount), 0),
                                   fact("required_recent", 3, 0),
                                   fact("reference_n", Double(t.referenceCount), 0),
                                   fact("required_reference", 10, 0)],
                           contributors: ["sleep_duration"], variant: "sleep_trend.insufficient")
        }
        var facts = [fact("sleep_recent_h", recent / 60, 1, "h"), fact("sleep_reference_h", center / 60, 1, "h"),
                     fact("sleep_delta_h", abs(delta) / 60, 1, "h"), fact("delta_mad", abs(dev), 1),
                     fact("recent_days", Double(t.recentDays), 0, "j"),
                     fact("reference_days", Double(t.referenceDays), 0, "j"),
                     fact("recent_n", Double(t.recentCount), 0), fact("reference_n", Double(t.referenceCount), 0)]
        var confidence = t.confidence
        var notes: [String] = []
        var contributors = ["sleep_duration_median", "personal_reference"]
        if let cov = report.sleep.medianCoverage, cov < lowSleepCoverage {
            confidence = .low
            notes.append("training.note.sleep_low_coverage")
            facts.append(fact("sleep_coverage_pct", (cov * 100).rounded(), 0, "%"))
            contributors.append("low_sleep_coverage")
        }
        return insight(code, .ok, confidence, facts: facts, contributors: contributors,
                       variant: "sleep_trend.\(dir.rawValue)", notes: notes)
    }

    // MARK: Contradictions

    private static func sleepRecoveryConflict(_ data: TrainingDataset) -> TrainingInsight? {
        guard let rec = latestRecovery(data, withinDays: 2), let score = rec.score else { return nil }
        let t = TrainingStats.trend(metric: .sleepDuration, series: data.series(.sleepDuration),
                                    asOfDay: data.asOfDay, recentDays: 2, referenceDays: 28,
                                    minRecent: 1, minReference: 10,
                                    reference: data.references.sleepDuration)
        guard t.status == .ok, let last = t.recentMedian, let center = t.referenceCenter,
              let delta = t.delta, let dev = t.deltaInMAD else { return nil }
        let variant: String
        if dev <= -TrainingStats.notableDeviationMAD && score >= recoveryGreenMin {
            variant = "sleep_low_recovery_high"
        } else if dev > -TrainingStats.notableDeviationMAD && score < recoveryRedMax {
            variant = "sleep_ok_recovery_low"
        } else {
            return nil
        }
        var confidence = TrainingConfidence.capped(t.confidence, at: .medium)
        confidence = TrainingConfidence.capped(confidence, at: rec.confidence ?? .low)
        var notes: [String] = []
        if rec.isExperimental { notes.append("training.note.experimental_recovery") }
        return insight(TrainingInsightCode.sleepRecoveryConflict, .contradictory, confidence,
                       facts: [fact("sleep_last_h", last / 60, 1, "h"), fact("sleep_reference_h", center / 60, 1, "h"),
                               fact("sleep_delta_h", abs(delta) / 60, 1, "h"), fact("delta_mad", abs(dev), 1),
                               fact("recovery_score", score, 0)],
                       contributors: ["sleep_duration_vs_personal_reference", "recovery_score"],
                       variant: "conflict.\(variant)", notes: notes, experimental: rec.isExperimental)
    }

    private static func feelingRecoveryConflict(_ data: TrainingDataset) -> TrainingInsight? {
        guard let rec = latestRecovery(data, withinDays: 2), let score = rec.score,
              let feeling = data.feelings.filter({ $0.key > data.asOfDay - 2 }).max(by: { $0.key < $1.key })?.value
        else { return nil }
        let variant: String
        if feeling <= 2 && score >= recoveryGreenMin {
            variant = "feeling_low_recovery_high"
        } else if feeling >= 4 && score < recoveryRedMax {
            variant = "feeling_high_recovery_low"
        } else {
            return nil
        }
        var notes: [String] = []
        if rec.isExperimental { notes.append("training.note.experimental_recovery") }
        return insight(TrainingInsightCode.feelingRecoveryConflict, .contradictory, .low,
                       facts: [fact("feeling", feeling, 1), fact("feeling_max", 5, 0), fact("recovery_score", score, 0)],
                       contributors: ["reported_feeling", "recovery_score"],
                       variant: "conflict.\(variant)", notes: notes, experimental: rec.isExperimental)
    }

    // MARK: Volume per sport

    private static func volume(_ sport: TrainingSport, _ data: TrainingDataset, code: String) -> TrainingInsight? {
        let asOf = data.asOfDay
        let recentDays = 7, priorBlocks = 3
        let priorDays = recentDays * priorBlocks
        let windowStart = asOf - recentDays - priorDays + 1
        let all = data.sessions.filter { $0.sport == sport }
        let inWindow = all.filter { $0.day >= windowStart && $0.day <= asOf }
        guard !all.isEmpty, (all.map { $0.day }.max() ?? Int.min) >= asOf - 56 else { return nil }
        let name = sport.rawValue
        let tracked = data.firstDay.map { asOf - $0 + 1 } ?? 0
        if tracked < volumeRequiredTrackedDays {
            return insight(code, .insufficientData, .low,
                           facts: [fact("tracked_days", Double(max(0, tracked)), 0, "j"),
                                   fact("required_days", Double(volumeRequiredTrackedDays), 0, "j")],
                           contributors: ["history_length"], variant: "volume.\(name).insufficient")
        }
        let recent = inWindow.filter { $0.day > asOf - recentDays }
        let prior = inWindow.filter { $0.day <= asOf - recentDays }
        let useMinutes = inWindow.allSatisfy { $0.durationMinutes != nil }
        let recentSessions = Double(recent.count)
        let priorMeanSessions = Double(prior.count) / Double(priorBlocks)
        let recentMinutes = TrainingMath.sum(recent.compactMap { $0.durationMinutes })
        let priorMeanMinutes = TrainingMath.sum(prior.compactMap { $0.durationMinutes }) / Double(priorBlocks)
        let recentMeasure = useMinutes ? recentMinutes : recentSessions
        let priorMeasure = useMinutes ? priorMeanMinutes : priorMeanSessions
        if recentMeasure == 0 && priorMeasure == 0 { return nil }

        let direction: String
        if priorMeasure <= 0 { direction = "up" }
        else if recentMeasure >= priorMeasure * volumeUpFactor { direction = "up" }
        else if recentMeasure <= priorMeasure * volumeDownFactor { direction = "down" }
        else { direction = "stable" }

        var facts = [fact("recent_sessions", recentSessions, 0), fact("prior_sessions_mean", priorMeanSessions, 1),
                     fact("recent_days", Double(recentDays), 0, "j"), fact("prior_days", Double(priorDays), 0, "j")]
        var notes: [String] = []
        var contributors = ["session_count"]
        if useMinutes {
            facts.append(fact("recent_minutes", recentMinutes, 0, "min"))
            facts.append(fact("prior_minutes_mean", priorMeanMinutes, 0, "min"))
            notes.append("training.note.volume_minutes")
            contributors.append("session_duration")
        }
        if sport == .strength {
            let srpe = recent.compactMap { $0.srpeLoad }
            if !srpe.isEmpty {
                facts.append(fact("srpe_load_recent", TrainingMath.sum(srpe), 0, "u.a."))
                notes.append("training.note.volume_srpe")
                contributors.append("srpe")
            }
            notes.append("training.note.no_hr_strength")
        } else if sport == .swim {
            notes.append("training.note.no_hr_swim")
        }
        let confidence: TrainingConfidence = useMinutes && all.count >= 6 ? .medium : .low
        return insight(code, .ok, confidence, facts: facts, contributors: contributors,
                       variant: "volume.\(name).\(direction)", notes: notes)
    }

    // MARK: Change detection

    private static func change(_ metric: TrainingMetric, _ report: TrainingStatsReport, code: String,
                               name: String, data: TrainingDataset) -> TrainingInsight? {
        guard let c = report.change(metric), c.status == .changeDetected, let dir = c.direction,
              let stat = c.statistic else { return nil }
        let experimental = metric == .recoveryScore
            && data.recovery.values.contains { $0.isExperimental }
        var confidence = c.confidence
        var notes: [String] = []
        if metric == .recoveryScore {
            confidence = TrainingConfidence.capped(confidence, at: .medium)
            if experimental { notes.append("training.note.experimental_recovery") }
        }
        let onsetAgo = c.onsetDay.map { max(0, report.asOfDay - $0) } ?? 0
        return insight(code, .ok, confidence,
                       facts: [fact("statistic", stat, 1), fact("threshold", c.threshold, 1),
                               fact("recent_points", Double(c.recentCount), 0),
                               fact("reference_points", Double(c.referenceCount), 0),
                               fact("recent_days", Double(c.recentDays), 0, "j"),
                               fact("onset_days_ago", Double(onsetAgo), 0, "j")],
                       contributors: ["cusum", "personal_reference"],
                       variant: "change.\(name).\(dir.rawValue)", notes: notes, experimental: experimental)
    }

    // MARK: Exploratory links

    private static func link(_ pair: TrainingLinkPair, _ report: TrainingStatsReport,
                             _ data: TrainingDataset) -> TrainingInsight? {
        guard let l = report.link(pair), l.pairCount > 0 else { return nil }
        let code: String
        let name: String
        switch pair {
        case .loadToNextSleepDuration: code = TrainingInsightCode.linkLoadSleep; name = "load_sleep"
        case .loadToNextRecovery: code = TrainingInsightCode.linkLoadRecovery; name = "load_recovery"
        case .sleepDurationToRecovery: code = TrainingInsightCode.linkSleepRecovery; name = "sleep_recovery"
        case .sleepEfficiencyToRecovery: code = TrainingInsightCode.linkEfficiencyRecovery; name = "efficiency_recovery"
        }
        let experimental = pair.involvesRecovery && data.recovery.values.contains { $0.isExperimental }
        var notes = [LinkStat.noteKey]
        if experimental { notes.append("training.note.experimental_recovery") }
        guard l.status == .ok, let rho = l.spearman, let lo = l.intervalLow, let hi = l.intervalHigh else {
            if l.status == .insufficientData {
                return insight(code, .insufficientData, .low,
                               facts: [fact("n", Double(l.pairCount), 0),
                                       fact("required_n", Double(LinkStat.minimumPairs), 0)],
                               contributors: ["paired_days"], variant: "link.\(name).insufficient",
                               notes: notes, experimental: experimental)
            }
            return nil
        }
        // Only report associations whose interval excludes zero and that are not negligible.
        guard (lo > 0 || hi < 0), abs(rho) >= linkMinimumAbsRho else { return nil }
        let confidence: TrainingConfidence = l.pairCount >= 30 ? .medium : .low
        return insight(code, .ok, confidence,
                       facts: [fact("n", Double(l.pairCount), 0), fact("rho_abs", abs(rho), 2),
                               fact("ci_abs_low", min(abs(lo), abs(hi)), 2),
                               fact("ci_abs_high", max(abs(lo), abs(hi)), 2)],
                       contributors: ["rank_correlation", "paired_days"],
                       variant: "link.\(name).\(rho > 0 ? "pos" : "neg")",
                       notes: notes, experimental: experimental)
    }
}
