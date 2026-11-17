import XCTest
@testable import Loop

// MARK: - RecoveryCoachModelTests
//
// Covers RecoveryCoachModel's pure logic:
//   - sub-score computation (HRV/RHR logistic, Sleep passthrough),
//   - 30-day baseline fold (mean + sample std-dev, selected day excluded),
//   - delta direction polarity (HRV/Sleep higher = better, RHR lower = better),
//   - WHOOP band thresholds (red < 34, yellow 34–67, green ≥ 67),
//   - cold-start / missing-data fallbacks (nil score, "--" rows).
final class RecoveryCoachModelTests: XCTestCase {

    // MARK: - Helpers

    /// Builds a DailySnapshot with only the fields the model reads, leaving the
    /// rest at sensible defaults. Date is `YYYY-MM-DD` (the project's day key).
    private func makeMetric(
        date: String = "2026-06-15",
        recovery: Double? = 80,
        avgHrv: Double? = 60,
        restingHR: Double? = 50,
        sleepScore: Double? = 80
    ) -> DailySnapshot {
        DailySnapshot(
            date: date,
            totalSleepMin: 420,
            efficiency: 90,
            deepMin: 80,
            remMin: 100,
            lightMin: 240,
            disturbances: 3,
            sleepStart: nil,
            sleepEnd: nil,
            sleepScore: sleepScore,
            restingHR: restingHR,
            avgHrv: avgHrv,
            recovery: recovery,
            recoveryStatus: "high",
            recoveryBand: "green",
            strain: 12,
            sleepTargetMin: 480,
            targetStrain: 12,
            targetStrainConfidence: "high",
            recentOverload: false,
            adviceSignals: []
        )
    }

