import Foundation
import SwiftUI

// MARK: - RecoveryCoachModel

/// Pure-logic companion for `RecoveryDetailView` — derives WHOOP-style sub-scores
/// (HRV, RHR, Sleep) and 30-day deltas from a `DailySnapshot` + its history.
///
/// Kept free of view code so the math is unit-testable, mirroring `SleepCoachModel`.
/// The sub-score formula reuses the engine's `recoveryScore()` logistic shape
/// (`Recovery.swift`: `100 / (1 + exp(-1.2 * z))`) so the per-metric scores are
/// consistent with the headline recovery number that `LocalMetricsEngine` produces.
struct RecoveryCoachModel {
    let metric: DailySnapshot
    let history: [DailySnapshot]

    /// Lookback window for the personal baseline (matches WHOOP's "vs 30-day average").
    static let lookbackDays = 30

    init(metric: DailySnapshot, history: [DailySnapshot] = []) {
        self.metric = metric
        self.history = history
    }

    // MARK: - Top-level score

    /// Recovery score [0, 100], or `nil` during cold-start / express preview.
    var score: Double? {
        guard let value = metric.recovery, value.isFinite else { return nil }
        return min(max(value, 0), 100)
    }

    /// True when the snapshot is an express-preview (strain only, no recovery yet).
    var isCalibrating: Bool {
        score == nil
    }

    /// WHOOP-style color band — `"red"` < 34, `"yellow"` 34–67, `"green"` ≥ 67.
    /// `calibrating` when no score is available yet.
    var band: RecoveryBand {
        guard let score else { return .calibrating }
        return RecoveryBand(score: score)
    }

    var headline: String {
        guard let score else { return String(localized: "today.calibrage.de.ta.baseline.de.recuperation", table: "Today") }
        if usesExperimentalHealthRecovery {
            if score >= 67 { return String(localized: "today.recuperation.estimee.haute", table: "Today") }
            if score >= 34 { return String(localized: "today.recuperation.estimee.moyenne", table: "Today") }
            return String(localized: "today.recuperation.estimee.basse", table: "Today")
        }
        if score >= 67 { return String(localized: "today.recuperation.haute.tu.peux.pousser.aujourd.hui", table: "Today") }
        if score >= 34 { return String(localized: "today.recuperation.moyenne.modere.l.effort", table: "Today") }
        return String(localized: "today.recuperation.basse.priorise.le.repos", table: "Today")
    }

    var explanation: String {
        if usesExperimentalHealthRecovery {
            return TodayL.text("today.recovery.experimental.description")
        }
        return TodayL.text("today.recovery.description")
    }

    /// Integer score for the hero, or nil while calibrating.
    var scoreInt: Int? { score.map { Int($0.rounded()) } }

    /// Short quality word carried in band colour (the page's one accent).
    var qualityLabel: String {
        switch band {
        case .green:       return "Haute"
        case .yellow:      return String(localized: "today.moderee", table: "Today")
        case .red:         return "Basse"
        case .calibrating: return String(localized: "today.calibrage", table: "Today")
        }
    }

    // MARK: - Gauge (foregrounded "where you sit")

    /// Score position [0, 1] on the 0–100 gauge.
    var scoreFraction: Double { min(max((score ?? 0) / 100, 0), 1) }

    /// Band boundary fractions for the gauge ticks (red→yellow at 34, yellow→green at 67).
    var bandTickFractions: [Double] { [0.34, 0.67] }

    /// Today's score vs the most recent prior day with a real recovery value.
    var deltaVsYesterday: Double? {
        guard let score else { return nil }
        let prev = history
            .filter { $0.date < metric.date }
            .sorted { $0.date > $1.date }
            .first { ($0.recovery ?? 0) > 0 }?
            .recovery
        guard let prev else { return nil }
        return score - prev
    }

    var deltaVsYesterdayText: String {
        guard let d = deltaVsYesterday else { return String(localized: "today.1er.jour", table: "Today") }
        let r = Int(d.rounded())
        if r == 0 { return "stable vs hier" }
        return "\(r > 0 ? "+" : "")\(r) pts vs hier"
    }

    // MARK: - Trend (rolling 7-day means + 14-day series)

