import XCTest
@testable import Loop

// MARK: - SleepCoachModelTests
//
// Covers SleepCoachModel's real-hypnogram wiring:
//   - decoding SleepSession.stages into a full-resolution ribbon and using the
//     daily snapshot for the stage balance,
//   - showing no invented hypnogram when no session/stages are present,
//   - tolerating malformed stage payloads without throwing.
final class SleepCoachModelTests: XCTestCase {

    // MARK: - Helpers

    private func makeMetric() -> DailySnapshot {
        DailySnapshot(
            date: "2026-06-15",
            totalSleepMin: 420,
            efficiency: 90,
            deepMin: 80,
            remMin: 100,
            lightMin: 240,
            disturbances: 3,
            sleepStart: nil,
            sleepEnd: nil,
            sleepScore: 80,
            restingHR: 50,
            avgHrv: 60,
            recovery: 80,
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

    private func makeSession(stagesJSON: String?) -> SleepSession {
        SleepSession(
            startTs: 1000,
            endTs: 2800,
            efficiency: 0.9,
            restingHr: 50,
            avgHrv: 60,
            stages: stagesJSON?.data(using: .utf8)
        )
    }

    // MARK: - Real stages

    func testRealStagesDriveRibbonAndSnapshotDrivesBalance() {
        let json = """
        [{"start": 1000, "end": 1900, "stage": "light"},
         {"start": 1900, "end": 2200, "stage": "deep"},
         {"start": 2200, "end": 2800, "stage": "deep"}]
        """
        let model = SleepCoachModel(metric: makeMetric(), session: makeSession(stagesJSON: json))

        XCTAssertTrue(model.hasRealStages)

        // Ribbon keeps full resolution: 3 segments on the real epoch-second axis.
        XCTAssertEqual(model.ribbonSegments.count, 3)
        XCTAssertEqual(model.ribbonSegments.first?.from, Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(model.ribbonSegments.last?.to, Date(timeIntervalSince1970: 2800))

        // Real segments retain both adjacent deep runs, with their exact durations.
        XCTAssertEqual(model.ribbonSegments.map(\.stage), [.light, .deep, .deep])
        XCTAssertEqual(model.ribbonSegments.map(\.durationMinutes), [15, 5, 10])
        // The balance is sourced from the daily snapshot, not the ribbon.
        XCTAssertEqual(model.stageRows.map(\.stage), [.deep, .rem, .light])
        XCTAssertEqual(model.stageRows.map(\.minutes), [80, 100, 240])
    }

    // MARK: - Fallback (no session)

    func testNilSessionDoesNotInventHypnogram() {
        let model = SleepCoachModel(metric: makeMetric(), session: nil)
        XCTAssertFalse(model.hasRealStages)
        XCTAssertTrue(model.ribbonSegments.isEmpty)
    }

    // MARK: - Malformed payload

    func testMalformedStagesAreNotInvented() {
        let model = SleepCoachModel(metric: makeMetric(), session: makeSession(stagesJSON: "{not an array}"))

        XCTAssertFalse(model.hasRealStages)
        XCTAssertTrue(model.ribbonSegments.isEmpty)
    }
}
