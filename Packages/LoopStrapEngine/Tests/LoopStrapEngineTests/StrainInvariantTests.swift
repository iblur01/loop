import XCTest
@testable import LoopStrapEngine

final class StrainInvariantTests: XCTestCase {
    func testSessionRPEIsSeparateAndRequiresValidSelfReport() {
        XCTAssertEqual(sessionRPELoad(perceivedExertion: 7, durationMinutes: 60), 420)
        XCTAssertEqual(sessionRPELoad(perceivedExertion: 0, durationMinutes: 60), 0)
        XCTAssertNil(sessionRPELoad(perceivedExertion: nil, durationMinutes: 60))
        XCTAssertNil(sessionRPELoad(perceivedExertion: 11, durationMinutes: 60))
        XCTAssertNil(sessionRPELoad(perceivedExertion: 5, durationMinutes: 0))
    }
    private func series(_ bpm: Double, cadence: Double = 1) -> [(ts: Double, bpm: Double)] {
        (0..<600).map { (Double($0) * cadence, bpm) }
    }
    private func load(_ samples: [(ts: Double, bpm: Double)], difficulty: Double = 1) throws -> StrainResult {
        try strain(hrSeries: samples, restingHR: 60, hrmaxEstimate: 180, sex: .male, difficulty: difficulty)
    }

    func testDeclaredZoneBoundariesAndPartition() throws {
        for pct in [0.0, 20, 49.9, 50, 59.9, 60, 70, 80, 90, 100] {
            let result = try load(series(60 + pct * 1.2))
            XCTAssertEqual(result.observedMinutes, 10, accuracy: 1e-8)
            XCTAssertEqual(result.belowZoneMinutes + result.hrZoneMinutes.reduce(0, +), 10, accuracy: 1e-8)
            if pct < 50 { XCTAssertEqual(result.hrZoneMinutes.reduce(0, +), 0) }
        }
    }

    func testOrderingDuplicateAndInvalidSampleInvariance() throws {
        let regular = series(150)
        let expected = try load(regular)
        let noisy = Array((regular + regular + [(Double.nan, 150), (900, Double.nan), (901, -1)]).reversed())
        let actual = try load(noisy)
        XCTAssertEqual(actual.trimp, expected.trimp)
        XCTAssertEqual(actual.observedMinutes, expected.observedMinutes)
        XCTAssertThrowsError(try load(Array(repeating: (0, 150), count: 600)))
    }

    func testMonotonicIntensityAndBoundedScale() throws {
        var previous = 0.0
        for bpm in stride(from: 60.0, through: 240, by: 5) {
            let result = try load(series(bpm))
            XCTAssertGreaterThanOrEqual(result.trimp, previous)
            XCTAssertTrue((0...21).contains(result.strain))
            previous = result.trimp
        }
        XCTAssertEqual(try load(series(180), difficulty: 1e100).strain, 21)
        XCTAssertThrowsError(try load(series(150), difficulty: .nan))
        XCTAssertThrowsError(try load(series(150), difficulty: -1))
    }

    func testSparseReadingsDoNotRepresentHoursOfContinuousLoad() throws {
        let sparse = try load(series(150, cadence: 3600))
        XCTAssertEqual(sparse.observedMinutes, 100, accuracy: 1e-8)
        XCTAssertNil(estimateHRmax(hrHistory: Array(repeating: .nan, count: 600)))
        XCTAssertNil(estimateHRmax(hrHistory: [], age: .nan))
    }

    func testPlausibilityBoundsApplyToEverySourceAndManualReserve() throws {
        let good = series(150)
        let noisy = good + [(900, 1), (901, 10_000)]
        XCTAssertEqual(try load(noisy).trimp, try load(good).trimp)
        XCTAssertNil(estimateHRmax(hrHistory: Array(repeating: 10_000, count: 600)))
        XCTAssertEqual(estimateHRmax(hrHistory: Array(repeating: 180, count: 600) + [1, 10_000]), 180)
        for maxHR in [1.0, 251, 10_000] {
            XCTAssertThrowsError(try strain(hrSeries: good, restingHR: 60, hrmaxEstimate: maxHR, sex: .male))
        }
        for restHR in [1.0, 151] {
            XCTAssertThrowsError(try strain(hrSeries: good, restingHR: restHR, hrmaxEstimate: 200, sex: .male))
        }
        let merged = mergeSupplementalHR(band: [(100, 1), (101, 10_000)], supplemental: [(100, 130)])
        XCTAssertEqual(merged.count, 10)
        XCTAssertTrue(merged.allSatisfy { $0.bpm == 130 })
        let prioritized = mergePrioritizedHR(band: [(100, 130)], supplemental: [],
                                             preferred: [(100, 10_000)], preferredRanges: [(100, 110)])
        XCTAssertEqual(prioritized.count, 1)
        XCTAssertEqual(prioritized.first?.bpm, 130)
        XCTAssertEqual(CardioInputPolicy.heartRateBPM.lowerBound, 25)
        XCTAssertEqual(CardioInputPolicy.heartRateBPM.upperBound, 250)
    }

    func testInvalidBandDoesNotBlockExternalAndPriorityIsWindowBounded() {
        let fixed = mergeSupplementalHR(band: [(100, .nan)], supplemental: [(100, 130)])
        XCTAssertEqual(fixed.count, 10)
        let band = (0..<40).map { (ts: Double($0), bpm: 100.0) }
        let output = mergePrioritizedHR(band: band + band, supplemental: [],
                                        preferred: [(10, 160)], preferredRanges: [(12, 16)])
        XCTAssertEqual(output.count, 40)
        XCTAssertEqual(Set(output.map(\.ts)).count, 40)
        for sample in output {
            XCTAssertEqual(sample.bpm, (12..<16).contains(sample.ts) ? 160 : 100)
        }
        let missing = mergePrioritizedHR(band: band, supplemental: [], preferred: [], preferredRanges: [(0, 40)])
        XCTAssertEqual(missing.map(\.bpm), band.map(\.bpm))
    }
}
