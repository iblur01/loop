import Foundation
import XCTest
@testable import LoopStrapEngine

final class TrainingStatsInvariantsTests: XCTestCase {
    private let today = TrainingFixtures.today

    // MARK: Order, determinism

    func testDayOrderOfInputsDoesNotChangeReportOrInsights() {
        let input = TrainingFixtures.rich()
        let shuffled = TrainingFixtures.reordered(input)
        XCTAssertEqual(TrainingStats.compute(input), TrainingStats.compute(shuffled))
        XCTAssertEqual(TrainingAdviceEngine.insights(for: input), TrainingAdviceEngine.insights(for: shuffled))
    }

    func testComputationIsDeterministic() {
        let input = TrainingFixtures.rich()
        XCTAssertEqual(TrainingStats.compute(input), TrainingStats.compute(input))
        XCTAssertEqual(TrainingAdviceEngine.insights(for: input), TrainingAdviceEngine.insights(for: input))
    }

    // MARK: Session de-duplication

    private func sessions(_ list: [TrainingSession]) -> [TrainingSession] {
        TrainingDataset(TrainingInputs(asOfDay: today, sessions: list)).sessions
    }

    func testSameSessionIdIsCountedOnceAndFieldsAreMerged() {
        let a = TrainingSession(id: "x", day: today, sport: .run, startTime: 1_000, durationMinutes: 30,
                                cardioLoad: 5, source: "band")
        let b = TrainingSession(id: "x", day: today, sport: .run, startTime: 1_000, durationMinutes: 30,
                                perceivedExertion: 6, source: "health")
        let kept = sessions([a, b, a])
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?.cardioLoad, 5)
        XCTAssertEqual(kept.first?.perceivedExertion, 6)
        XCTAssertEqual(sessions([b, a, a]), kept)
    }

    func testSameEffortFromTwoSourcesWithDifferentIdsIsCountedOnce() {
        let start = Double(today) * 86_400 + 25_000
        let a = TrainingSession(id: "a", day: today, sport: .run, startTime: start, durationMinutes: 45, source: "band")
        let b = TrainingSession(id: "b", day: today, sport: .run, startTime: start + 60, durationMinutes: 44, source: "health")
        XCTAssertEqual(sessions([a, b]).count, 1)
    }

    func testSimultaneousDifferentSportsAreBothCounted() {
        let start = Double(today) * 86_400 + 25_000
        let run = TrainingSession(id: "r", day: today, sport: .run, startTime: start, durationMinutes: 45)
        let strength = TrainingSession(id: "s", day: today, sport: .strength, startTime: start, durationMinutes: 45)
        XCTAssertEqual(sessions([run, strength]).count, 2)
    }

    func testSameSportDistinctOrBarelyOverlappingSessionsAreBothCounted() {
        let start = Double(today) * 86_400 + 25_000
        let a = TrainingSession(id: "a", day: today, sport: .run, startTime: start, durationMinutes: 60)
        let later = TrainingSession(id: "b", day: today, sport: .run, startTime: start + 36_000, durationMinutes: 60)
        let halfOverlap = TrainingSession(id: "c", day: today, sport: .run, startTime: start + 1_800, durationMinutes: 60)
        XCTAssertEqual(sessions([a, later]).count, 2)
        XCTAssertEqual(sessions([a, halfOverlap]).count, 2)
    }

    func testSessionsWithoutStartTimeAndDistinctIdsAreNeverMerged() {
        let a = TrainingSession(id: "a", day: today, sport: .run, durationMinutes: 30)
        let b = TrainingSession(id: "b", day: today, sport: .run, durationMinutes: 30)
        XCTAssertEqual(sessions([a, b]).count, 2)
    }

    func testInvalidSessionNumbersBecomeNilNotZero() {
        let s = TrainingSession(id: "a", day: today, sport: .run, durationMinutes: -5, cardioLoad: .nan,
                                perceivedExertion: 14)
        let kept = sessions([s])
        XCTAssertEqual(kept.count, 1)
        XCTAssertNil(kept[0].durationMinutes)
        XCTAssertNil(kept[0].cardioLoad)
        XCTAssertNil(kept[0].perceivedExertion)
    }

    // MARK: Gaps, single day, nil, zero

    func testGapsInLoadDoNotCountAsZeroAndKeepRatioInCalibration() throws {
        var input = TrainingInputs(asOfDay: today)
        input.dailyLoads = TrainingFixtures.loads((today - 59)...today) { d in d % 2 == 0 ? 10 : nil }
        let report = TrainingStats.compute(input)
        XCTAssertEqual(report.load.dataDays, 14)
        XCTAssertEqual(report.load.status, .calibration)
        XCTAssertNil(report.load.ratio)
        XCTAssertEqual(try XCTUnwrap(report.load.acuteEWMA), 10, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(report.load.chronicEWMA), 10, accuracy: 1e-9)
    }

    func testNilValuesAreIgnoredAndZeroIsAKnownValue() {
        var withNil = TrainingInputs(asOfDay: today)
        withNil.dailyLoads = TrainingFixtures.loads((today - 6)...today) { d in d == today - 3 ? nil : 6 + Double(d - today) }
        var without = TrainingInputs(asOfDay: today)
        without.dailyLoads = withNil.dailyLoads.filter { $0.value != nil }
        XCTAssertEqual(TrainingStats.compute(withNil), TrainingStats.compute(without))
        XCTAssertEqual(TrainingStats.compute(withNil).monotony.knownDays, 6)

        var zeros = TrainingInputs(asOfDay: today)
        zeros.dailyLoads = TrainingFixtures.loads((today - 6)...today) { _ in 0 }
        XCTAssertEqual(TrainingStats.compute(zeros).monotony.knownDays, 7)
    }

    func testSingleDayOfDataNeverProducesConfidentOrFiniteTrouble() {
        var input = TrainingInputs(asOfDay: today)
        input.dailyLoads = [TrainingDailyLoad(day: today, value: 9, confidence: .high)]
        input.sleep = [TrainingSleepNight(day: today, durationMinutes: 400, efficiency: 0.9, coverage: 1)]
        input.recovery = [TrainingRecoveryDay(day: today, score: 55, confidence: .high)]
        input.sessions = [TrainingSession(id: "s", day: today, sport: .run, durationMinutes: 30)]
        let report = TrainingStats.compute(input)
        XCTAssertEqual(report.load.status, .calibration)
        XCTAssertEqual(report.regularity.status, .insufficientData)
        XCTAssertEqual(report.monotony.status, .insufficientData)
        XCTAssertTrue(report.trends.allSatisfy { $0.status == .insufficientData })
        XCTAssertTrue(report.changes.allSatisfy { $0.status == .insufficientData })
        XCTAssertTrue(report.links.allSatisfy { $0.status == .insufficientData })
        XCTAssertNil(report.regularity.intervalStdDev)
        for insight in TrainingAdviceEngine.insights(for: input) {
            XCTAssertNotEqual(insight.state, .ok, insight.code)
            XCTAssertEqual(insight.confidence, .low, insight.code)
        }
    }

    func testEmptyInputProducesEmptyEverythingWithoutCrash() {
        let input = TrainingInputs(asOfDay: today)
        let report = TrainingStats.compute(input)
        XCTAssertEqual(report.load.status, .noData)
        XCTAssertTrue(report.weeklyVolumes.isEmpty)
        XCTAssertNil(report.regularity.activeShare)
        XCTAssertNil(report.regularity.daysSinceLastSession)
        XCTAssertTrue(TrainingAdviceEngine.insights(for: input).isEmpty)
    }

    func testZeroAndConstantSeriesNeverDivideByZero() throws {
        var zero = TrainingInputs(asOfDay: today)
        zero.dailyLoads = TrainingFixtures.loads((today - 40)...today) { _ in 0 }
        let z = TrainingStats.compute(zero)
        XCTAssertEqual(z.load.status, .chronicNearZero)
        XCTAssertNil(z.load.ratio)
        XCTAssertEqual(z.monotony.status, .undefined)
        XCTAssertNil(z.monotony.monotony)
        XCTAssertNil(z.monotony.coefficientOfVariation)

        var constant = TrainingInputs(asOfDay: today)
        constant.dailyLoads = TrainingFixtures.loads((today - 40)...today) { _ in 7 }
        constant.sleep = TrainingFixtures.sleep((today - 40)...today) { _ in 450 }
        let c = TrainingStats.compute(constant)
        XCTAssertEqual(try XCTUnwrap(c.load.ratio), 1, accuracy: 1e-9)
        XCTAssertEqual(c.monotony.status, .undefined)
        let sleepTrend = try? XCTUnwrap(c.trend(.sleepDuration))
        XCTAssertEqual(sleepTrend?.status, .ok)
        XCTAssertEqual(try XCTUnwrap(sleepTrend?.deltaInMAD), 0, accuracy: 1e-9)
        XCTAssertEqual(c.change(.sleepDuration)?.status, .noChange)
        XCTAssertEqual(c.link(.sleepDurationToRecovery)?.status, .insufficientData)
    }

    // MARK: Temporal limits

    func testFutureEntriesAreIgnored() {
        let base = TrainingFixtures.rich()
        var withFuture = base
        withFuture.dailyLoads.append(TrainingDailyLoad(day: today + 1, value: 999, confidence: .high))
        withFuture.sleep.append(TrainingSleepNight(day: today + 2, durationMinutes: 100))
        withFuture.recovery.append(TrainingRecoveryDay(day: today + 1, score: 1))
        withFuture.sessions.append(TrainingSession(id: "future", day: today + 1, sport: .run, durationMinutes: 99))
        XCTAssertEqual(TrainingStats.compute(base), TrainingStats.compute(withFuture))
    }

    func testRatioRequiresExactlyTwentyOneDaysOfData() {
        func status(days: Int) -> LoadRatioStatus {
            var input = TrainingInputs(asOfDay: today)
            input.dailyLoads = TrainingFixtures.loads((today - days + 1)...today) { d in 5 + TrainingFixtures.pseudo(d, 3) }
            return TrainingStats.compute(input).load.status
        }
        XCTAssertEqual(status(days: 20), .calibration)
        XCTAssertEqual(status(days: 21), .available)
        XCTAssertEqual(status(days: 28), .available)
    }

    func testStaleLoadHistoryHasNoRecentData() {
        var input = TrainingInputs(asOfDay: today)
        input.dailyLoads = TrainingFixtures.loads((today - 60)...(today - 7)) { _ in 8 }
        XCTAssertEqual(TrainingStats.compute(input).load.status, .noRecentData)
    }

    func testTrendWindowBoundariesAreInclusive() {
        // recent = today-6...today, reference = today-34...today-7
        var series: [Int: Double] = [:]
        for d in (today - 34)...(today - 7) { series[d] = 100 }
        for d in (today - 6)...today { series[d] = 200 }
        let t = TrainingStats.trend(metric: .cardioLoad, series: series, asOfDay: today)
        XCTAssertEqual(t.recentCount, 7)
        XCTAssertEqual(t.referenceCount, 28)
        XCTAssertEqual(t.recentMedian, 200)
        XCTAssertEqual(t.referenceCenter, 100)
        series[today - 35] = 5_000      // outside the reference window
        XCTAssertEqual(TrainingStats.trend(metric: .cardioLoad, series: series, asOfDay: today), t)
    }

    // MARK: Calendar and weekly volumes

    func testWeekBucketingIsMondayBased() {
        XCTAssertEqual(TrainingCalendar.weekIndex(forDay: 3), 0)   // Sunday 1970-01-04
        XCTAssertEqual(TrainingCalendar.weekIndex(forDay: 4), 1)   // Monday 1970-01-05
        XCTAssertEqual(TrainingCalendar.weekStartDay(forWeek: 1), 4)
        XCTAssertEqual(TrainingCalendar.weekIndex(forDay: -3), 0)
        XCTAssertEqual(TrainingCalendar.weekIndex(forDay: -4), -1)
    }

    func testStrengthAndSwimMakeNoHeartRateClaimButRunDoes() throws {
        var input = TrainingInputs(asOfDay: today)
        input.sessions = [
            TrainingSession(id: "r", day: today, sport: .run, durationMinutes: 30, cardioLoad: 6),
            TrainingSession(id: "s", day: today, sport: .strength, startTime: 100, durationMinutes: 40,
                            cardioLoad: 9, perceivedExertion: 7),
            TrainingSession(id: "w", day: today, sport: .swim, startTime: 5_000, durationMinutes: 20, cardioLoad: 4)
        ]
        let volumes = TrainingStats.compute(input).weeklyVolumes
        let run = try XCTUnwrap(volumes.first { $0.sport == .run })
        let strength = try XCTUnwrap(volumes.first { $0.sport == .strength })
        let swim = try XCTUnwrap(volumes.first { $0.sport == .swim })
        XCTAssertEqual(try XCTUnwrap(run.cardioLoadPerHour), 12, accuracy: 1e-9)
        XCTAssertEqual(run.cardioLoadSum, 6)
        XCTAssertNil(strength.cardioLoadSum)
        XCTAssertNil(strength.cardioLoadPerHour)
        XCTAssertEqual(strength.srpeLoadSum, 280)
        XCTAssertEqual(strength.totalMinutes, 40)
        XCTAssertNil(swim.cardioLoadSum)
        XCTAssertNil(swim.cardioLoadPerHour)
        XCTAssertNil(swim.srpeLoadSum)
        XCTAssertEqual(swim.totalMinutes, 20)
    }

    func testUnknownDurationIsNotZeroMinutes() throws {
        var input = TrainingInputs(asOfDay: today)
        input.sessions = [TrainingSession(id: "r", day: today, sport: .run)]
        let run = try XCTUnwrap(TrainingStats.compute(input).weeklyVolumes.first)
        XCTAssertEqual(run.sessionCount, 1)
        XCTAssertNil(run.totalMinutes)
        XCTAssertNil(run.cardioLoadPerHour)
        XCTAssertNil(run.meanPerceivedExertion)
    }

    // MARK: Regularity

    func testRegularityIntervalsAndSpacing() throws {
        var input = TrainingInputs(asOfDay: today)
        // loads give 28 tracked days; sessions on days -20, -17, -10, -2
        input.dailyLoads = TrainingFixtures.loads((today - 27)...today) { _ in 5 }
        input.sessions = [-20, -17, -10, -2].map {
            TrainingSession(id: "s\($0)", day: today + $0, sport: .run, durationMinutes: 30)
        }
        let r = TrainingStats.compute(input).regularity
        XCTAssertEqual(r.status, .ok)
        XCTAssertEqual(r.trackedDays, 28)
        XCTAssertEqual(r.activeDays, 4)
        XCTAssertEqual(r.intervals, [3, 7, 8])
        XCTAssertEqual(r.maxInterval, 8)
        XCTAssertEqual(r.daysSinceLastSession, 2)
        XCTAssertEqual(try XCTUnwrap(r.meanInterval), 6, accuracy: 1e-9)
        XCTAssertNotNil(r.intervalStdDev)
    }

    // MARK: Monotony

    func testMonotonyMatchesDefinition() throws {
        var input = TrainingInputs(asOfDay: today)
        let values: [Double] = [2, 4, 6, 8, 10, 6, 4]
        input.dailyLoads = values.enumerated().map {
            TrainingDailyLoad(day: today - 6 + $0.offset, value: $0.element)
        }
        let m = TrainingStats.compute(input).monotony
        XCTAssertEqual(m.status, .ok)
        XCTAssertEqual(try XCTUnwrap(m.meanLoad), 40.0 / 7, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(m.monotony), 2.294, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(m.coefficientOfVariation), 1 / 2.294, accuracy: 0.01)
    }

    func testFewerThanFiveKnownDaysGivesNoMonotony() {
        var input = TrainingInputs(asOfDay: today)
        input.dailyLoads = TrainingFixtures.loads((today - 3)...today) { Double($0 - today + 10) }
        let m = TrainingStats.compute(input).monotony
        XCTAssertEqual(m.status, .insufficientData)
        XCTAssertNil(m.monotony)
    }

    // MARK: Duplicated daily values

    func testDuplicateDailyLoadsAreNotSummed() {
        var input = TrainingInputs(asOfDay: today)
        input.dailyLoads = [TrainingDailyLoad(day: today, value: 8, confidence: .high, source: "band"),
                            TrainingDailyLoad(day: today, value: 8, confidence: .low, source: "health")]
        let data = TrainingDataset(input)
        XCTAssertEqual(data.loads[today]?.value, 8)
        XCTAssertEqual(data.loads[today]?.confidence, .high)
        input.dailyLoads.reverse()
        XCTAssertEqual(TrainingDataset(input).loads, data.loads)
    }
}