    /// Recovery values for the selected day and up to the 13 days before it, oldest
    /// first — feeds the trend mini-chart. Skips express/cold-start zeros.
    var trendSeries: [RecoveryTrendPoint] {
        history
            .filter { $0.date <= metric.date }
            .sorted { $0.date < $1.date }
            .suffix(14)
            .compactMap { snap in
                guard let r = snap.recovery, r.isFinite, r > 0 else { return nil }
                return RecoveryTrendPoint(date: snap.date, value: min(max(r, 0), 100), isToday: snap.date == metric.date)
            }
    }

    /// Mean of the last 7 valid days minus the 7 before that. `nil` until both windows
    /// have at least 3 valid nights.
    var weeklyTrendDelta: Double? {
        let snaps = history
            .filter { ($0.recovery ?? 0) > 0 && $0.date <= metric.date }
            .sorted { $0.date > $1.date }
        let recent = snaps.prefix(7).compactMap { $0.recovery }
        let prior = snaps.dropFirst(7).prefix(7).compactMap { $0.recovery }
        guard recent.count >= 3, prior.count >= 3 else { return nil }
        let m1 = recent.reduce(0, +) / Double(recent.count)
        let m2 = prior.reduce(0, +) / Double(prior.count)
        return m1 - m2
    }

    var trendDirection: RecoveryDeltaDirection {
        guard let d = weeklyTrendDelta, abs(d) >= 1 else { return .neutral }
        return d > 0 ? .better : .worse
    }

    var trendText: String {
        guard let d = weeklyTrendDelta else { return "Historique insuffisant" }
        let r = Int(d.rounded())
        if abs(r) < 1 { return String(localized: "today.stable.vs.semaine.derniere", table: "Today") }
        return TodayL.format("today.final.recovery.week.delta", r > 0 ? "+" : "", String(r))
    }

    // MARK: - Drivers (what influences the score)

    /// Metric rows that actually have a sub-score (baseline available).
    private var scoredMetrics: [RecoveryMetricRow] { metrics.filter { $0.subScore != nil } }

    /// The metric pulling the score down the most (lowest sub-score).
    var limitingDriver: RecoveryMetricRow? {
        scoredMetrics.min { ($0.subScore ?? 100) < ($1.subScore ?? 100) }
    }

    /// The metric supporting the score the most (highest sub-score).
    var strongestDriver: RecoveryMetricRow? {
        scoredMetrics.max { ($0.subScore ?? 0) < ($1.subScore ?? 0) }
    }

    /// One-line dominant driver for the "why" disclosure header.
    var dominantDriverSummary: String {
        guard let l = limitingDriver else { return "Calibrage en cours" }
        return TodayL.format("today.recovery.limiting", l.label)
    }

    /// Prose tying the drivers together, shown when the "why" disclosure expands.
    var driverNarrative: String {
        guard let limiting = limitingDriver else {
            return String(localized: "today.pas.encore.assez.de.nuits.pour.comparer.tes.signaux.a.ta.baseline.continue", table: "Today")
        }
        let strong = strongestDriver
        var out = TodayL.format("today.recovery.why", limiting.label)
        if let strong, strong.id != limiting.id, (strong.subScore ?? 0) >= 60 {
            out += " À l'inverse, \(strong.label.lowercased()) te soutient."
        }
        return out
    }

    // MARK: - How to improve (prescriptive)

    var improvementTitle: String {
        if usesExperimentalHealthRecovery { return String(localized: "today.estimation.experimentale", table: "Today") }
        switch band {
        case .green:       return "Tu peux pousser"
        case .yellow:      return String(localized: "today.journee.mesuree", table: "Today")
        case .red:         return "Repos prioritaire"
        case .calibrating: return String(localized: "today.calibrage", table: "Today")
        }
    }

