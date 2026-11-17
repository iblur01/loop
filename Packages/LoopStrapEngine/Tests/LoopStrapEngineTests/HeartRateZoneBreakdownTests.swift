import XCTest
@testable import LoopStrapEngine

/// Zones FC d'une séance : minutes par zone à FC connue, mêmes bornes que la charge cardio.
final class HeartRateZoneBreakdownTests: XCTestCase {
    /// Repos 60, max 180 → réserve 120. Dix minutes à 1 Hz par palier : sous la zone (33 % HRR),
    /// puis zones 1 à 5 (54, 64, 74, 84, 94 % HRR).
    func testKnownWorkoutProducesExpectedMinutesPerZone() throws {
        let plateaus: [Double] = [100, 125, 137, 149, 161, 173]
        var hr: [(ts: Double, bpm: Double)] = []
        for (i, bpm) in plateaus.enumerated() {
            for s in 0..<600 { hr.append((ts: Double(i * 600 + s), bpm: bpm)) }
        }
        let result = try strain(hrSeries: hr, restingHR: 60, hrmaxEstimate: 180, sex: .male)
        let zones = try XCTUnwrap(HeartRateZoneBreakdown(result: result, restingHR: 60, maxHR: 180,
                                                         maxHRSource: .replay))

        XCTAssertEqual(zones.belowZoneMinutes, 10, accuracy: 1e-6)
        for minutes in zones.zoneMinutes { XCTAssertEqual(minutes, 10, accuracy: 1e-6) }
        XCTAssertEqual(zones.totalMinutes, 60, accuracy: 1.0 / 60)
        XCTAssertEqual(zones.totalMinutes, result.observedMinutes, accuracy: 1e-9)
        XCTAssertEqual(zones.restingHR, 60)
        XCTAssertEqual(zones.maxHR, 180)
        XCTAssertEqual(zones.maxHRSource, .replay)
        XCTAssertEqual(zones.lowerBpm(zone: 1), 120)
        XCTAssertEqual(zones.lowerBpm(zone: 5), 168)
    }

    func testZoneOfBpmFollowsLoadBounds() {
        XCTAssertEqual(HeartRateZoneBreakdown.zone(forBpm: 119, restingHR: 60, maxHR: 180), 0)
        XCTAssertEqual(HeartRateZoneBreakdown.zone(forBpm: 120, restingHR: 60, maxHR: 180), 1)
        XCTAssertEqual(HeartRateZoneBreakdown.zone(forBpm: 168, restingHR: 60, maxHR: 180), 5)
        XCTAssertNil(HeartRateZoneBreakdown.zone(forBpm: 120, restingHR: 180, maxHR: 180))
    }

    func testSourceFollowsMaxHeartRatePrecedence() {
        let personal = MaxHeartRateReference(bpm: 190, provenance: "manual")
        XCTAssertEqual(MaxHeartRatePolicy.source(override: 185, personal: personal), .replay)
        XCTAssertEqual(MaxHeartRatePolicy.source(override: nil, personal: personal), .personal)
        XCTAssertEqual(MaxHeartRatePolicy.source(override: nil, personal: nil), .estimated)
    }

    func testUnusableBreakdownIsNil() {
        XCTAssertNil(HeartRateZoneBreakdown(zoneMinutes: [0, 0, 0, 0, 0], belowZoneMinutes: 0,
                                            restingHR: 60, maxHR: 180, maxHRSource: .estimated))
        XCTAssertNil(HeartRateZoneBreakdown(zoneMinutes: [1, 2], belowZoneMinutes: 0,
                                            restingHR: 60, maxHR: 180, maxHRSource: .estimated))
        XCTAssertNil(HeartRateZoneBreakdown(zoneMinutes: [1, 1, 1, 1, 1], belowZoneMinutes: 0,
                                            restingHR: 60, maxHR: 60, maxHRSource: .estimated))
    }
}
