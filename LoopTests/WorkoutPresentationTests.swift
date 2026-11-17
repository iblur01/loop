import XCTest
import LoopStrapEngine
@testable import Loop

// MARK: - WorkoutPresentationTests
//
// Présentation du détail de séance : aucune tuile pour une mesure absente ou nulle, allure
// seulement pour une course avec distance et durée, profils FC / tracé masqués s'ils sont vides.
final class WorkoutPresentationTests: XCTestCase {

    private func makeSession(kind: String? = "running", sportType: Int? = 37, durationS: Int? = 1800,
                             distanceM: Double? = 5000, kcal: Double? = 320, avgHr: Double? = 148,
                             peakHr: Int? = 171, strain: Double? = 11.2,
                             externalID: String? = "abc", sourceName: String? = "Apple Watch") -> WorkoutSession {
        WorkoutSession(deviceId: "dev", startTs: 1_700_000_000, endTs: 1_700_001_800, avgHr: avgHr,
                       peakHr: peakHr, strain: strain, kind: kind, durationS: durationS, caloriesKcal: kcal,
                       sportType: sportType, distanceM: distanceM, sourceName: sourceName, externalID: externalID)
    }

    func testFullRunShowsAllTilesWithPace() {
        let ids = WorkoutFormat.metrics(makeSession()).map(\.id)
        XCTAssertEqual(ids, ["distance", "pace", "duration", "energy", "avgHr", "peakHr", "strain"])
        let pace = WorkoutFormat.metrics(makeSession()).first { $0.id == "pace" }
        XCTAssertEqual(pace?.value, "6:00")
    }

    func testMissingMeasuresProduceNoTile() {
        let s = makeSession(distanceM: nil, kcal: 0, avgHr: nil, peakHr: 0, strain: nil)
        XCTAssertEqual(WorkoutFormat.metrics(s).map(\.id), ["duration"])
    }

    func testNoPaceOutsideRunning() {
        let s = makeSession(kind: "cycling", sportType: 13)
        XCTAssertFalse(WorkoutFormat.metrics(s).contains { $0.id == "pace" })
        XCTAssertTrue(WorkoutFormat.metrics(s).contains { $0.id == "distance" })
    }

    func testAccessibilityValueCarriesUnit() {
        let hr = WorkoutFormat.metrics(makeSession()).first { $0.id == "avgHr" }
        XCTAssertEqual(hr?.accessibilityValue, "148 battements par minute")
    }

    func testSourceFallsBackToBand() {
        XCTAssertEqual(WorkoutFormat.source(makeSession(externalID: nil, sourceName: nil)), "Détectée par le bracelet")
        XCTAssertEqual(WorkoutFormat.source(makeSession()), "Apple Watch")
    }

    func testEmptyProfilesAreHidden() {
        XCTAssertFalse(WorkoutHeartRateProfile(samples: []).hasCurve)
        XCTAssertNil(HeartRateZoneBreakdown(zoneMinutes: [0, 0, 0, 0, 0], belowZoneMinutes: 0,
                                            restingHR: 55, maxHR: 190, maxHRSource: .estimated))
        XCTAssertNil(makeSession().heartRateZones)
        XCTAssertFalse(WorkoutRoute(coordinates: [.init(latitude: 47.4, longitude: -0.5)]).isDrawable)
    }

    func testZoneBoundsComeFromEngine() throws {
        let p = try XCTUnwrap(HeartRateZoneBreakdown(zoneMinutes: [10, 5, 3, 1, 0], belowZoneMinutes: 11,
                                                     restingHR: 60, maxHR: 190, maxHRSource: .personal))
        XCTAssertEqual(p.lowerBpm(zone: 1), 125) // 60 + 0,5 × 130
        XCTAssertEqual(p.lowerBpm(zone: 5), 177) // 60 + 0,9 × 130
    }

    func testZonesSurviveCacheRoundTripAndRPE() throws {
        let zones = HeartRateZoneBreakdown(zoneMinutes: [10, 5, 3, 1, 0], belowZoneMinutes: 11,
                                           restingHR: 60, maxHR: 190, maxHRSource: .personal)
        let s = WorkoutSession(deviceId: "dev", startTs: 1, endTs: 1801, avgHr: 140, peakHr: 170, strain: 9,
                               kind: "running", durationS: 1800, caloriesKcal: nil, externalID: "x",
                               heartRateZones: zones)
        let decoded = try JSONDecoder().decode(WorkoutSession.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(decoded.heartRateZones, zones)
        XCTAssertEqual(s.withPerceivedEffort(6).heartRateZones, zones)
    }
}