    var improvementMessage: String {
        if isCalibrating {
            return String(localized: "today.porte.ton.bracelet.ou.ta.montre.la.nuit.pour.etablir.tes.references.personn", table: "Today")
        }
        if usesExperimentalHealthRecovery {
            return String(localized: "today.ce.score.utilise.une.estimation.sante.experimentale.suis.plutot.sa.tendance", table: "Today")
        }
        if band == .green {
            return TodayL.text("today.recovery.advice.high")
        }
        switch limitingDriver?.kind {
        case .hrv:
            return TodayL.text("today.recovery.advice.hrv")
        case .rhr:
            if metric.recoveryRHRObservation?.sourceID.contains("sleep-median-hr") == true {
                return String(localized: "today.ta.fc.mediane.de.nuit.est.au.dessus.de.ta.reference.habituelle", table: "Today")
            }
            return TodayL.text("today.recovery.advice.rhr")
        case .sleep:
            return String(localized: "today.ton.sommeil.tire.la.recuperation.vers.le.bas.vise.30.a.60.min.de.plus.cette", table: "Today")
        case .none:
            return String(localized: "today.garde.l.effort.mesure.et.concentre.toi.sur.le.sommeil.l.hydratation.et.la.n", table: "Today")
        }
    }

    private var usesExperimentalHealthRecovery: Bool {
        metric.recoveryHRVMetric == "sdnn" || metric.recoveryRHRObservation?.sourceID.contains("sleep-median-hr") == true
    }

    // MARK: - Metric rows

    var metrics: [RecoveryMetricRow] {
        [hrvRow, rhrRow, sleepRow]
    }

    // MARK: - HRV (higher = better recovery)

    private var hrvRow: RecoveryMetricRow {
        let value = metric.recoveryHRVObservation?.value ?? metric.avgHrv
        let baseline = hrvBaseline
        let subScore: Double? = {
            if metric.recoveryHRVObservation != nil { return metric.recoveryZHrv.map { logisticScore(z: $0) } }
            if let z = metric.recoveryZHrv { return logisticScore(z: z) }
            guard let value, let baseline else { return nil }
            let z = (value - baseline.mean) / max(baseline.stdDev, 1e-9)
            return logisticScore(z: z)
        }()
        let delta: Double? = {
            if metric.recoveryHRVObservation != nil { return nil }
            guard let value, let baseline else { return nil }
            return value - baseline.mean
        }()
        return RecoveryMetricRow(
            kind: .hrv,
            value: value,
            valueText: value.map { "\(Int($0.rounded())) ms" + (metric.recoveryHRVMetric == "sdnn" ? " · SDNN" : "") } ?? "--",
            subScore: subScore,
            delta: delta,
            deltaText: formatDelta(value: delta, unit: "ms"),
            // HRV: higher than baseline = better recovery
            deltaDirection: direction(for: delta, higherIsBetter: true)
        )
    }

    // MARK: - RHR (lower = better recovery)

    private var rhrRow: RecoveryMetricRow {
        let value = metric.recoveryRHRObservation?.value ?? metric.restingHR
        let baseline = rhrBaseline
        let subScore: Double? = {
            if metric.recoveryRHRObservation != nil { return metric.recoveryZRhr.map { logisticScore(z: $0) } }
            if let z = metric.recoveryZRhr { return logisticScore(z: z) }
            guard let value, let baseline else { return nil }
            // Inverted: lower RHR is better → z = (mean - value) / σ
            let z = (baseline.mean - value) / max(baseline.stdDev, 1e-9)
            return logisticScore(z: z)
        }()
        let delta: Double? = {
            if metric.recoveryRHRObservation != nil { return nil }
            guard let value, let baseline else { return nil }
            return value - baseline.mean
        }()
        return RecoveryMetricRow(
            kind: .rhr,
            value: value,
            valueText: value.map { "\(Int($0.rounded())) bpm" + (metric.recoveryRHRObservation?.sourceID.contains("sleep-median-hr") == true ? TodayL.text("today.final.recovery.overnight") : "") } ?? "--",
            subScore: subScore,
            delta: delta,
            deltaText: formatDelta(value: delta, unit: "bpm"),
            // RHR: lower than baseline = better recovery
            deltaDirection: direction(for: delta, higherIsBetter: false),
            labelOverride: metric.recoveryRHRObservation?.sourceID.contains("sleep-median-hr") == true ? TodayL.text("today.final.recovery.overnight.label") : nil
        )
    }

    // MARK: - Respiratory rate — OFFLINE-03 (champ server-only absent en local-first)

