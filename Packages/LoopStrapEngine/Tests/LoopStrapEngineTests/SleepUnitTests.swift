import XCTest
@testable import LoopStrapEngine

// MARK: - SleepUnitTests

/// Unit tests for the Sleep module primitives (SleepTypes, InBedDetection, EpochGrid).
/// RED phase: tests written before implementation.
final class SleepUnitTests: XCTestCase {

    // MARK: - SleepStage rawValues

    func testSleepStageRawValues() {
        XCTAssertEqual(SleepStage.wake.rawValue, "wake")
        XCTAssertEqual(SleepStage.light.rawValue, "light")
        XCTAssertEqual(SleepStage.deep.rawValue, "deep")
        XCTAssertEqual(SleepStage.rem.rawValue, "rem")
    }

    func testSleepStageFromRawValue() {
        XCTAssertEqual(SleepStage(rawValue: "wake"), .wake)
        XCTAssertEqual(SleepStage(rawValue: "light"), .light)
        XCTAssertEqual(SleepStage(rawValue: "deep"), .deep)
        XCTAssertEqual(SleepStage(rawValue: "rem"), .rem)
        XCTAssertNil(SleepStage(rawValue: "unknown"))
    }

    // MARK: - Module constants

    func testEpochSIs30() {
        XCTAssertEqual(epochS, 30.0)
    }

    func testHRVStrideEpochsIs4() {
        XCTAssertEqual(hrvStrideEpochs, 4)
    }

    func testGravThreshold() {
        XCTAssertEqual(gravThreshold, 0.013, accuracy: 1e-9)
    }

    func testMoveFracStillMax() {
        XCTAssertEqual(moveFracStillMax, 0.10, accuracy: 1e-9)
    }

    func testMoveFracMovingMin() {
        XCTAssertEqual(moveFracMovingMin, 0.15, accuracy: 1e-9)
    }

    // MARK: - EpochGrid struct

    func testEpochGridHasNEpochs() {
        let grid = EpochGrid(
            start: 0.0, end: 30.0, nEpochs: 1,
            counts: [0.0], moveFrac: [0.0], ckSleep: [true],
            hr: [60.0], rrBuckets: [[]], respBuckets: [[]]
        )
        XCTAssertEqual(grid.nEpochs, 1)
        XCTAssertEqual(grid.counts.count, 1)
        XCTAssertEqual(grid.moveFrac.count, 1)
        XCTAssertEqual(grid.ckSleep.count, 1)
    }

    // MARK: - EpochFeatures struct

    func testEpochFeaturesHasNaNFields() {
        let f = EpochFeatures(
            epochIdx: 0, hr: 60.0, hrVar: 0.5, rmssd: 40.0, sdnn: 50.0,
            hf: .nan, lf: .nan, lfhf: .nan,
            respRate: 15.0, rrv: 2.0, moveFrac: 0.05, ckSleep: true, clock: 0.0
        )
        XCTAssertTrue(f.hf.isNaN)
        XCTAssertTrue(f.lf.isNaN)
        XCTAssertTrue(f.lfhf.isNaN)
        XCTAssertEqual(f.epochIdx, 0)
        XCTAssertEqual(f.hr, 60.0)
        XCTAssertEqual(f.ckSleep, true)
    }

    // MARK: - StageSegment struct

    func testStageSegmentFields() {
        let seg = StageSegment(start: 100.0, end: 200.0, stage: .light)
        XCTAssertEqual(seg.start, 100.0)
        XCTAssertEqual(seg.end, 200.0)
        XCTAssertEqual(seg.stage, .light)
    }

    // MARK: - SleepSession struct

    func testSleepSessionHasEfficiency() {
        let seg = StageSegment(start: 100.0, end: 200.0, stage: .light)
        let session = SleepSession(
            start: 100.0, end: 200.0,
            stages: [seg],
            efficiency: 0.85,
            tst: 85.0, sol: 5.0, waso: 10.0,
            restingHR: 55.0, avgRmssd: 42.0, nDisturbances: 2
        )
        XCTAssertEqual(session.efficiency, 0.85, accuracy: 1e-9)
        XCTAssertEqual(session.nDisturbances, 2)
    }

    // MARK: - SleepStreams struct

