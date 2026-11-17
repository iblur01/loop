import Foundation
import SwiftUI

// MARK: - StrainCoachModel

/// Pure-logic companion for `StrainDetailView` — derives WHOOP-style sub-scores
/// for the levers that drive the day's strain and the target recommendation.
///
/// Kept free of view code so the math is unit-testable, mirroring
/// `RecoveryCoachModel` / `SleepCoachModel`.
///
/// The four levers:
///   1. **Effort** — actual day strain vs the recommended target (alignment score)
///   2. **Cible** — the target strain itself, with confidence as the score
///   3. **Récupération** — the recovery % that set the target (passthrough)
///   4. **FC au repos** — RHR, the Karvonen denominator (lower = more HR reserve =
///      less strain for the same effort). Z-scored vs 30d like the recovery page.
struct StrainCoachModel {
    let metric: DailySnapshot
    let history: [DailySnapshot]

    /// Lookback window for the personal baseline (matches WHOOP's "vs 30-day average").
    static let lookbackDays = 30

    /// Minimum valid prior nights to trust a baseline (same rationale as RecoveryCoachModel).
    static let minBaselineNights = 3

    init(metric: DailySnapshot, history: [DailySnapshot] = []) {
        self.metric = metric
        self.history = history
    }

    // MARK: - Top-level strain

    /// Day strain on the 0–21 Banister scale, or `nil` during cold-start / express
    /// without enough HR samples.
    var strain: Double? {
        guard let value = metric.strain, value.isFinite else { return nil }
        return min(max(value, 0), 21)
    }

    var isCalibrating: Bool { strain == nil }

    /// WHOOP-style strain band — blue spectrum, not red/yellow/green (strain is
    /// load, not recovery). `calibrating` when no strain is available yet.
    var band: StrainBand {
        guard let strain else { return .calibrating }
        return StrainBand(strain: strain)
    }

    /// Today vs a past day: past days get a factual recap, never an imperative (`AdviceTense`).
    var tense: AdviceTense { AdviceTense.of(day: metric.date) }

    var headline: String {
        guard let strain else { return String(localized: "today.calibrage.du.strain", table: "Today") }
        let t = tense
        if let target = metric.targetStrain, target > 0 {
            if strain < target * 0.7 {
                return t.pick(TodayL.text("today.journee.calme.il.te.reste.de.la.marge.jusqu.a.la.cible"),
                              past: TodayL.text("today.journee.calme.l.effort.est.reste.sous.la.cible"))
            }
            if strain <= target * 1.1 {
                return t.pick(TodayL.text("today.effort.aligne.avec.ta.cible.bonne.gestion.de.charge"),
                              past: TodayL.text("today.ce.jour.la.l.effort.etait.aligne.avec.la.cible"))
            }
            return t.pick(TodayL.text("today.tu.as.depasse.la.cible.surveille.ta.recuperation.demain"),
                          past: TodayL.text("today.strain.over.target.past"))
        }
        return t.pick(TodayL.text("today.strain.du.jour.calcule.depuis.ta.frequence.cardiaque"),
                      past: TodayL.text("today.strain.de.ce.jour.calcule.depuis.ta.frequence.cardiaque"))
    }

    var explanation: String {
        TodayL.text("today.le.strain.mesure.la.charge.cardiovasculaire.de.ta.journee.sur.une.echelle.d")
    }

    /// Day strain formatted, or "--" while calibrating.
    var strainText: String { strain.map { String(format: "%.1f", $0) } ?? "--" }

    /// Short band word carried in band colour (the page's one accent).
    var qualityLabel: String {
        switch band {
        case .easy:        return "Facile"
        case .moderate:    return String(localized: "today.modere", table: "Today")
        case .high:        return String(localized: "today.eleve", table: "Today")
        case .veryHigh:    return String(localized: "today.tres.eleve", table: "Today")
        case .calibrating: return String(localized: "today.calibrage", table: "Today")
        }
    }

    // MARK: - Target (foregrounded "where you are vs target")

    var targetStrain: Double? {
        guard let t = metric.targetStrain, t > 0 else { return nil }
        return t
    }

    var targetText: String { targetStrain.map { String(format: "%.1f", $0) } ?? "--" }

    /// Position [0, 1] of current strain on the 0–21 scale.
    var strainFraction: Double { min(max((strain ?? 0) / 21, 0), 1) }

    /// Position [0, 1] of the target tick on the 0–21 scale.
    var targetFraction: Double? { targetStrain.map { min(max($0 / 21, 0), 1) } }

