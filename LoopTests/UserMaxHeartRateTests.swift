import XCTest
@testable import Loop

@MainActor
final class UserMaxHeartRateTests: XCTestCase {
    func testBounds() {
        XCTAssertNil(UserMaxHeartRate(bpm: 119, provenance: .manual))
        XCTAssertNil(UserMaxHeartRate(bpm: 231, provenance: .manual))
        XCTAssertNotNil(UserMaxHeartRate(bpm: 120, provenance: .manual))
        XCTAssertNotNil(UserMaxHeartRate(bpm: 230, provenance: .measured))
        XCTAssertNil(UserMaxHeartRate(bpm: 180, provenance: .ageEstimate, age: 5))
    }

    func testAgeEstimateTanaka() {
        XCTAssertEqual(UserMaxHeartRate.ageEstimate(age: 30), 187)
        XCTAssertNil(UserMaxHeartRate.ageEstimate(age: 3))
        let v = UserMaxHeartRate.fromAge(40)
        XCTAssertEqual(v?.bpm, 180)
        XCTAssertEqual(v?.provenance, .ageEstimate)
        XCTAssertEqual(v?.age, 40)
    }

    func testAgeDroppedForNonAgeProvenance() {
        XCTAssertNil(UserMaxHeartRate(bpm: 190, provenance: .manual, age: 30)?.age)
    }

    func testCodableRoundTripAndRejectsOutOfRange() throws {
        let v = try XCTUnwrap(UserMaxHeartRate(bpm: 191, provenance: .measured, enteredAt: Date(timeIntervalSince1970: 1000)))
        let data = try JSONEncoder().encode(v)
        XCTAssertEqual(try JSONDecoder().decode(UserMaxHeartRate.self, from: data), v)
        let bad = #"{"bpm":300,"provenance":"manual","enteredAt":0}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(UserMaxHeartRate.self, from: bad))
    }

    func testPreferencesResolvedSetAndClear() {
        let prefs = UserPreferences.shared
        let before = prefs.userMaxHeartRate
        defer { if let before { prefs.setMaxHeartRate(before.bpm, provenance: before.provenance, age: before.age, now: before.enteredAt) } else { prefs.clearMaxHeartRate() } }
        prefs.clearMaxHeartRate()
        XCTAssertNil(prefs.resolvedMaxHeartRate())
        XCTAssertFalse(prefs.setMaxHeartRate(500, provenance: .manual))
        XCTAssertNil(prefs.resolvedMaxHeartRate())
        XCTAssertTrue(prefs.setMaxHeartRate(188, provenance: .measured))
        XCTAssertEqual(prefs.resolvedMaxHeartRate()?.bpm, 188)
        XCTAssertEqual(prefs.resolvedMaxHeartRate()?.provenance, .measured)
        prefs.clearMaxHeartRate()
        XCTAssertNil(prefs.resolvedMaxHeartRate())
    }
}
