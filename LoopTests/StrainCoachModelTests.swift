import XCTest
@testable import Loop

// MARK: - StrainCoachModelTests
//
// Covers StrainCoachModel's pure logic:
//   - effort alignment score (at target = 100, under/overshoot diminishing),
//   - confidence → score mapping for the target row,
//   - recovery passthrough,
//   - RHR z-score sub-score (inverted: lower = better strain capacity),
//   - 30-day baseline fold (min 3 nights, non-physiologic zeros filtered),
//   - strain band thresholds (easy < 9, moderate 9–13, high 13–17, veryHigh ≥ 17),
//   - cold-start / missing-data fallbacks.
final class StrainCoachModelTests: XCTestCase {

    // MARK: - Helpers

    private func makeMetric(
        date: String = "2026-06-15",
        strain: Double? = 14.2,
        targetStrain: Double? = 12.4,
        targetStrainConfidence: String? = "high",
        recovery: Double? = 85,
        restingHR: Double? = 50
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
            sleepScore: 82,
            restingHR: restingHR,
            avgHrv: 68,
            recovery: recovery,
            recoveryStatus: "high",
            recoveryBand: "green",
            strain: strain,
            sleepTargetMin: 480,
            targetStrain: targetStrain,
            targetStrainConfidence: targetStrainConfidence,
            recentOverload: false,
            adviceSignals: []
        )
    }

    private func makeHistory(
        before selectedDay: String,
        count: Int,
        strainBase: Double = 12,
        rhrBase: Double = 50,
        recoveryBase: Double = 75
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
                strain: strainBase,
                targetStrain: 12,
                targetStrainConfidence: "high",
                recovery: recoveryBase,
                restingHR: rhrBase
            )
        }
    }

    // MARK: - Band thresholds

    func testBandThresholdsMatchWhoop() {
        XCTAssertEqual(StrainBand(strain: 0), .easy)
        XCTAssertEqual(StrainBand(strain: 8.9), .easy)
        XCTAssertEqual(StrainBand(strain: 9), .moderate)
        XCTAssertEqual(StrainBand(strain: 12.9), .moderate)
        XCTAssertEqual(StrainBand(strain: 13), .high)
        XCTAssertEqual(StrainBand(strain: 16.9), .high)
        XCTAssertEqual(StrainBand(strain: 17), .veryHigh)
        XCTAssertEqual(StrainBand(strain: 21), .veryHigh)
    }

    func testStrainAndBandFromMetric() {
        let model = StrainCoachModel(metric: makeMetric(strain: 14.2), history: [])
        XCTAssertEqual(model.strain ?? -1, 14.2, accuracy: 0.001)
        XCTAssertEqual(model.band, .high)
        XCTAssertFalse(model.isCalibrating)
    }

    func testNilStrainIsCalibrating() {
        let model = StrainCoachModel(metric: makeMetric(strain: nil), history: [])
        XCTAssertNil(model.strain)
        XCTAssertTrue(model.isCalibrating)
        XCTAssertEqual(model.band, .calibrating)
    }

    // MARK: - Metrics row order

    func testMetricsRowOrder() {
        let model = StrainCoachModel(metric: makeMetric(), history: [])
        XCTAssertEqual(model.metrics.map(\.kind), [.effort, .target, .recovery, .rhr])
    }

    // MARK: - Effort alignment score

    func testEffortAtTargetScores100() {
        let model = StrainCoachModel(metric: makeMetric(strain: 12, targetStrain: 12), history: [])
        let effort = model.metrics.first { $0.kind == .effort }!
        XCTAssertEqual(effort.subScore ?? -1, 100, accuracy: 0.001)
        XCTAssertEqual(effort.valueText, "12.0")
    }

    func testEffortBelowTargetScoresProportionally() {
        // strain=6, target=12 → 50%
        let model = StrainCoachModel(metric: makeMetric(strain: 6, targetStrain: 12), history: [])
        let effort = model.metrics.first { $0.kind == .effort }!
        XCTAssertEqual(effort.subScore ?? -1, 50, accuracy: 0.001)
    }

    func testEffortOvershootDiminishesScore() {
        // strain=14, target=12 → overshoot=2 → 100 - 2*15 = 70
        let model = StrainCoachModel(metric: makeMetric(strain: 14, targetStrain: 12), history: [])
        let effort = model.metrics.first { $0.kind == .effort }!
        XCTAssertEqual(effort.subScore ?? -1, 70, accuracy: 0.001)
    }

    func testEffortBigOvershootFloorsAtZero() {
        // strain=20, target=12 → overshoot=8 → 100 - 8*15 = -20 → clamped to 0
        let model = StrainCoachModel(metric: makeMetric(strain: 20, targetStrain: 12), history: [])
        let effort = model.metrics.first { $0.kind == .effort }!
        XCTAssertEqual(effort.subScore ?? -1, 0, accuracy: 0.001)
    }

    func testEffortNoTargetYieldsNilScore() {
        let model = StrainCoachModel(metric: makeMetric(strain: 14, targetStrain: nil), history: [])
        let effort = model.metrics.first { $0.kind == .effort }!
        XCTAssertNil(effort.subScore)
    }

    // MARK: - Target row (confidence → score)

    func testTargetHighConfidenceScores90() {
        let model = StrainCoachModel(
            metric: makeMetric(targetStrain: 12, targetStrainConfidence: "high"),
            history: []
        )
        let target = model.metrics.first { $0.kind == .target }!
        XCTAssertEqual(target.subScore ?? -1, 90, accuracy: 0.001)
        XCTAssertEqual(target.valueText, "12.0")
        XCTAssertEqual(target.deltaText, "Confiance haute")
    }

    func testTargetMediumConfidenceScores60() {
        let model = StrainCoachModel(
            metric: makeMetric(targetStrain: 12, targetStrainConfidence: "medium"),
            history: []
        )
        let target = model.metrics.first { $0.kind == .target }!
        XCTAssertEqual(target.subScore ?? -1, 60, accuracy: 0.001)
        XCTAssertEqual(target.deltaText, "Confiance moyenne")
    }

    func testTargetLowConfidenceScores30() {
        let model = StrainCoachModel(
            metric: makeMetric(targetStrain: 12, targetStrainConfidence: "low"),
            history: []
        )
        let target = model.metrics.first { $0.kind == .target }!
        XCTAssertEqual(target.subScore ?? -1, 30, accuracy: 0.001)
        XCTAssertEqual(target.deltaText, "Confiance basse")
    }

    func testNilTargetYieldsNilScore() {
        let model = StrainCoachModel(
            metric: makeMetric(targetStrain: nil, targetStrainConfidence: nil),
            history: []
        )
        let target = model.metrics.first { $0.kind == .target }!
        XCTAssertNil(target.subScore)
        XCTAssertEqual(target.valueText, "--")
    }

    // MARK: - Recovery passthrough

    func testRecoveryPassthrough() {
        let model = StrainCoachModel(metric: makeMetric(recovery: 85), history: [])
        let recovery = model.metrics.first { $0.kind == .recovery }!
        XCTAssertEqual(recovery.subScore ?? -1, 85, accuracy: 0.001)
        XCTAssertEqual(recovery.valueText, "85%")
    }

    func testNilRecoveryShowsPlaceholder() {
        let model = StrainCoachModel(metric: makeMetric(recovery: nil), history: [])
        let recovery = model.metrics.first { $0.kind == .recovery }!
        XCTAssertEqual(recovery.valueText, "--")
        XCTAssertNil(recovery.subScore)
    }

    // MARK: - RHR (inverted: lower = better strain capacity)

    func testRhrBelowBaselineScoresHigher() {
        let history = makeHistory(before: "2026-06-15", count: 30, rhrBase: 50)
        let metric = makeMetric(date: "2026-06-15", restingHR: 46)
        let model = StrainCoachModel(metric: metric, history: history)

        let rhr = model.metrics.first { $0.kind == .rhr }!
        XCTAssertGreaterThan(rhr.subScore ?? 0, 50)
        XCTAssertEqual(rhr.delta ?? 999, -4.0, accuracy: 0.001)
        XCTAssertEqual(rhr.deltaDirection, .better, "RHR below baseline = better strain capacity")
        XCTAssertEqual(rhr.valueText, "46 bpm")
    }

    func testRhrAboveBaselineIsWorse() {
        let history = makeHistory(before: "2026-06-15", count: 30, rhrBase: 50)
        let metric = makeMetric(date: "2026-06-15", restingHR: 55)
        let model = StrainCoachModel(metric: metric, history: history)

        let rhr = model.metrics.first { $0.kind == .rhr }!
        XCTAssertLessThan(rhr.subScore ?? 100, 50)
        XCTAssertEqual(rhr.deltaDirection, .worse)
    }

    // MARK: - Strain delta (neutral direction)

    func testStrainDeltaIsNeutral() {
        let history = makeHistory(before: "2026-06-15", count: 30, strainBase: 10)
        let metric = makeMetric(date: "2026-06-15", strain: 14, targetStrain: 12)
        let model = StrainCoachModel(metric: metric, history: history)

        let effort = model.metrics.first { $0.kind == .effort }!
        // Delta = 14 - 10 = +4.0, direction is neutral (strain isn't good/bad)
        XCTAssertEqual(effort.delta ?? 999, 4.0, accuracy: 0.001)
        XCTAssertEqual(effort.deltaDirection, .neutral)
        XCTAssertEqual(effort.deltaText, "+4.0 vs 30j")
    }

    // MARK: - Baseline gating

    func testBelowMinBaselineNightsYieldsNilDelta() {
        let history = makeHistory(before: "2026-06-15", count: 2, strainBase: 10, rhrBase: 50)
        let metric = makeMetric(date: "2026-06-15", strain: 14, restingHR: 48)
        let model = StrainCoachModel(metric: metric, history: history)

        let effort = model.metrics.first { $0.kind == .effort }!
        XCTAssertNil(effort.delta)

        let rhr = model.metrics.first { $0.kind == .rhr }!
        XCTAssertNil(rhr.delta)
        XCTAssertNil(rhr.subScore)
    }

    func testNonPhysiologicRhrZerosFilteredFromBaseline() {
        let history = makeHistory(before: "2026-06-15", count: 30, rhrBase: 0)
        let metric = makeMetric(date: "2026-06-15", restingHR: 50)
        let model = StrainCoachModel(metric: metric, history: history)

        let rhr = model.metrics.first { $0.kind == .rhr }!
        XCTAssertNil(rhr.subScore, "RHR baseline of all-zeros must not produce a sub-score")
        XCTAssertNil(rhr.delta)
        XCTAssertEqual(rhr.valueText, "50 bpm")
    }

    func testLookbackExcludesSelectedDay() {
        var history = makeHistory(before: "2026-06-15", count: 30, strainBase: 10)
        history.append(makeMetric(date: "2026-06-15", strain: 20))
        let metric = makeMetric(date: "2026-06-15", strain: 20, targetStrain: 12)
        let model = StrainCoachModel(metric: metric, history: history)

        let effort = model.metrics.first { $0.kind == .effort }!
        // Baseline stays 10 (selected day excluded) → delta = 20 - 10 = 10
        XCTAssertEqual(effort.delta ?? 999, 10.0, accuracy: 0.001)
    }

    // MARK: - Cold-start

    func testNoHistoryYieldsNilDeltasButKeepsValues() {
        let metric = makeMetric(strain: 14, targetStrain: 12, recovery: 85, restingHR: 50)
        let model = StrainCoachModel(metric: metric, history: [])

        let effort = model.metrics.first { $0.kind == .effort }!
        // Effort sub-score only needs strain + target, not history
        XCTAssertEqual(effort.subScore ?? -1, 100 - (14 - 12) * 15, accuracy: 0.001)
        XCTAssertNil(effort.delta)

        let rhr = model.metrics.first { $0.kind == .rhr }!
        XCTAssertNil(rhr.subScore, "No baseline → no RHR sub-score")
        XCTAssertNil(rhr.delta)
        XCTAssertEqual(rhr.valueText, "50 bpm")

        // Recovery and target don't need history
        let recovery = model.metrics.first { $0.kind == .recovery }!
        XCTAssertEqual(recovery.subScore ?? -1, 85, accuracy: 0.001)

        let target = model.metrics.first { $0.kind == .target }!
        XCTAssertEqual(target.subScore ?? -1, 90, accuracy: 0.001)
    }

    // MARK: - Delta text formatting

    func testStrainDeltaFormatting() {
        let history = makeHistory(before: "2026-06-15", count: 30, strainBase: 10)
        let metric = makeMetric(date: "2026-06-15", strain: 12.5, targetStrain: 12)
        let model = StrainCoachModel(metric: metric, history: history)

        let effort = model.metrics.first { $0.kind == .effort }!
        XCTAssertEqual(effort.deltaText, "+2.5 vs 30j")
    }

    func testRhrDeltaFormatting() {
        let history = makeHistory(before: "2026-06-15", count: 30, rhrBase: 50)
        let metric = makeMetric(date: "2026-06-15", restingHR: 47)
        let model = StrainCoachModel(metric: metric, history: history)

        let rhr = model.metrics.first { $0.kind == .rhr }!
        XCTAssertEqual(rhr.deltaText, "-3 bpm vs 30j")
    }
}