    /// `true` when the day overshot the target by more than 10% — the one place a
    /// warning tint is justified (genuine over-exertion).
    var isOvershoot: Bool {
        guard let strain, let target = targetStrain else { return false }
        return strain > target * 1.1
    }

    var headroomText: String {
        guard let strain, let target = targetStrain else { return "Cible non disponible" }
        let gap = target - strain
        if abs(gap) <= target * 0.1 { return "Cible atteinte" }
        if gap > 0 { return TodayL.format("today.strain.remaining", String(format: "%.1f", gap)) }
        return TodayL.format("today.strain.exceeded", String(format: "%.1f", -gap))
    }

    // MARK: - Trend (14-day series + weekly mean delta)

    var trendSeries: [StrainTrendPoint] {
        history
            .filter { $0.date <= metric.date }
            .sorted { $0.date < $1.date }
            .suffix(14)
            .compactMap { snap in
                guard let s = snap.strain, s.isFinite, s > 0 else { return nil }
                return StrainTrendPoint(date: snap.date, value: min(max(s, 0), 21), isToday: snap.date == metric.date)
            }
    }

    var weeklyTrendDelta: Double? {
        let snaps = history
            .filter { ($0.strain ?? 0) > 0 && $0.date <= metric.date }
            .sorted { $0.date > $1.date }
        let recent = snaps.prefix(7).compactMap { $0.strain }
        let prior = snaps.dropFirst(7).prefix(7).compactMap { $0.strain }
        guard recent.count >= 3, prior.count >= 3 else { return nil }
        let m1 = recent.reduce(0, +) / Double(recent.count)
        let m2 = prior.reduce(0, +) / Double(prior.count)
        return m1 - m2
    }

    var trendText: String {
        guard let d = weeklyTrendDelta else { return "Historique insuffisant" }
        let r = (d * 10).rounded() / 10
        if abs(r) < 0.1 { return String(localized: "today.charge.stable.vs.semaine.derniere", table: "Today") }
        return TodayL.format("today.final.strain.week.delta", r > 0 ? "+" : "", String(format: "%.1f", r))
    }

    // MARK: - Acute:Chronic load ratio (ACWR)

    /// Mean of the last `n` valid strain days (selected day included), most-recent first.
    private func strainMean(lastDays n: Int) -> (mean: Double, count: Int)? {
        let vals = history
            .filter { $0.date <= metric.date }
            .sorted { $0.date > $1.date }
            .compactMap { $0.strain }
            .filter { $0.isFinite && $0 > 0 }
            .prefix(n)
        guard !vals.isEmpty else { return nil }
        return (vals.reduce(0, +) / Double(vals.count), vals.count)
    }

    /// Acute (7-day) / chronic (28-day) load ratio — the sports-science overtraining
    /// gauge. `nil` until there are ≥3 acute and ≥7 chronic valid days.
    var acwrRatio: Double? {
        guard let acute = strainMean(lastDays: 7), acute.count >= 3,
              let chronic = strainMean(lastDays: 28), chronic.count >= 7,
              chronic.mean > 0 else { return nil }
        return acute.mean / chronic.mean
    }

    var acwrText: String {
        guard let r = acwrRatio else { return String(localized: "today.charge.en.calibrage", table: "Today") }
        return String(format: "%.2f · %@", r, acwrZone.label)
    }

    var acwrZone: StrainLoadZone {
        guard let r = acwrRatio else { return .unknown }
        if r < 0.8 { return .detraining }
        if r <= 1.3 { return .optimal }
        if r <= 1.5 { return .ramping }
        return .high
    }

    // MARK: - Why (what drove the level)

    var dominantSummary: String {
        guard strain != nil, targetStrain != nil else { return "Calibrage en cours" }
        if isOvershoot { return String(localized: "today.au.dessus.de.ta.cible", table: "Today") }
        if let strain, let target = targetStrain, strain < target * 0.7 { return String(localized: "today.sous.ta.cible", table: "Today") }
        return String(localized: "today.aligne.avec.ta.cible", table: "Today")
    }

