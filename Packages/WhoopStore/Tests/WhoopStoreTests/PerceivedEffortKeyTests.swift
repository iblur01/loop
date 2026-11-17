import XCTest
@testable import WhoopStore

final class PerceivedEffortKeyTests: XCTestCase {
    func testKeyFormats() {
        XCTAssertEqual(WorkoutPerceivedEffort.workoutKey(externalID: "ABC", deviceId: "healthkit", startTs: 5), "external:ABC")
        XCTAssertEqual(WorkoutPerceivedEffort.workoutKey(externalID: nil, deviceId: "band", startTs: 5), "band:band:5")
        XCTAssertEqual(WorkoutPerceivedEffort.workoutKey(externalID: "", deviceId: "band", startTs: 5), "band:band:5")
    }

    func testBatchLookupByKeyReturnsOnlyStoredEfforts() async throws {
        let ws = try await WhoopStore.inMemory()
        let store = PerceivedEffortStore(store: ws)
        let run = WorkoutPerceivedEffort.workoutKey(externalID: "RUN", deviceId: "healthkit", startTs: 0)
        let walk = WorkoutPerceivedEffort.workoutKey(externalID: "WALK", deviceId: "healthkit", startTs: 0)
        let band = WorkoutPerceivedEffort.workoutKey(externalID: nil, deviceId: "band", startTs: 1_000)
        try await store.save(workoutId: run, rpe: 8)
        try await store.save(workoutId: band, rpe: 4)
        let found = try await store.get(workoutIds: [run, walk, band, run])
        XCTAssertEqual(found[run]?.rpe, 8)
        XCTAssertNil(found[walk])
        XCTAssertEqual(found[band]?.rpe, 4)
        XCTAssertEqual(found.count, 2)
        // A shifted re-detection of the band session does not inherit the entry.
        let shifted = WorkoutPerceivedEffort.workoutKey(externalID: nil, deviceId: "band", startTs: 1_030)
        let none = try await store.get(workoutIds: [shifted])
        XCTAssertTrue(none.isEmpty)
    }
}
