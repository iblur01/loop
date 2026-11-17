import XCTest
import WhoopStore
import WhoopProtocol
@testable import Loop

final class FullIncrementalParityTests: XCTestCase {
    func testOlderAndRecentHealthChangesMatchFreshRecalculation() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "band", mac: nil, name: nil)
        let now = 1_794_654_000
        let points = (0..<10).flatMap { day in
            (0..<800).map { n in HRSample(ts: now - day * 86400 - n * 60, bpm: 65 + (n % 40)) }
        }
        try await store.insert(Streams(hr: points), deviceId: "band")
        func sample(_ value: Double, at ts: Int) -> HealthSample {
            HealthSample(uuid: "sample", type: "heartRate", startDate: Double(ts),
                         endDate: Double(ts), value: value, unit: "count/min",
                         sourceName: "Test Watch", sourceBundle: "test.watch", metadataOrigin: nil,
                         importedAt: 0)
        }
        let oldTs = now - 8 * 86400 - 10
        try await store.upsertHealthSamples([sample(85, at: oldTs)])
        let engine = LocalMetricsEngine(store: store, deviceId: "band")
        let date = Date(timeIntervalSince1970: Double(now))
        var (previous, revisions) = try await engine.computeCore(days: 10, previous: nil,
            previousDayCounts: nil, forceFull: true, now: date)

        for changed in [sample(95, at: oldTs), sample(100, at: now - 10)] {
            // Same UUID updates values and eventually moves the sample to a newer day.
            try await store.upsertHealthSamples([changed])
            let (incremental, next) = try await engine.computeCore(days: 10, previous: previous,
                previousDayCounts: revisions, forceFull: false, now: date)
            let fresh = try await LocalMetricsEngine(store: store, deviceId: "band").compute(days: 10, now: date)
            XCTAssertEqual(incremental.daily, fresh.daily)
            XCTAssertEqual(incremental.sleepSessions, fresh.sleepSessions)
            XCTAssertEqual(incremental.workoutSessions, fresh.workoutSessions)
            previous = incremental; revisions = next
        }
    }
}