    var whyNarrative: String {
        let t = tense
        guard let strain, let target = targetStrain else {
            return t.pick(TodayL.text("today.pas.encore.assez.de.donnees.pour.situer.ton.effort.par.rapport.a.une.cible"),
                          past: TodayL.text("today.pas.assez.de.donnees.ce.jour.la.pour.situer.l.effort.par.rapport.a.une.cibl"))
        }
        let targetText = Self.format(target)
        let rec = metric.recovery.map { Int($0.rounded()) }
        let recPart = rec.map { TodayL.format("today.strain.recovery.part", String($0)) } ?? ""
        if strain > target * 1.1 {
            return t.pick(TodayL.format("today.strain.above.explain", targetText, recPart),
                          past: TodayL.format("today.strain.above.explain.past", targetText, recPart))
        }
        if strain < target * 0.7 {
            return t.pick(TodayL.format("today.strain.below.explain", targetText, recPart),
                          past: TodayL.format("today.strain.below.explain.past", targetText, recPart))
        }
        return t.pick(TodayL.format("today.strain.aligned.explain", targetText, recPart),
                      past: TodayL.format("today.strain.aligned.explain.past", targetText, recPart))
    }

    // MARK: - How to manage (prescriptive)

    var manageTitle: String {
        let t = tense
        if isCalibrating { return String(localized: "today.calibrage", table: "Today") }
        if isOvershoot || acwrZone == .high {
            return t.pick(TodayL.text("today.final.strain.ease"), past: TodayL.text("today.charge.au.dessus.de.la.cible"))
        }
        if let strain, let target = targetStrain, strain < target * 0.7 {
            return t.pick("Tu as de la marge", past: TodayL.text("today.journee.sous.la.cible"))
        }
        return t.pick(TodayL.text("today.final.strain.managed"), past: TodayL.text("today.final.strain.aligned"))
    }

    var manageMessage: String {
        let t = tense
        if isCalibrating {
            return t.pick(TodayL.text("today.continue.a.porter.le.bracelet.pour.calculer.ton.strain.et.ta.cible.du.jour"),
                          past: TodayL.text("today.pas.assez.de.donnees.ce.jour.la.pour.calculer.le.strain.et.la.cible"))
        }
        if acwrZone == .high {
            return t.pick(TodayL.text("today.strain.high.acute"),
                          past: TodayL.text("today.strain.high.acute.past"))
        }
        if isOvershoot {
            return t.pick(TodayL.text("today.strain.over.target"),
                          past: TodayL.text("today.strain.over.target.past"))
        }
        if let strain, let target = targetStrain, strain < target * 0.7 {
            return t.pick(TodayL.format("today.strain.room.message", Self.format(target)),
                          past: TodayL.format("today.strain.room.message.past", Self.format(target)))
        }
        if acwrZone == .detraining {
            return t.pick(TodayL.text("today.ta.charge.baisse.depuis.quelques.jours.tu.peux.remonter.l.intensite.progres"),
                          past: TodayL.text("today.ce.jour.la.la.charge.baissait.depuis.quelques.jours"))
        }
        return t.pick(TodayL.text("today.effort.aligne.avec.ta.cible.et.charge.equilibree.garde.ce.rythme"),
                      past: TodayL.text("today.effort.aligne.avec.la.cible.et.charge.equilibree.ce.jour.la"))
    }

    // MARK: - Metric rows

    var metrics: [StrainMetricRow] {
        [effortRow, targetRow, recoveryRow, rhrRow]
    }

    // MARK: - Effort (actual strain vs target)

    private var effortRow: StrainMetricRow {
        let value = strain
        let baseline = strainBaseline
        let subScore: Double? = {
            guard let value, let target = metric.targetStrain, target > 0 else { return nil }
            return effortAlignmentScore(strain: value, target: target)
        }()
        // Delta vs 30d average strain — neutral direction (higher strain isn't
        // inherently good or bad, it's just more/less load than usual).
        let delta: Double? = {
            guard let value, let baseline else { return nil }
            return value - baseline.mean
        }()
        return StrainMetricRow(
            kind: .effort,
            value: value,
            valueText: value.map { String(format: "%.1f", $0) } ?? "--",
            subScore: subScore,
            delta: delta,
            deltaText: formatStrainDelta(value: delta),
            deltaDirection: .neutral
        )
    }

    // MARK: - Target strain (with confidence)

    private var targetRow: StrainMetricRow {
        let value = metric.targetStrain
        let subScore: Double? = {
            guard value != nil else { return nil }
            return confidenceScore(metric.targetStrainConfidence)
        }()
        return StrainMetricRow(
            kind: .target,
            value: value,
            valueText: value.map { String(format: "%.1f", $0) } ?? "--",
            subScore: subScore,
            delta: nil,
            deltaText: confidenceLabel(metric.targetStrainConfidence),
            deltaDirection: .neutral
        )
    }

    // MARK: - Recovery (the input that set the target)