    // `respRateBpm` est un champ server-only absent de `DailySnapshot` (architecture local-first).
    // La row a été supprimée de l'UI le 2026-06-19 : afficher un "--" permanent sans contexte
    // prêtait à confusion. Sera réintroduite quand un calculateur local de fréquence respiratoire
    // sera câblé dans `LocalMetricsEngine` (cf. loop-redesign/03-donnees-manquantes.md, niveau 3).

    // MARK: - Sleep (uses the existing 0–100 sleepScore)

    private var sleepRow: RecoveryMetricRow {
        let value = metric.sleepScore
        let baseline = sleepBaseline
        let subScore: Double? = {
            guard let value, value.isFinite else { return nil }
            return min(max(value, 0), 100)
        }()
        let delta: Double? = {
            guard let value, let baseline else { return nil }
            return value - baseline.mean
        }()
        return RecoveryMetricRow(
            kind: .sleep,
            value: value,
            valueText: value.map { "\(Int($0.rounded()))%" } ?? "--",
            subScore: subScore,
            delta: delta,
            deltaText: formatDelta(value: delta, unit: "pts"),
            // Sleep: higher score than baseline = better recovery
            deltaDirection: direction(for: delta, higherIsBetter: true)
        )
    }

    // MARK: - 30-day baselines

    /// Snapshots strictly before the selected day, most-recent first, capped at
    /// `lookbackDays`. The selected day is excluded so it doesn't bias its own
    /// baseline.
    private var lookback: [DailySnapshot] {
        let prior = history
            .filter { $0.date < metric.date }
            .sorted { $0.date > $1.date }
        return Array(prior.prefix(Self.lookbackDays))
    }

    /// Minimum number of valid prior nights required to trust a baseline. Below
    /// this the per-metric sub-score and delta stay `nil` — a single noisy night
    /// (or a streak of express snapshots with `restingHR = nil`) would otherwise
    /// produce a mean of 0 and a misleading "+50 bpm vs 30j" delta.
    static let minBaselineNights = 3

    private struct Baseline {
        let mean: Double
        let stdDev: Double
        let n: Int
    }

    private var hrvBaseline: Baseline? {
        if let observation = metric.recoveryHRVObservation, metric.recoveryHRVMetric == "sdnn" {
            return baseline(extract: { $0.healthSDNN?.sourceID == observation.sourceID ? $0.healthSDNN?.value : nil }, positive: true)
        }
        return baseline(extract: { $0.avgHrv }, positive: true)
    }

    private var rhrBaseline: Baseline? {
        if let observation = metric.recoveryRHRObservation, observation.sourceID.contains("sleep-median-hr") {
            return baseline(extract: { $0.healthRestingHR?.sourceID == observation.sourceID ? $0.healthRestingHR?.value : nil }, positive: true)
        }
        return baseline(extract: { $0.restingHR }, positive: true)
    }

    private var sleepBaseline: Baseline? {
        baseline(extract: { $0.sleepScore }, positive: false)
    }

    /// Folds the lookback into a personal baseline. `positive` filters out
    /// non-physiologic zero/negative values (an RHR or HRV of 0 is an artefact
    /// of an express snapshot or a cold-start row, not a real measurement) so
    /// they don't drag the mean to 0 and fabricate a delta.
    private func baseline(
        extract: (DailySnapshot) -> Double?,
        positive: Bool
    ) -> Baseline? {
        var values = lookback.compactMap { extract($0) }.filter { $0.isFinite }
        if positive { values = values.filter { $0 > 0 } }
        guard values.count >= Self.minBaselineNights else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        let stdDev: Double = {
            guard values.count > 1 else { return 0 }
            let variance = values.map { pow($0 - mean, 2) }.reduce(0, +) / Double(values.count - 1)
            return sqrt(variance)
        }()
        return Baseline(mean: mean, stdDev: stdDev, n: values.count)
    }

    // MARK: - Helpers

    /// WHOOP-style logistic squash to [0, 100]. Mirrors `Recovery.swift` (k=1.2, z0=0.0)
    /// so a value exactly on the baseline scores ~58% (population-average anchor).
    private func logisticScore(z: Double) -> Double {
        let raw = 100.0 / (1.0 + exp(-1.2 * z))
        return min(max(raw, 0), 100)
    }