    /// Generates `count` synthetic history days strictly BEFORE `selectedDay`,
    /// each with HRV/RHR/Sleep values drawn from a deterministic pattern around
    /// the given baseline so the assertions stay exact.
    private func makeHistory(
        before selectedDay: String,
        count: Int,
        hrvBase: Double = 60,
        rhrBase: Double = 50,
        sleepBase: Double = 80
    ) -> [DailySnapshot] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withFullDate]
        fmt.timeZone = TimeZone(identifier: "UTC")!
        guard let anchor = fmt.date(from: selectedDay) else { return [] }

        return (1...count).map { offset in
            let day = cal.date(byAdding: .day, value: -offset, to: anchor) ?? anchor
            return makeMetric(
                date: fmt.string(from: day),
                recovery: 75,
                avgHrv: hrvBase,
                restingHR: rhrBase,
                sleepScore: sleepBase
            )
        }
    }

    // MARK: - Band thresholds

    func testBandThresholdsMatchEngine() {
        // Mirrors Recovery.swift: red < 34, yellow 34–67, green ≥ 67.
        XCTAssertEqual(RecoveryBand(score: 0), .red)
        XCTAssertEqual(RecoveryBand(score: 33.9), .red)
        XCTAssertEqual(RecoveryBand(score: 34), .yellow)
        XCTAssertEqual(RecoveryBand(score: 66.9), .yellow)
        XCTAssertEqual(RecoveryBand(score: 67), .green)
        XCTAssertEqual(RecoveryBand(score: 100), .green)
    }

    func testScoreAndBandFromMetric() {
        let model = RecoveryCoachModel(metric: makeMetric(recovery: 85), history: [])
        XCTAssertEqual(model.score ?? -1, 85, accuracy: 0.001)
        XCTAssertEqual(model.band, .green)
        XCTAssertFalse(model.isCalibrating)
    }

    func testNilRecoveryIsCalibrating() {
        let model = RecoveryCoachModel(metric: makeMetric(recovery: nil), history: [])
        XCTAssertNil(model.score)
        XCTAssertTrue(model.isCalibrating)
        XCTAssertEqual(model.band, .calibrating)
    }

    // MARK: - Sub-score: HRV

    func testHrvSubScoreOnBaselineIsAroundFiftyEight() {
        // z = 0 → logistic(0) = 100 / (1 + exp(0)) = 50 — but the engine's anchor
        // is 100/(1+exp(-1.2*0)) = 50, not 58 (the comment refers to the composite
        // recovery score's population anchor, not the per-metric z=0 point).
        let history = makeHistory(before: "2026-06-15", count: 30, hrvBase: 60)
        let metric = makeMetric(date: "2026-06-15", avgHrv: 60)
        let model = RecoveryCoachModel(metric: metric, history: history)

        let hrv = model.metrics.first { $0.kind == .hrv }
        XCTAssertNotNil(hrv?.subScore)
        XCTAssertEqual(hrv?.subScore ?? -1, 50.0, accuracy: 0.01)
        XCTAssertEqual(hrv?.delta ?? 999, 0.0, accuracy: 0.001)
        XCTAssertEqual(hrv?.deltaDirection, .neutral)
    }

    func testHrvAboveBaselineScoresHigherAndBetter() {
        let history = makeHistory(before: "2026-06-15", count: 30, hrvBase: 60)
        let metric = makeMetric(date: "2026-06-15", avgHrv: 75)
        let model = RecoveryCoachModel(metric: metric, history: history)

        let hrv = model.metrics.first { $0.kind == .hrv }!
        XCTAssertGreaterThan(hrv.subScore ?? 0, 50)
        XCTAssertEqual(hrv.delta ?? 999, 15.0, accuracy: 0.001)
        XCTAssertEqual(hrv.deltaDirection, .better)
        XCTAssertEqual(hrv.valueText, "75 ms")
    }

    func testHrvBelowBaselineScoresLowerAndWorse() {
        let history = makeHistory(before: "2026-06-15", count: 30, hrvBase: 60)
        let metric = makeMetric(date: "2026-06-15", avgHrv: 45)
        let model = RecoveryCoachModel(metric: metric, history: history)

        let hrv = model.metrics.first { $0.kind == .hrv }!
        XCTAssertLessThan(hrv.subScore ?? 100, 50)
        XCTAssertEqual(hrv.deltaDirection, .worse)
    }

    // MARK: - Sub-score: RHR (inverted polarity)

    func testRhrSubScoreInvertedPolarity() {
        // RHR lower than baseline = better recovery.
        let history = makeHistory(before: "2026-06-15", count: 30, rhrBase: 50)
        let metric = makeMetric(date: "2026-06-15", restingHR: 46)
        let model = RecoveryCoachModel(metric: metric, history: history)

        let rhr = model.metrics.first { $0.kind == .rhr }!
        XCTAssertGreaterThan(rhr.subScore ?? 0, 50)
        XCTAssertEqual(rhr.delta ?? 999, -4.0, accuracy: 0.001)
        XCTAssertEqual(rhr.deltaDirection, .better, "RHR below baseline should be 'better'")
        XCTAssertEqual(rhr.valueText, "46 bpm")
    }

    func testRhrAboveBaselineIsWorse() {
        let history = makeHistory(before: "2026-06-15", count: 30, rhrBase: 50)
        let metric = makeMetric(date: "2026-06-15", restingHR: 55)
        let model = RecoveryCoachModel(metric: metric, history: history)

        let rhr = model.metrics.first { $0.kind == .rhr }!
        XCTAssertLessThan(rhr.subScore ?? 100, 50)
        XCTAssertEqual(rhr.deltaDirection, .worse)
    }

    // MARK: - Sub-score: Sleep (passthrough)

    func testSleepSubScorePassthrough() {
        // Sleep score is already 0–100, no z-score fold — sub-score == value.
        let history = makeHistory(before: "2026-06-15", count: 30, sleepBase: 80)
        let metric = makeMetric(date: "2026-06-15", sleepScore: 88)
        let model = RecoveryCoachModel(metric: metric, history: history)

        let sleep = model.metrics.first { $0.kind == .sleep }!
        XCTAssertEqual(sleep.subScore ?? -1, 88, accuracy: 0.001)
        XCTAssertEqual(sleep.delta ?? 999, 8.0, accuracy: 0.001)
        XCTAssertEqual(sleep.deltaDirection, .better)
        XCTAssertEqual(sleep.valueText, "88%")
    }

    // MARK: - Resp row (supprimée 2026-06-19 — champ server-only absent en local-first)

    // La row `resp` était toujours "--" en local-first (champ server-only absent de
    // `DailySnapshot`). Elle a été retirée de `RecoveryCoachModel.metrics` le 2026-06-19
    // (cf. loop-redesign/02-champs-boutons-inutiles.md). Elle sera réintroduite quand un
    // calculateur local de fréquence respiratoire sera câblé. Test précédent supprimé.

    // MARK: - Metrics row order

    func testMetricsRowOrderMatchesWhoop() {
        let model = RecoveryCoachModel(metric: makeMetric(), history: [])
        XCTAssertEqual(model.metrics.map(\.kind), [.hrv, .rhr, .sleep])
    }

    // MARK: - Lookback window

    func testLookbackExcludesSelectedDay() {
        // The selected day (2026-06-15) is in history but must not bias its own
        // baseline — even with HRV=99 on the selected day, the baseline must
        // remain the prior-days mean.
        var history = makeHistory(before: "2026-06-15", count: 30, hrvBase: 60)
        history.append(makeMetric(date: "2026-06-15", avgHrv: 99))
        let metric = makeMetric(date: "2026-06-15", avgHrv: 99)
        let model = RecoveryCoachModel(metric: metric, history: history)

        let hrv = model.metrics.first { $0.kind == .hrv }!
        // Baseline is still 60 → delta = 99 - 60 = 39, not 0.
        XCTAssertEqual(hrv.delta ?? 999, 39.0, accuracy: 0.001)
    }

    func testLookbackCappedAt30Days() {
        // 60 days of history at HRV=60 + 1 older day at HRV=200. If the lookback
        // is correctly capped at 30, the 200 shouldn't leak into the baseline.
        var history = makeHistory(before: "2026-06-15", count: 60, hrvBase: 60)
        // Inject one outlier 31 days back (just outside the 30-day window).
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withFullDate]
        fmt.timeZone = TimeZone(identifier: "UTC")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let anchor = fmt.date(from: "2026-06-15")!
        let outlierDay = cal.date(byAdding: .day, value: -31, to: anchor)!
        history.append(makeMetric(date: fmt.string(from: outlierDay), avgHrv: 200))
        let metric = makeMetric(date: "2026-06-15", avgHrv: 60)
        let model = RecoveryCoachModel(metric: metric, history: history)

        let hrv = model.metrics.first { $0.kind == .hrv }!
        // Baseline = mean of the last 30 prior days (all 60) → 60. Outlier excluded.
        XCTAssertEqual(hrv.delta ?? 999, 0.0, accuracy: 0.001)
    }

    // MARK: - Cold-start / missing data

    func testNoHistoryYieldsNilSubScoresButKeepsValues() {
        let metric = makeMetric(avgHrv: 60, restingHR: 50, sleepScore: 80)
        let model = RecoveryCoachModel(metric: metric, history: [])

        let hrv = model.metrics.first { $0.kind == .hrv }!
        XCTAssertNil(hrv.subScore, "No baseline → no HRV sub-score")
        XCTAssertNil(hrv.delta)
        XCTAssertEqual(hrv.valueText, "60 ms")
        XCTAssertEqual(hrv.deltaText, "--")

        let rhr = model.metrics.first { $0.kind == .rhr }!
        XCTAssertNil(rhr.subScore)
        XCTAssertEqual(rhr.valueText, "50 bpm")

        // Sleep passes through its 0–100 score even without history.
        let sleep = model.metrics.first { $0.kind == .sleep }!
        XCTAssertEqual(sleep.subScore ?? -1, 80, accuracy: 0.001)
    }

    func testBelowMinBaselineNightsYieldsNilDelta() {
        // 2 prior nights < minBaselineNights (3) → no baseline, no delta, no
        // sub-score. Prevents a "+50 bpm vs 30j" style false delta from a
        // too-small sample.
        let history = makeHistory(before: "2026-06-15", count: 2, hrvBase: 60, rhrBase: 50)
        let metric = makeMetric(date: "2026-06-15", avgHrv: 70, restingHR: 48)
        let model = RecoveryCoachModel(metric: metric, history: history)

        let hrv = model.metrics.first { $0.kind == .hrv }!
        XCTAssertNil(hrv.subScore)
        XCTAssertNil(hrv.delta)
        XCTAssertEqual(hrv.deltaText, "--")

        let rhr = model.metrics.first { $0.kind == .rhr }!
        XCTAssertNil(rhr.subScore)
        XCTAssertNil(rhr.delta)
    }

    func testNonPhysiologicZeroValuesFilteredFromBaseline() {
        // 30 prior nights where RHR is 0 (express snapshots / cold-start rows).
        // A naive mean would be 0 → delta for tonight's RHR=50 would show as
        // "+50 bpm vs 30j" (a false "worse" signal). The model must filter
        // non-positive RHR/HRV values out of the baseline so the delta stays
        // nil instead of fabricating a misleading comparison.
        let history = makeHistory(before: "2026-06-15", count: 30, rhrBase: 0)
        let metric = makeMetric(date: "2026-06-15", restingHR: 50)
        let model = RecoveryCoachModel(metric: metric, history: history)

        let rhr = model.metrics.first { $0.kind == .rhr }!
        XCTAssertNil(rhr.subScore, "RHR baseline of all-zeros must not produce a sub-score")
        XCTAssertNil(rhr.delta, "RHR baseline of all-zeros must not produce a delta")
        XCTAssertEqual(rhr.valueText, "50 bpm")
    }

    func testNilMetricValuesShowPlaceholders() {
        let metric = makeMetric(avgHrv: nil, restingHR: nil, sleepScore: nil)
        let model = RecoveryCoachModel(metric: metric, history: makeHistory(before: "2026-06-15", count: 30))

        let hrv = model.metrics.first { $0.kind == .hrv }!
        XCTAssertEqual(hrv.valueText, "--")
        XCTAssertNil(hrv.subScore)
        XCTAssertEqual(hrv.deltaText, "--")

        let rhr = model.metrics.first { $0.kind == .rhr }!
        XCTAssertEqual(rhr.valueText, "--")
        XCTAssertNil(rhr.subScore)

        let sleep = model.metrics.first { $0.kind == .sleep }!
        XCTAssertEqual(sleep.valueText, "--")
        XCTAssertNil(sleep.subScore)
    }

    // MARK: - Delta text formatting

    func testDeltaTextSignAndUnit() {
        let history = makeHistory(before: "2026-06-15", count: 30, hrvBase: 60)
        let metric = makeMetric(date: "2026-06-15", avgHrv: 65)
        let model = RecoveryCoachModel(metric: metric, history: history)

        let hrv = model.metrics.first { $0.kind == .hrv }!
        XCTAssertEqual(hrv.deltaText, "+5 ms vs 30j")
    }

    func testDeltaTextNegativeRhrHasLeadingMinus() {
        let history = makeHistory(before: "2026-06-15", count: 30, rhrBase: 50)
        let metric = makeMetric(date: "2026-06-15", restingHR: 47)
        let model = RecoveryCoachModel(metric: metric, history: history)

        let rhr = model.metrics.first { $0.kind == .rhr }!
        XCTAssertEqual(rhr.deltaText, "-3 bpm vs 30j")
    }

    func testAppleRecoveryDisplaysItsActualMethodAndEvidence() {
        let metric = DailySnapshot(date: "2026-06-15", totalSleepMin: 420, efficiency: 0.9,
            deepMin: 80, remMin: 100, lightMin: 240, disturbances: 3, sleepStart: nil, sleepEnd: nil,
            sleepScore: nil, restingHR: nil, avgHrv: nil, recovery: 55, recoveryStatus: "medium",
            recoveryBand: "yellow", strain: nil, sleepTargetMin: nil, targetStrain: nil,
            targetStrainConfidence: nil, recentOverload: nil, adviceSignals: [],
            recoveryZHrv: 0.5, recoveryZRhr: -0.2,
            healthSDNN: .init(value: 45, sourceID: "watch-a", sampleCount: 5),
            healthRestingHR: .init(value: 62, sourceID: "sleep-median-hr-v1|watch-a", sampleCount: 20),
            recoveryHRVMetric: "sdnn", recoveryHRVObservation: .init(value: 45, sourceID: "watch-a", sampleCount: 5),
            recoveryRHRObservation: .init(value: 62, sourceID: "sleep-median-hr-v1|watch-a", sampleCount: 20))
        let model = RecoveryCoachModel(metric: metric)
        let hrv = model.metrics.first { $0.kind == .hrv }!
        let rhr = model.metrics.first { $0.kind == .rhr }!
        XCTAssertEqual(hrv.valueText, "45 ms · SDNN")
        XCTAssertEqual(rhr.valueText, "62 bpm · médiane nuit")
        XCTAssertEqual(rhr.label, "FC médiane de nuit")
        XCTAssertNotNil(hrv.subScore)
        XCTAssertNotNil(rhr.subScore)
        XCTAssertTrue(model.explanation.contains("expérimentale"))
        XCTAssertTrue(model.headline.contains("estimée"))
    }
}
