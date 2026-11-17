import XCTest
@testable import WhoopStore

final class ExternalWorkoutOverlapTests: XCTestCase {
    func testOverlappingQueryReturnsSessionsCrossingTheWindowStart() async throws {
        let store = try await WhoopStore.inMemory()
        func w(_ id: String, _ start: Double, _ end: Double) -> ExternalWorkout {
            ExternalWorkout(id: id, source: "healthkit", sportType: 37, startDate: start, endDate: end,
                            durationSec: end - start, energyKcal: nil, distanceM: nil, sourceName: "Watch", importedAt: 0)
        }
        // Local midnight at t = 10_000: "cross" starts before it and ends after it.
        try await store.upsertExternalWorkouts([w("before", 1_000, 2_000), w("cross", 9_000, 11_000),
                                                w("inside", 12_000, 13_000), w("after", 30_000, 31_000)])
        let overlapping = try await store.externalWorkouts(overlapping: 10_000, to: 20_000)
        XCTAssertEqual(overlapping.map(\.id), ["inside", "cross"])
        let startingInDay = try await store.externalWorkouts(from: 10_000, to: 20_000)
        XCTAssertEqual(startingInDay.map(\.id), ["inside"])
    }
}