    /// Maps a signed delta to a recovery-favorable direction. `higherIsBetter`
    /// encodes the metric's polarity (true for HRV/Sleep, false for RHR).
    private func direction(for delta: Double?, higherIsBetter: Bool) -> RecoveryDeltaDirection {
        guard let delta, delta.isFinite, delta != 0 else { return .neutral }
        let favorable = higherIsBetter ? (delta > 0) : (delta < 0)
        return favorable ? .better : .worse
    }

    /// Formats a delta with its sign and unit, e.g. `+5 ms vs 30j` or `-2 bpm vs 30j`.
    private func formatDelta(value: Double?, unit: String) -> String {
        guard let value, value.isFinite else { return "--" }
        let rounded = Int(value.rounded())
        let sign = rounded > 0 ? "+" : ""
        return "\(sign)\(rounded) \(unit) vs 30j"
    }
}

// MARK: - RecoveryBand

// Couleurs et état d'affichage : `RecoveryCoachModel+Display.swift` (app seulement), pour que
// Tools/LoopReplay compile ce fichier sans dépendre des tokens d'UI.

/// WHOOP-style color band. Thresholds mirror the engine's `recoveryBand()` in
/// `Recovery.swift`: red < 34, yellow 34–67, green ≥ 67. `calibrating` is a UI-only
/// extra for the cold-start / express-preview state where no score exists yet.
enum RecoveryBand: String {
    case red, yellow, green, calibrating

    init(score: Double) {
        if score < 34 { self = .red; return }
        if score < 67 { self = .yellow; return }
        self = .green
    }

    /// `true` for the low/critical state where the hero accent should pulse.
    var isLow: Bool { self == .red }
}

// MARK: - RecoveryTrendPoint

/// One point on the recovery trend mini-chart.
struct RecoveryTrendPoint: Identifiable {
    let id = UUID()
    let date: String
    let value: Double
    let isToday: Bool
}

// MARK: - RecoveryMetricKind

enum RecoveryMetricKind: CaseIterable {
    case hrv, rhr, sleep

    var label: String {
        switch self {
        case .hrv:   return String(localized: "today.variabilite.de.la.frequence.cardiaque", table: "Today")
        case .rhr:   return String(localized: "today.frequence.cardiaque.au.repos", table: "Today")
        case .sleep: return String(localized: "today.sommeil", table: "Today")
        }
    }

    /// Compact label for rows and driver summaries.
    var shortLabel: String {
        switch self {
        case .hrv:   return "HRV"
        case .rhr:   return TodayL.text("today.remaining.hr.rest")
        case .sleep: return String(localized: "today.sommeil", table: "Today")
        }
    }

    var systemImage: String {
        switch self {
        case .hrv:   return "waveform.path.ecg"
        case .rhr:   return "heart.fill"
        case .sleep: return "bed.double.fill"
        }
    }
}

// MARK: - RecoveryDeltaDirection

enum RecoveryDeltaDirection {
    case better, worse, neutral

    /// SF Symbol arrow matching the direction. Diagonal arrows (up-right / down-right)
    /// match WHOOP's delta indicator convention.
    var systemImage: String {
        switch self {
        case .better:   return "arrow.up.right"
        case .worse:    return "arrow.down.right"
        case .neutral:  return "minus"
        }
    }
}

// MARK: - RecoveryMetricRow

struct RecoveryMetricRow: Identifiable {
    let id = UUID()
    let kind: RecoveryMetricKind
    let value: Double?
    let valueText: String
    /// Per-metric sub-score [0, 100], WHOOP-style. `nil` when the metric or its
    /// baseline isn't available (cold-start, server-only field, or no history).
    let subScore: Double?
    let delta: Double?
    let deltaText: String
    let deltaDirection: RecoveryDeltaDirection
    var labelOverride: String? = nil
    var label: String { labelOverride ?? kind.shortLabel }

    var band: RecoveryBand {
        guard let subScore else { return .calibrating }
        return RecoveryBand(score: subScore)
    }

    var hasScore: Bool { subScore != nil }

    /// Sub-score [0, 1] for the facts mini-bar.
    var subScoreFraction: Double { min(max((subScore ?? 0) / 100, 0), 1) }

    /// Sub-score as an integer percentage, or "--" while calibrating.
    var subScoreText: String { subScore.map { "\(Int($0.rounded()))%" } ?? "--" }
}
