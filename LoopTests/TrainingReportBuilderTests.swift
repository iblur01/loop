import XCTest
@testable import Loop
import LoopStrapEngine
import WhoopStore

final class TrainingReportBuilderTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!

    private func snap(_ date: String, strain: Double?, sleep: Double? = 440, efficiency: Double? = 90,
                      recovery: Double = 70, hrvMetric: String? = nil) -> DailySnapshot {
        DailySnapshot(date: date, totalSleepMin: sleep, efficiency: efficiency, deepMin: nil, remMin: nil, lightMin: nil,
                      disturbances: 2, sleepStart: nil, sleepEnd: nil, sleepScore: nil, restingHR: 52, avgHrv: 60,
                      recovery: recovery, recoveryStatus: "high", recoveryBand: nil, strain: strain,
                      sleepTargetMin: nil, targetStrain: nil, targetStrainConfidence: nil, recentOverload: nil,
                      adviceSignals: [], recoveryHRVMetric: hrvMetric)
    }

    private func cache(daily: [DailySnapshot] = [], workouts: [WorkoutSession] = []) -> LoopCache {
        LoopCache(daily: daily, sleepSessions: [], workoutSessions: workouts, stress: nil, hrSamples: [], summary: nil, updatedAt: nil)
    }

    func testDayOrdinal() {
        XCTAssertEqual(TrainingReportBuilder.dayOrdinal("1970-01-01"), 0)
        XCTAssertEqual(TrainingReportBuilder.dayOrdinal("1970-01-11"), 10)
        XCTAssertNil(TrainingReportBuilder.dayOrdinal("2026-02-30"))
    }

    func testEmptyCacheGivesNoReport() {
        XCTAssertNil(TrainingReportBuilder.make(cache: cache(), today: "2026-11-14", deviceZone: utc))
    }

    func testReportBuiltFromCache() throws {
        let days = (0..<10).map { snap(LocalDay.adding(-$0, to: "2026-11-14"), strain: 10) }
        let report = try XCTUnwrap(TrainingReportBuilder.make(cache: cache(daily: days), today: "2026-11-14", deviceZone: utc))
        XCTAssertEqual(report.stats.asOfDay, TrainingReportBuilder.dayOrdinal("2026-11-14"))
        XCTAssertFalse(report.insights.isEmpty)
    }

    func testExpressSnapshotIsExcluded() throws {
        let past = (1..<10).map { snap(LocalDay.adding(-$0, to: "2026-11-14"), strain: 10) }
        var express = snap("2026-11-14", strain: 3)
        express.isExpress = true
        let without = try XCTUnwrap(TrainingReportBuilder.make(cache: cache(daily: past), today: "2026-11-14", deviceZone: utc))
        let with = try XCTUnwrap(TrainingReportBuilder.make(cache: cache(daily: past + [express]), today: "2026-11-14", deviceZone: utc))
        XCTAssertEqual(with, without)
        // Same snapshot, final: the report must differ, proving the comparison above is sensitive.
        let final = snap("2026-11-14", strain: 3)
        let included = try XCTUnwrap(TrainingReportBuilder.make(cache: cache(daily: past + [final]), today: "2026-11-14", deviceZone: utc))
        XCTAssertNotEqual(included, without)
    }

    func testDayWithoutWorkoutStillBuildsReport() throws {
        let days = (0..<10).map { snap(LocalDay.adding(-$0, to: "2026-11-14"), strain: 8) }
        let report = try XCTUnwrap(TrainingReportBuilder.make(cache: cache(daily: days, workouts: []), today: "2026-11-14", deviceZone: utc))
        XCTAssertTrue(report.stats.weeklyVolumes.allSatisfy { $0.srpeLoadSum == nil })
    }

    func testWorkoutWithoutRPEHasNoSRPELoad() throws {
        let start = Int(LocalDay.start("2026-11-13", in: utc)!) + 8 * 3600
        let w = WorkoutSession(deviceId: "d", startTs: start, endTs: start + 3600, avgHr: 140, peakHr: 170, strain: 8,
                               kind: "running", durationS: 3600, caloriesKcal: nil)
        XCTAssertNil(w.perceivedEffort)
        let report = try XCTUnwrap(TrainingReportBuilder.make(cache: cache(workouts: [w]), today: "2026-11-14", deviceZone: utc))
        XCTAssertNil(report.stats.weeklyVolumes.compactMap(\.srpeLoadSum).first)
    }

    func testNormalizedEfficiency() {
        XCTAssertEqual(TrainingReportBuilder.normalizedEfficiency(0.9), 0.9)
        XCTAssertEqual(TrainingReportBuilder.normalizedEfficiency(1), 1)
        XCTAssertEqual(try XCTUnwrap(TrainingReportBuilder.normalizedEfficiency(90)), 0.9, accuracy: 1e-12)
        XCTAssertNil(TrainingReportBuilder.normalizedEfficiency(nil))
        XCTAssertNil(TrainingReportBuilder.normalizedEfficiency(-0.1))
        XCTAssertNil(TrainingReportBuilder.normalizedEfficiency(150))
        XCTAssertNil(TrainingReportBuilder.normalizedEfficiency(.nan))
    }

    func testEfficiencyFractionAndPercentGiveSameReport() throws {
        func report(_ eff: Double) throws -> TrainingReport {
            let days = (0..<30).map { snap(LocalDay.adding(-$0, to: "2026-11-14"), strain: 8, efficiency: eff) }
            return try XCTUnwrap(TrainingReportBuilder.make(cache: cache(daily: days), today: "2026-11-14", deviceZone: utc))
        }
        XCTAssertEqual(try report(0.9), try report(90))
    }

    func testSleepRecoveryConflictIsExperimentalForHealthRecovery() throws {
        func conflict(hrvMetric: String?) throws -> TrainingInsight? {
            var days = (1..<35).map { snap(LocalDay.adding(-$0, to: "2026-11-14"), strain: 8,
                                           sleep: 440 + Double($0 % 5) * 4) }
            days.append(snap("2026-11-14", strain: 8, sleep: 300, recovery: 85, hrvMetric: hrvMetric))
            let report = try XCTUnwrap(TrainingReportBuilder.make(cache: cache(daily: days), today: "2026-11-14", deviceZone: utc))
            return report.insights.first { $0.code == TrainingInsightCode.sleepRecoveryConflict }
        }
        let experimental = try XCTUnwrap(conflict(hrvMetric: "sdnn"))
        XCTAssertEqual(experimental.state, .contradictory)
        XCTAssertTrue(experimental.isExperimental)
        let band = try XCTUnwrap(conflict(hrvMetric: nil))
        XCTAssertFalse(band.isExperimental)
    }

    func testPerceivedEffortReachesWeeklySRPE() throws {
        let start = Int(LocalDay.start("2026-11-13", in: utc)!) + 8 * 3600
        let w = WorkoutSession(deviceId: "d", startTs: start, endTs: start + 3600, avgHr: 140, peakHr: 170, strain: 8,
                               kind: "running", durationS: 3600, caloriesKcal: nil)
            .withPerceivedEffort(6)
        XCTAssertNotNil(w.rpeLoad)
        let report = try XCTUnwrap(TrainingReportBuilder.make(cache: cache(workouts: [w]), today: "2026-11-14", deviceZone: utc))
        XCTAssertNotNil(report.stats.weeklyVolumes.compactMap(\.srpeLoadSum).first)
        let noRPE = w.withPerceivedEffort(nil)
        XCTAssertNil(noRPE.rpeLoad)
    }
}
