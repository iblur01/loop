import Foundation
import XCTest
@testable import LoopStrapEngine

final class TrainingAdviceRulesTests: XCTestCase {
    private let today = TrainingFixtures.today

    private func insight(_ code: String, in list: [TrainingInsight]) -> TrainingInsight? {
        list.first { $0.code == code }
    }

    // MARK: Load ratio

    func testCalibrationIsExplicitAndCitesDaysOfData() throws {
        var input = TrainingInputs(asOfDay: today)
        input.dailyLoads = TrainingFixtures.loads((today - 9)...today) { _ in 8 }
        let i = try XCTUnwrap(insight(TrainingInsightCode.loadRatio, in: TrainingAdviceEngine.insights(for: input)))
        XCTAssertEqual(i.state, .insufficientData)
        XCTAssertEqual(i.confidence, .low)
        XCTAssertEqual(i.shortKey, "training.load_ratio.calibration.short")
        XCTAssertEqual(i.fact("data_days")?.value, 10)
        XCTAssertEqual(i.fact("required_days")?.value, 21)
        assertNumbersTraceable(i)
        assertAllKeysLocalised(i)
    }

    func testHighRatioIsReportedWithFactsAndNoCategoricalAdvice() throws {
        var input = TrainingInputs(asOfDay: today)
        input.dailyLoads = TrainingFixtures.loads((today - 34)...today) { d in d > today - 7 ? 20 : 5 }
        let i = try XCTUnwrap(insight(TrainingInsightCode.loadRatio, in: TrainingAdviceEngine.insights(for: input)))
        XCTAssertEqual(i.state, .ok)
        XCTAssertEqual(i.shortKey, "training.load_ratio.high.short")
        XCTAssertEqual(i.confidence, .high)
        XCTAssertEqual(i.fact("data_days")?.value, 28)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(i.fact("ratio")?.value), TrainingAdviceEngine.ratioHigh)
        XCTAssertTrue(i.contributors.contains("acute_ewma_7d"))
        assertNumbersTraceable(i)
    }

    func testLowInputConfidenceDowngradesAndIsExplained() throws {
        var input = TrainingInputs(asOfDay: today)
        input.dailyLoads = TrainingFixtures.loads((today - 34)...today, confidence: .low) { d in 6 + TrainingFixtures.pseudo(d, 3) }
        let i = try XCTUnwrap(insight(TrainingInsightCode.loadRatio, in: TrainingAdviceEngine.insights(for: input)))
        XCTAssertEqual(i.confidence, .low)
        XCTAssertTrue(i.detailNoteKeys.contains("training.note.low_confidence_inputs"))
        XCTAssertTrue(i.contributors.contains("low_confidence_inputs"))
        assertNumbersTraceable(i)
    }

    func testZeroChronicLoadIsNotPresentedAsARatio() throws {
        var input = TrainingInputs(asOfDay: today)
        input.dailyLoads = TrainingFixtures.loads((today - 34)...today) { _ in 0 }
        let i = try XCTUnwrap(insight(TrainingInsightCode.loadRatio, in: TrainingAdviceEngine.insights(for: input)))
        XCTAssertEqual(i.state, .insufficientData)
        XCTAssertNil(i.fact("ratio"))
        assertNumbersTraceable(i)
    }

    // MARK: Contradictions

    private func conflictInput(lastNight: Double, recovery: Double, label: String? = nil) -> TrainingInputs {
        var input = TrainingInputs(asOfDay: today)
        input.sleep = TrainingFixtures.sleep((today - 34)...today) { d in
            d >= today - 1 ? lastNight : 440 + TrainingFixtures.pseudo(d, 5) * 4
        }
        input.recovery = [TrainingRecoveryDay(day: today, score: recovery, confidence: .high, experimentalLabel: label)]
        return input
    }

    func testShortSleepWithHighRecoveryIsContradictoryNotConcluded() throws {
        let input = conflictInput(lastNight: 300, recovery: 85, label: "expérimental")
        let list = TrainingAdviceEngine.insights(for: input)
        let i = try XCTUnwrap(insight(TrainingInsightCode.sleepRecoveryConflict, in: list))
        XCTAssertEqual(i.state, .contradictory)
        XCTAssertEqual(i.shortKey, "training.conflict.sleep_low_recovery_high.short")
        XCTAssertLessThanOrEqual(i.confidence, .medium)
        XCTAssertTrue(i.isExperimental)
        XCTAssertTrue(i.detailNoteKeys.contains("training.note.experimental_recovery"))
        XCTAssertEqual(i.fact("recovery_score")?.value, 85)
        XCTAssertEqual(try XCTUnwrap(i.fact("sleep_last_h")?.value), 5, accuracy: 1e-9)
        assertNumbersTraceable(i)
        assertAllKeysLocalised(i)
    }

    func testNormalSleepWithLowRecoveryIsContradictory() throws {
        let list = TrainingAdviceEngine.insights(for: conflictInput(lastNight: 445, recovery: 20))
        let i = try XCTUnwrap(insight(TrainingInsightCode.sleepRecoveryConflict, in: list))
        XCTAssertEqual(i.shortKey, "training.conflict.sleep_ok_recovery_low.short")
        XCTAssertFalse(i.isExperimental)
        XCTAssertFalse(i.detailNoteKeys.contains("training.note.experimental_recovery"))
    }

    func testConsistentSignalsRaiseNoConflict() {
        XCTAssertNil(insight(TrainingInsightCode.sleepRecoveryConflict,
                             in: TrainingAdviceEngine.insights(for: conflictInput(lastNight: 300, recovery: 20))))
        XCTAssertNil(insight(TrainingInsightCode.sleepRecoveryConflict,
                             in: TrainingAdviceEngine.insights(for: conflictInput(lastNight: 445, recovery: 80))))
    }

    func testFeelingAgainstRecoveryIsContradictory() throws {
        var input = TrainingInputs(asOfDay: today)
        input.recovery = [TrainingRecoveryDay(day: today, score: 82, confidence: .medium)]
        input.feelings = [TrainingFeelingDay(day: today, value: 1), TrainingFeelingDay(day: today, value: 2)]
        let i = try XCTUnwrap(insight(TrainingInsightCode.feelingRecoveryConflict,
                                      in: TrainingAdviceEngine.insights(for: input)))
        XCTAssertEqual(i.state, .contradictory)
        XCTAssertEqual(i.confidence, .low)
        XCTAssertEqual(i.fact("feeling")?.value, 1.5)
        assertNumbersTraceable(i)
        input.feelings = [TrainingFeelingDay(day: today, value: nil)]
        XCTAssertNil(insight(TrainingInsightCode.feelingRecoveryConflict, in: TrainingAdviceEngine.insights(for: input)))
    }

    // MARK: Sleep trend, coverage

    func testPartialSleepCoverageLowersConfidenceAndSaysSo() throws {
        var input = TrainingInputs(asOfDay: today)
        input.sleep = (today - 34...today).map {
            TrainingSleepNight(day: $0, durationMinutes: $0 > today - 7 ? 380 : 450, coverage: 0.5)
        }
        let i = try XCTUnwrap(insight(TrainingInsightCode.sleepTrend, in: TrainingAdviceEngine.insights(for: input)))
        XCTAssertEqual(i.confidence, .low)
        XCTAssertEqual(i.shortKey, "training.sleep_trend.down.short")
        XCTAssertEqual(i.fact("sleep_coverage_pct")?.value, 50)
        assertNumbersTraceable(i)
    }

    func testSleepTrendWithoutReferenceIsInsufficient() throws {
        var input = TrainingInputs(asOfDay: today)
        input.sleep = TrainingFixtures.sleep((today - 4)...today) { _ in 420 }
        let i = try XCTUnwrap(insight(TrainingInsightCode.sleepTrend, in: TrainingAdviceEngine.insights(for: input)))
        XCTAssertEqual(i.state, .insufficientData)
        assertNumbersTraceable(i)
    }

    // MARK: Volume per sport

    func testStrengthAndSwimVolumeCarryNoHeartRateClaim() throws {
        var input = TrainingInputs(asOfDay: today)
        input.dailyLoads = TrainingFixtures.loads((today - 40)...today) { _ in 5 }
        for k in 0..<4 {
            input.sessions.append(TrainingSession(id: "s\(k)", day: today - k * 3, sport: .strength, startTime: Double(k) * 90_000,
                                                  durationMinutes: 50, perceivedExertion: 6))
            input.sessions.append(TrainingSession(id: "w\(k)", day: today - k * 5, sport: .swim, startTime: Double(k) * 90_000 + 10,
                                                  durationMinutes: 30))
        }
        let list = TrainingAdviceEngine.insights(for: input)
        let strength = try XCTUnwrap(insight(TrainingInsightCode.volumeStrength, in: list))
        XCTAssertTrue(strength.detailNoteKeys.contains("training.note.no_hr_strength"))
        XCTAssertNotNil(strength.fact("srpe_load_recent"))
        let swim = try XCTUnwrap(insight(TrainingInsightCode.volumeSwim, in: list))
        XCTAssertTrue(swim.detailNoteKeys.contains("training.note.no_hr_swim"))
        XCTAssertNil(swim.fact("srpe_load_recent"))
        XCTAssertNil(insight(TrainingInsightCode.volumeRun, in: list))
        [strength, swim].forEach { assertNumbersTraceable($0); assertAllKeysLocalised($0) }
    }

    func testVolumeNeedsFourWeeksOfHistory() throws {
        var input = TrainingInputs(asOfDay: today)
        input.sessions = [TrainingSession(id: "r", day: today, sport: .run, durationMinutes: 30),
                          TrainingSession(id: "r2", day: today - 10, sport: .run, durationMinutes: 30)]
        let i = try XCTUnwrap(insight(TrainingInsightCode.volumeRun, in: TrainingAdviceEngine.insights(for: input)))
        XCTAssertEqual(i.state, .insufficientData)
        XCTAssertEqual(i.fact("tracked_days")?.value, 11)
        assertNumbersTraceable(i)
    }

    func testVolumeDirectionUsesMinutesWhenAllDurationsKnown() throws {
        var input = TrainingInputs(asOfDay: today)
        input.dailyLoads = TrainingFixtures.loads((today - 40)...today) { _ in 5 }
        // prior 21 days: 3 sessions of 30 min (30 min mean per 7 days); recent 7 days: 2 x 60 min
        input.sessions = [-8, -14, -20].map { TrainingSession(id: "p\($0)", day: today + $0, sport: .run, durationMinutes: 30) }
            + [0, -3].map { TrainingSession(id: "q\($0)", day: today + $0, sport: .run, durationMinutes: 60) }
        let i = try XCTUnwrap(insight(TrainingInsightCode.volumeRun, in: TrainingAdviceEngine.insights(for: input)))
        XCTAssertEqual(i.shortKey, "training.volume.run.up.short")
        XCTAssertEqual(i.fact("recent_minutes")?.value, 120)
        XCTAssertEqual(i.fact("prior_minutes_mean")?.value, 30)
        assertNumbersTraceable(i)
    }

    // MARK: Change and links

    func testChangeInsightIsCappedAndFlaggedWhenRecoveryIsExperimental() throws {
        var input = TrainingInputs(asOfDay: today)
        input.recovery = ((today - 41)...today).map { d in
            TrainingRecoveryDay(day: d, score: d > today - 14 ? 85 : 50 + TrainingFixtures.pseudo(d, 3) * 2,
                                confidence: .high, experimentalLabel: "expérimental")
        }
        let i = try XCTUnwrap(insight(TrainingInsightCode.changeRecovery, in: TrainingAdviceEngine.insights(for: input)))
        XCTAssertEqual(i.state, .ok)
        XCTAssertLessThanOrEqual(i.confidence, .medium)
        XCTAssertTrue(i.isExperimental)
        XCTAssertEqual(i.fact("recent_points")?.value, 14)
        XCTAssertEqual(i.fact("onset_days_ago")?.value, 13)
        assertNumbersTraceable(i)
    }

    func testExploratoryLinkCarriesCaveatAndNeverHighConfidence() throws {
        var input = TrainingInputs(asOfDay: today)
        input.sleep = TrainingFixtures.sleep((today - 39)...today) { d in 400 + Double((d * 37) % 60) }
        input.recovery = ((today - 39)...today).map { d in
            TrainingRecoveryDay(day: d, score: 40 + (400 + Double((d * 37) % 60)) / 10, confidence: .medium)
        }
        let list = TrainingAdviceEngine.insights(for: input)
        let i = try XCTUnwrap(insight(TrainingInsightCode.linkSleepRecovery, in: list))
        XCTAssertEqual(i.state, .ok)
        XCTAssertEqual(i.shortKey, "training.link.sleep_recovery.pos.short")
        XCTAssertEqual(i.confidence, .medium)
        XCTAssertEqual(i.detailNoteKeys.first, LinkStat.noteKey)
        XCTAssertTrue(TrainingInsightRenderer.detail(i).contains("pas une causalité"))
        XCTAssertEqual(i.fact("n")?.value, 40)
        assertNumbersTraceable(i)
        for l in list where l.code.hasPrefix("TRAINING_LINK_") {
            XCTAssertNotEqual(l.confidence, .high)
            XCTAssertTrue(l.detailNoteKeys.contains(LinkStat.noteKey))
        }
    }

    func testTooFewPairsGivesInsufficientLinkInsight() throws {
        var input = TrainingInputs(asOfDay: today)
        input.sleep = TrainingFixtures.sleep((today - 7)...today) { d in 400 + Double(d % 9) }
        input.recovery = ((today - 7)...today).map { TrainingRecoveryDay(day: $0, score: 50 + Double($0 % 7)) }
        let i = try XCTUnwrap(insight(TrainingInsightCode.linkSleepRecovery, in: TrainingAdviceEngine.insights(for: input)))
        XCTAssertEqual(i.state, .insufficientData)
        XCTAssertEqual(i.fact("n")?.value, 8)
        XCTAssertEqual(i.fact("required_n")?.value, 14)
        assertNumbersTraceable(i)
    }
}
