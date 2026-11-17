import XCTest
import WhoopProtocol
import WhoopStore
@testable import Loop

final class LocalMetricsEngineSyncTests: XCTestCase {
    func testDbStatsCountsCurrentDeviceSeparatelyFromTotalRows() async throws {
        let store = try await makeTempStore()
        try await store.upsertDevice(id: "theo-whoop", mac: nil, name: nil)
        try await store.upsertDevice(id: "my-whoop", mac: nil, name: nil)
        try await store.insert(
            Streams(hr: [HRSample(ts: 100, bpm: 60)],
                    gravity: [GravitySample(ts: 100, x: 0.1, y: 0.2, z: 0.3)]),
            deviceId: "theo-whoop")
        try await store.insert(
            Streams(hr: [HRSample(ts: 200, bpm: 61)]),
            deviceId: "my-whoop")

        let engine = LocalMetricsEngine(store: store, deviceId: "theo-whoop")
        let stats = await engine.dbStats()

        XCTAssertEqual(engine.deviceId, "theo-whoop")
        XCTAssertEqual(stats.decodedRows, 2)
        XCTAssertEqual(stats.decodedRowsTotal, 3)
        XCTAssertEqual(stats.latestTs, 100)
    }

    private func makeTempStore() async throws -> WhoopStore {
        let path = NSTemporaryDirectory() + "loop-engine-tests-\(UUID().uuidString).sqlite"
        return try await WhoopStore(path: path)
    }
}
