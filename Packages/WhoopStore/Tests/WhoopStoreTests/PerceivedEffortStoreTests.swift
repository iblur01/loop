import XCTest
import GRDB
@testable import WhoopStore

final class PerceivedEffortStoreTests: XCTestCase {
    func testV12CreatesTableAndSchemaVersion() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("workout_perceived_effort"))
        XCTAssertGreaterThanOrEqual(WhoopStoreInfo.schemaVersion, 12)
    }

    func testRoundTripAndReplace() async throws {
        let ws = try await WhoopStore.inMemory()
        let store = PerceivedEffortStore(store: ws)
        try await store.save(workoutId: "external:A", rpe: 7, note: "  jambes lourdes ", now: Date(timeIntervalSince1970: 100))
        var got = try await store.get(workoutId: "external:A")
        XCTAssertEqual(got?.rpe, 7)
        XCTAssertEqual(got?.note, "jambes lourdes")
        XCTAssertEqual(got?.recordedAt, 100)
        try await store.save(workoutId: "external:A", rpe: 4, now: Date(timeIntervalSince1970: 200))
        got = try await store.get(workoutId: "external:A")
        XCTAssertEqual(got?.rpe, 4)
        XCTAssertNil(got?.note)
        let all = try await store.list(recordedFrom: 0, to: 1000)
        XCTAssertEqual(all.count, 1)
    }

    func testBoundsRejected() async throws {
        let ws = try await WhoopStore.inMemory()
        let store = PerceivedEffortStore(store: ws)
        for bad in [0, 11, -3] {
            do { try await store.save(workoutId: "x", rpe: bad); XCTFail("rpe \(bad) accepté") }
            catch { XCTAssertEqual(error as? PerceivedEffortStore.StoreError, .invalidRPE) }
        }
        XCTAssertNil(WorkoutPerceivedEffort(workoutId: "", rpe: 5, recordedAt: 0))
        XCTAssertNotNil(WorkoutPerceivedEffort(workoutId: "x", rpe: 1, recordedAt: 0))
        XCTAssertNotNil(WorkoutPerceivedEffort(workoutId: "x", rpe: 10, recordedAt: 0))
    }

    func testDatabaseCheckConstraintRejectsOutOfRange() async throws {
        let ws = try await WhoopStore.inMemory()
        do {
            try await ws.syncWriteForTest("INSERT INTO workout_perceived_effort VALUES ('x', 11, 0, NULL)")
            XCTFail("CHECK non appliqué")
        } catch {}
    }

    func testNoteTruncatedAndBatchRead() async throws {
        let ws = try await WhoopStore.inMemory()
        let store = PerceivedEffortStore(store: ws)
        let long = String(repeating: "a", count: 300)
        let e = try await store.save(workoutId: "a", rpe: 5, note: long)
        XCTAssertEqual(e.note?.count, WorkoutPerceivedEffort.maxNoteLength)
        try await store.save(workoutId: "b", rpe: 9)
        let map = try await store.get(workoutIds: ["a", "b", "zzz"])
        XCTAssertEqual(Set(map.keys), ["a", "b"])
        let empty = try await store.get(workoutIds: [])
        XCTAssertTrue(empty.isEmpty)
    }

    func testDelete() async throws {
        let ws = try await WhoopStore.inMemory()
        let store = PerceivedEffortStore(store: ws)
        try await store.save(workoutId: "a", rpe: 5)
        try await store.delete(workoutId: "a")
        try await store.delete(workoutId: "absent")
        let got = try await store.get(workoutId: "a")
        XCTAssertNil(got)
    }
}

extension WhoopStore {
    func syncWriteForTest(_ sql: String) throws {
        try syncWrite { db in try db.execute(sql: sql) }
    }
}