    private var recoveryRow: StrainMetricRow {
        let value = metric.recovery
        let subScore: Double? = {
            guard let value, value.isFinite else { return nil }
            return min(max(value, 0), 100)
        }()
        return StrainMetricRow(
            kind: .recovery,
            value: value,
            valueText: value.map { "\(Int($0.rounded()))%" } ?? "--",
            subScore: subScore,
            delta: nil,
            deltaText: nil,
            deltaDirection: .neutral
        )
    }

    // MARK: - Resting HR (Karvonen denominator lever)

    private var rhrRow: StrainMetricRow {
        let value = metric.restingHR
        let baseline = rhrBaseline
        let subScore: Double? = {
            guard let value, let baseline else { return nil }
            // Lower RHR = more HR reserve = better strain capacity → inverted z.
            let z = (baseline.mean - value) / max(baseline.stdDev, 1e-9)
            return logisticScore(z: z)
        }()
        let delta: Double? = {
            guard let value, let baseline else { return nil }
            return value - baseline.mean
        }()
        return StrainMetricRow(
            kind: .rhr,
            value: value,
            valueText: value.map { "\(Int($0.rounded())) bpm" } ?? "--",
            subScore: subScore,
            delta: delta,
            deltaText: formatDelta(value: delta, unit: "bpm"),
            deltaDirection: direction(for: delta, higherIsBetter: false)
        )
    }

    // MARK: - 30-day baselines

    private var lookback: [DailySnapshot] {
        let prior = history
            .filter { $0.date < metric.date }
            .sorted { $0.date > $1.date }
        return Array(prior.prefix(Self.lookbackDays))
    }

    private struct Baseline {
        let mean: Double
        let stdDev: Double
        let n: Int
    }

    private var strainBaseline: Baseline? {
        baseline(extract: { $0.strain }, positive: false)
    }

    private var rhrBaseline: Baseline? {
        baseline(extract: { $0.restingHR }, positive: true)
    }

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

    // MARK: - Score helpers

    /// Effort alignment score [0, 100]. 100 = exactly at target, diminishing
    /// for under- or overshoot. Overshoot penalty is gentler than undershoot
    /// — pushing a bit past the target is fine, big overexertion is not.
    private func effortAlignmentScore(strain: Double, target: Double) -> Double {
        if strain <= target {
            return (strain / target) * 100
        }
        let overshoot = strain - target
        return max(0, 100 - overshoot * 15)
    }

    /// Maps target-strain confidence to a 0–100 score so the badge color
    /// reflects how trustworthy the recommendation is.
    /// `"high"` → 90, `"medium"` → 60, `"low"` → 30, unknown → nil.
    private func confidenceScore(_ confidence: String?) -> Double? {
        guard let confidence else { return nil }
        switch confidence {
        case "high":   return 90
        case "medium": return 60
        case "low":    return 30
        default:       return nil
        }
    }

    private func confidenceLabel(_ confidence: String?) -> String {
        guard let confidence else { return "--" }
        switch confidence {
        case "high":   return "Confiance haute"
        case "medium": return String(localized: "today.confiance.moyenne", table: "Today")
        case "low":    return "Confiance basse"
        default:       return "--"
        }
    }

    /// WHOOP-style logistic squash to [0, 100] for the RHR z-score. Same shape
    /// as `RecoveryCoachModel.logisticScore` (k=1.2, z0=0.0).
    private func logisticScore(z: Double) -> Double {
        let raw = 100.0 / (1.0 + exp(-1.2 * z))
        return min(max(raw, 0), 100)
    }

    private func direction(for delta: Double?, higherIsBetter: Bool) -> StrainDeltaDirection {
        guard let delta, delta.isFinite, delta != 0 else { return .neutral }
        let favorable = higherIsBetter ? (delta > 0) : (delta < 0)
        return favorable ? .better : .worse
    }

    // MARK: - Delta text formatting

    /// Strain delta — 1 decimal, no unit (strain is a unitless 0–21 scale).
    private func formatStrainDelta(value: Double?) -> String {
        guard let value, value.isFinite else { return "--" }
        let rounded = (value * 10).rounded() / 10
        let sign = rounded > 0 ? "+" : ""
        return "\(sign)\(String(format: "%.1f", rounded)) vs 30j"
    }

    /// Generic delta with sign and unit (for RHR bpm).
    private func formatDelta(value: Double?, unit: String) -> String {
        guard let value, value.isFinite else { return "--" }
        let rounded = Int(value.rounded())
        let sign = rounded > 0 ? "+" : ""
        return "\(sign)\(rounded) \(unit) vs 30j"
    }
}

// MARK: - StrainBand