    func testSleepStreamsFields() {
        let streams = SleepStreams(
            hr: [(t: 0.0, v: 60.0)],
            rr: [(t: 0.0, v: 800.0)],
            resp: [(t: 0.0, v: 1024.0)],
            gravity: [(t: 0.0, v: 0.001)]
        )
        XCTAssertEqual(streams.hr.count, 1)
        XCTAssertEqual(streams.rr.count, 1)
        XCTAssertEqual(streams.resp.count, 1)
        XCTAssertEqual(streams.gravity.count, 1)
    }

    // MARK: - detectInBedRuns

    func testDetectInBedRunsEmptyGravityReturnsEmpty() {
        let result = detectInBedRuns(gravTimes: [], gravValues: [], hrTimes: [], hrValues: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testDetectInBedRunsSingleGravityReturnsEmpty() {
        let result = detectInBedRuns(gravTimes: [0.0], gravValues: [0.001], hrTimes: [], hrValues: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testDetectInBedRunsAllActiveReturnsEmpty() {
        // gravValues are movement-proxy deltas now: 1.0 ≫ still threshold (0.01) → all moving.
        let times = (0..<200).map { Double($0) * 60.0 }
        let values = [Double](repeating: 1.0, count: 200)
        let result = detectInBedRuns(gravTimes: times, gravValues: values, hrTimes: [], hrValues: [])
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - rescaleCounts

    func testRescaleCountsEmptyInput() {
        let result = rescaleCounts([])
        XCTAssertTrue(result.isEmpty)
    }

    func testRescaleCountsDivideBy100() {
        let result = rescaleCounts([100.0])
        XCTAssertEqual(result[0], 1.0, accuracy: 1e-9)
    }

    func testRescaleCountsClipAt300() {
        let result = rescaleCounts([300_000.0])  // 300000 / 100 = 3000 > 300 → clipped
        XCTAssertEqual(result[0], 300.0, accuracy: 1e-9)
    }

    func testRescaleCountsKnownValues() {
        let result = rescaleCounts([0.0, 50.0, 100.0, 200.0, 30001.0])
        XCTAssertEqual(result[0], 0.0, accuracy: 1e-9)
        XCTAssertEqual(result[1], 0.5, accuracy: 1e-9)
        XCTAssertEqual(result[2], 1.0, accuracy: 1e-9)
        XCTAssertEqual(result[3], 2.0, accuracy: 1e-9)
        XCTAssertEqual(result[4], 300.0, accuracy: 1e-9)  // clipped
    }

    // MARK: - coleKripke

    func testColeKripkeEmptyInput() {
        let result = coleKripke([])
        XCTAssertTrue(result.isEmpty)
    }

    func testColeKripkeAllZeroCountsIsAsleep() {
        // All zero counts → SI = 0 < 1 → all sleep
        let counts = [Double](repeating: 0.0, count: 10)
        let result = coleKripke(counts)
        XCTAssertEqual(result.count, 10)
        XCTAssertTrue(result.allSatisfy { $0 == true })
    }

    func testColeKripkeHighCountsIsAwake() {
        // All max count (300) → SI >> 1 → all wake
        let counts = [Double](repeating: 300.0, count: 10)
        let result = coleKripke(counts)
        XCTAssertEqual(result.count, 10)
        XCTAssertTrue(result.allSatisfy { $0 == false })
    }

    // MARK: - buildEpochGrid

    func testBuildEpochGridEmptyRunsReturnsEmptyGrid() {
        let grid = buildEpochGrid(
            inBedRuns: [],
            hrTimes: [], hrValues: [],
            rrTimes: [], rrValues: [],
            respTimes: [], respValues: [],
            gravTimes: [], gravValues: []
        )
        XCTAssertEqual(grid.nEpochs, 0)
        XCTAssertTrue(grid.counts.isEmpty)
    }

    func testBuildEpochGridSingleRunProducesEpochs() {
        // A 90-second in-bed run → 3 epochs of 30 s
        let start = 0.0
        let end = 90.0
        let grid = buildEpochGrid(
            inBedRuns: [(start, end)],
            hrTimes: [], hrValues: [],
            rrTimes: [], rrValues: [],
            respTimes: [], respValues: [],
            gravTimes: [], gravValues: []
        )
        XCTAssertEqual(grid.nEpochs, 3)
        XCTAssertEqual(grid.counts.count, 3)
        XCTAssertEqual(grid.moveFrac.count, 3)
        XCTAssertEqual(grid.ckSleep.count, 3)
    }

    func testBuildEpochGridBoundaryTsEqualsEndAssignedToLastBucket() {
        // Piège 1: ts == end should be assigned to last bucket
        let start = 0.0
        let end = 60.0
        // Two gravity samples: at start (delta 0) and one moving sample exactly at end.
        // Second sample has large delta (1.0 g change) → last bucket gets a count.
        let grid = buildEpochGrid(
            inBedRuns: [(start, end)],
            hrTimes: [], hrValues: [],
            rrTimes: [], rrValues: [],
            respTimes: [], respValues: [],
            gravTimes: [start, end], gravValues: [0.0, 1.0]
        )
        XCTAssertEqual(grid.nEpochs, 2)
        // The sample at ts==end (delta 1.0) should be in counts[1] (last bucket), not lost.
        // counts stores rescaled values (÷100), but delta=1.0 → rescaled=0.01 > 0
        XCTAssertGreaterThan(grid.counts[1], 0.0)
    }

    // MARK: - hypnogramMetrics

    func testHypnogramMetricsEmptySegmentsReturnsZeroTST() {
        let (tst, sol, waso, efficiency, lightSecs, deepSecs, remSecs, wakeSecs, nDist) =
            hypnogramMetrics([])
        XCTAssertEqual(tst, 0.0, accuracy: 1e-12)
        XCTAssertEqual(sol, 0.0, accuracy: 1e-12)
        XCTAssertEqual(waso, 0.0, accuracy: 1e-12)
        XCTAssertEqual(efficiency, 0.0, accuracy: 1e-12)
        XCTAssertEqual(lightSecs, 0.0, accuracy: 1e-12)
        XCTAssertEqual(deepSecs, 0.0, accuracy: 1e-12)
        XCTAssertEqual(remSecs, 0.0, accuracy: 1e-12)
        XCTAssertEqual(wakeSecs, 0.0, accuracy: 1e-12)
        XCTAssertEqual(nDist, 0)
    }

    func testHypnogramMetricsAllWakeReturnsZeroTST() {
        // All-wake segments: TST = 0, efficiency = 0
        let stages = [
            StageSegment(start: 0.0, end: 1800.0, stage: .wake),
            StageSegment(start: 1800.0, end: 3600.0, stage: .wake)
        ]
        let (tst, _, _, efficiency, lightSecs, deepSecs, remSecs, _, _) =
            hypnogramMetrics(stages)
        XCTAssertEqual(tst, 0.0, accuracy: 1e-12)
        XCTAssertEqual(efficiency, 0.0, accuracy: 1e-12)
        XCTAssertEqual(lightSecs, 0.0, accuracy: 1e-12)
        XCTAssertEqual(deepSecs, 0.0, accuracy: 1e-12)
        XCTAssertEqual(remSecs, 0.0, accuracy: 1e-12)
    }

    func testHypnogramMetricsKnownSegment() {
        // Simple known hypnogram: 30 min light, then 10 min wake (WASO), then 20 min deep
        // TIB = 60 min = 3600 s
        // TST = 30 min + 20 min = 50 min = 3000 s
        // SOL = 0 (first segment is sleep)
        // WASO = 10 min = 600 s (the wake inside the sleep period)
        // efficiency = TST / TIB = 3000 / 3600
        let t0 = 0.0
        let stages = [
            StageSegment(start: t0,          end: t0 + 1800.0, stage: .light),
            StageSegment(start: t0 + 1800.0, end: t0 + 2400.0, stage: .wake),
            StageSegment(start: t0 + 2400.0, end: t0 + 3600.0, stage: .deep)
        ]
        let (tst, sol, waso, efficiency, lightSecs, deepSecs, _, _, nDist) =
            hypnogramMetrics(stages)
        XCTAssertEqual(tst, 3000.0, accuracy: 1e-9)
        XCTAssertEqual(sol, 0.0, accuracy: 1e-9)
        XCTAssertEqual(waso, 600.0, accuracy: 1e-9)
        XCTAssertEqual(efficiency, 3000.0 / 3600.0, accuracy: 1e-9)
        XCTAssertEqual(lightSecs, 1800.0, accuracy: 1e-9)
        XCTAssertEqual(deepSecs, 1200.0, accuracy: 1e-9)
        XCTAssertEqual(nDist, 1)
    }
}