/// WHOOP-style strain band on the blue spectrum. Strain is load (not recovery),
/// so the bands are soft→bright→deep blue rather than red/yellow/green.
/// `calibrating` is a UI-only extra for the cold-start / express-preview state.
enum StrainBand: String {
    case easy       // < 9
    case moderate   // 9 – < 13
    case high       // 13 – < 17
    case veryHigh   // ≥ 17
    case calibrating

    init(strain: Double) {
        if strain < 9 { self = .easy; return }
        if strain < 13 { self = .moderate; return }
        if strain < 17 { self = .high; return }
        self = .veryHigh
    }

    /// Strain keeps one identity tint across bands (spec design §2.3): the band is told by its
    /// word, not by a shade of blue. Calibrating reads neutral.
    var color: Color {
        self == .calibrating ? HealthState.neutral.color : Metric.strain.tint
    }
}

// MARK: - StrainTrendPoint

/// One point on the strain trend mini-chart.
struct StrainTrendPoint: Identifiable {
    let id = UUID()
    let date: String
    let value: Double
    let isToday: Bool
}

// MARK: - StrainLoadZone (ACWR interpretation)

/// Acute:chronic workload ratio zone — the overtraining gauge.
enum StrainLoadZone {
    case detraining   // < 0.8
    case optimal      // 0.8 – 1.3
    case ramping      // 1.3 – 1.5
    case high         // > 1.5
    case unknown

    var label: String {
        switch self {
        case .detraining: return "en baisse"
        case .optimal:    return "zone optimale"
        case .ramping:    return "en hausse"
        case .high:       return TodayL.text("today.remaining.strain.high")
        case .unknown:    return "calibrage"
        }
    }

    /// Position [0, 1] of the ratio on a 0…2 gauge (1.0 = balanced sits at mid).
    func fraction(_ ratio: Double) -> Double { min(max(ratio / 2, 0), 1) }
}

// MARK: - StrainMetricKind

enum StrainMetricKind: CaseIterable {
    case effort, target, recovery, rhr

    var label: String {
        switch self {
        case .effort:   return String(localized: "today.effort.du.jour", table: "Today")
        case .target:   return String(localized: "today.cible.de.strain", table: "Today")
        case .recovery: return String(localized: "today.recuperation", table: "Today")
        case .rhr:      return String(localized: "today.frequence.cardiaque.au.repos", table: "Today")
        }
    }

    /// Compact label for the facts rows.
    var shortLabel: String {
        switch self {
        case .effort:   return "Effort"
        case .target:   return "Cible"
        case .recovery: return String(localized: "today.recup.c7b86f", table: "Today")
        case .rhr:      return TodayL.text("today.remaining.hr.rest")
        }
    }

    var systemImage: String {
        switch self {
        case .effort:   return "flame.fill"
        case .target:   return "target"
        case .recovery: return "heart.text.square.fill"
        case .rhr:      return "heart.fill"
        }
    }
}

// MARK: - StrainDeltaDirection

enum StrainDeltaDirection {
    case better, worse, neutral

    var systemImage: String {
        switch self {
        case .better:   return "arrow.up.right"
        case .worse:    return "arrow.down.right"
        case .neutral:  return "minus"
        }
    }

    var color: Color {
        switch self {
        case .better:   return HealthState.good.color
        case .worse:    return HealthState.poor.color
        case .neutral:  return HealthState.neutral.color
        }
    }
}

// MARK: - StrainMetricRow

struct StrainMetricRow: Identifiable {
    let id = UUID()
    let kind: StrainMetricKind
    let value: Double?
    let valueText: String
    /// Per-metric sub-score [0, 100]. `nil` when the metric or its baseline
    /// isn't available (cold-start, no target, server-only field).
    let subScore: Double?
    let delta: Double?
    /// Delta label — either a "±X vs 30j" trend or a confidence label for the
    /// target row (which has no trend delta).
    let deltaText: String?
    let deltaDirection: StrainDeltaDirection

    /// Recovery-style band for the sub-score badge color. Reuses `RecoveryBand`
    /// since the red/yellow/green thresholds (red < 34, yellow 34–67, green ≥ 67)
    /// are the right "how well am I doing" signal for the levers.
    var scoreBand: RecoveryBand {
        guard let subScore else { return .calibrating }
        return RecoveryBand(score: subScore)
    }

    var subScoreFraction: Double { min(max((subScore ?? 0) / 100, 0), 1) }
    var subScoreText: String { subScore.map { "\(Int($0.rounded()))%" } ?? "--" }
    var hasScore: Bool { subScore != nil }
}
