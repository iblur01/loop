import XCTest
import GRDB
@testable import WhoopStore

final class ExternalWorkoutTests: XCTestCase {
    private func w(_ id: String, start: Double = 1000, kcal: Double? = 200) -> ExternalWorkout {
        ExternalWorkout(id: id, source: "healthkit", sportType: 37, startDate: start, endDate: start + 600,
                        durationSec: 600, energyKcal: kcal, distanceM: nil, sourceName: "Watch", importedAt: 5)
    }

    func testV9CreatesTables() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("external_workout"))
        XCTAssertTrue(tables.contains("external_sync_anchor"))
        XCTAssertGreaterThanOrEqual(WhoopStoreInfo.schemaVersion, 10)
    }

    func testUpsertIsIdempotentAndUpdates() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertExternalWorkouts([w("a"), w("b", start: 2000)])
        try await store.upsertExternalWorkouts([w("a", kcal: 350)])
        let count = try await store.externalWorkoutCount()
        XCTAssertEqual(count, 2)
        let rows = try await store.externalWorkouts(from: 0, to: 5000)
        XCTAssertEqual(rows.map(\.id), ["b", "a"])
        XCTAssertEqual(rows.last?.energyKcal, 350)
        XCTAssertNil(rows.last?.distanceM)
        let late = try await store.externalWorkouts(from: 1500, to: 5000)
        XCTAssertEqual(late.count, 1)
    }

    func testDelete() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertExternalWorkouts([w("a"), w("b")])
        try await store.deleteExternalWorkouts(ids: ["a", "zzz"])
        let left = try await store.externalWorkouts(from: 0, to: 5000)
        XCTAssertEqual(left.map(\.id), ["b"])
    }

    func testAnchorUpsertGet() async throws {
        let store = try await WhoopStore.inMemory()
        let none = try await store.externalSyncAnchor(source: "healthkit")
        XCTAssertNil(none)
        try await store.setExternalSyncAnchor(source: "healthkit", data: Data([1, 2]), updatedAt: 1)
        try await store.setExternalSyncAnchor(source: "healthkit", data: Data([3]), updatedAt: 2)
        let got = try await store.externalSyncAnchor(source: "healthkit")
        XCTAssertEqual(got, Data([3]))
    }

    func testBatchAppliesUpsertsDeletesAndAnchor() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertExternalWorkouts([w("old")])
        try await store.applyExternalWorkoutBatch(source: "healthkit", upserts: [w("new")], deletedIds: ["old"],
                                                  anchor: Data([9]), updatedAt: 3)
        let after = try await store.externalWorkouts(from: 0, to: 5000)
        XCTAssertEqual(after.map(\.id), ["new"])
        let anchor = try await store.externalSyncAnchor(source: "healthkit")
        XCTAssertEqual(anchor, Data([9]))
    }

    func testProducerBundlePersistsThroughBothUpsertPaths() async throws {
        let store = try await WhoopStore.inMemory()
        func workout(_ id: String, _ bundle: String?) -> ExternalWorkout {
            ExternalWorkout(id: id, source: "healthkit", sportType: 37, startDate: 1000, endDate: 1600,
                            durationSec: 600, energyKcal: nil, distanceM: nil, sourceName: "Same name",
                            importedAt: 5, sourceBundle: bundle)
        }
        try await store.upsertExternalWorkouts([workout("a", "example.first"), workout("b", "example.second")])
        try await store.applyExternalWorkoutBatch(source: "healthkit", upserts: [workout("a", nil)],
                                                  deletedIds: [], anchor: Data([4]), updatedAt: 10)
        let rows = try await store.externalWorkouts(from: 0, to: 5000)
        XCTAssertEqual(rows.first(where: { $0.id == "a" })?.sourceBundle, "example.first")
        XCTAssertEqual(rows.first(where: { $0.id == "b" })?.sourceBundle, "example.second")
        let anchor = try await store.externalSyncAnchor(source: "healthkit")
        XCTAssertEqual(anchor, Data([4]))
        try await store.upsertExternalWorkouts([workout("a", "example.changed")])
        let updated = try await store.externalWorkouts(from: 0, to: 5000)
        XCTAssertEqual(updated.first(where: { $0.id == "a" })?.sourceBundle, "example.changed")
    }

    func testV14MigrationPreservesLegacyWorkoutAndAnchor() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("whoopstore-v13-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("whoop.sqlite").path
        try Self.seedV13(path: path)
        try Data("{\"schemaVersion\": 13}".utf8).write(to: folder.appendingPathComponent("meta.json"))
        XCTAssertEqual(try BackupValidation.validate(package: folder).schemaVersion, 13)
        let store = try await WhoopStore(path: path)
        let workouts = try await store.externalWorkouts(from: 0, to: 5000)
        XCTAssertEqual(workouts.map(\.id), ["legacy"])
        XCTAssertEqual(workouts.first?.sourceName, "Watch")
        XCTAssertNil(workouts.first?.sourceBundle)
        // v15 deliberately ignores pre-v15 anchors once (device identity catch-up); the row is kept.
        let anchor = try await store.externalSyncAnchor(source: "healthkit")
        XCTAssertNil(anchor)
        XCTAssertEqual(try Self.rawAnchor(path: path, source: "healthkit"), Data([7]))
    }

    private static func seedV13(path: String) throws {
        let queue = try DatabaseQueue(path: path)
        try WhoopStore.makeMigrator().migrate(queue, upTo: "v13")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO external_workout
                (id, source, sportType, startDate, endDate, durationSec, sourceName, importedAt)
                VALUES ('legacy', 'healthkit', 37, 1000, 1600, 600, 'Watch', 5)
                """)
            try db.execute(sql: "INSERT INTO external_sync_anchor (source, anchorData, updatedAt) VALUES (?, ?, ?)",
                           arguments: ["healthkit", Data([7]), 2])
        }
    }


    // MARK: - v15 stable device identity

    func testV15MigrationKeepsV14RowsWithNilDeviceIdentity() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("whoopstore-v14-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("whoop.sqlite").path
        try Self.seedV14(path: path)

        let store = try await WhoopStore(path: path)
        for table in ["health_sample", "external_workout"] {
            let cols = try await store.columnNamesForTest(table: table)
            XCTAssertTrue(cols.contains("productType"), "\(table) missing productType")
            XCTAssertTrue(cols.contains("deviceModel"), "\(table) missing deviceModel")
        }
        let workouts = try await store.externalWorkouts(from: 0, to: 5000)
        XCTAssertEqual(workouts.map(\.id), ["legacy"])
        XCTAssertEqual(workouts.first?.sourceName, "Watch")
        XCTAssertEqual(workouts.first?.sourceBundle, "com.apple.health")
        XCTAssertNil(workouts.first?.productType)
        XCTAssertNil(workouts.first?.deviceModel)
        let samples = try await store.healthSamples(type: "heartRate", from: 0, to: 5000)
        XCTAssertEqual(samples.map(\.uuid), ["hs"])
        XCTAssertEqual(samples.first?.value, 58)
        XCTAssertEqual(samples.first?.sourceName, "Apple Watch")
        XCTAssertNil(samples.first?.productType)
        XCTAssertNil(samples.first?.deviceModel)

        // One-shot catch-up: pre-v15 anchors are ignored (full re-import) but their rows are kept.
        let workoutAnchor = try await store.externalSyncAnchor(source: "healthkit")
        XCTAssertNil(workoutAnchor)
        let sampleAnchor = try await store.healthSyncAnchor(type: "heartRate")
        XCTAssertNil(sampleAnchor)
        let lastSync = try await store.healthSyncUpdatedAt()
        XCTAssertEqual(lastSync["heartRate"], 2)
        // An anchor written after v15 is honored, and reopening the base does not reset it again.
        try await store.setExternalSyncAnchor(source: "healthkit", data: Data([8]), updatedAt: 9)
        try await store.applyHealthSampleBatch(type: "heartRate", upserts: [], deletedUUIDs: [],
                                               anchor: Data([9]), updatedAt: 9)
        let reopened = try await WhoopStore(path: path)
        let workoutAfter = try await reopened.externalSyncAnchor(source: "healthkit")
        XCTAssertEqual(workoutAfter, Data([8]))
        let sampleAfter = try await reopened.healthSyncAnchor(type: "heartRate")
        XCTAssertEqual(sampleAfter, Data([9]))
    }

    func testDeviceIdentityRoundTripsAndSurvivesNilReupsert() async throws {
        let store = try await WhoopStore.inMemory()
        func workout(_ product: String?, _ model: String?) -> ExternalWorkout {
            ExternalWorkout(id: "w", source: "healthkit", sportType: 37, startDate: 1000, endDate: 1600,
                            durationSec: 600, energyKcal: nil, distanceM: nil, sourceName: "iPhone de Test",
                            importedAt: 5, sourceBundle: "com.apple.health",
                            productType: product, deviceModel: model)
        }
        try await store.upsertExternalWorkouts([workout("Watch6,1", "Watch")])
        var row = try await store.externalWorkouts(from: 0, to: 5000).first
        XCTAssertEqual(row?.productType, "Watch6,1")
        XCTAssertEqual(row?.deviceModel, "Watch")
        let byId = try await store.externalWorkout(id: "w")
        XCTAssertEqual(byId?.productType, "Watch6,1")
        XCTAssertEqual(byId?.deviceModel, "Watch")
        try await store.applyExternalWorkoutBatch(source: "healthkit", upserts: [workout(nil, nil)],
                                                  deletedIds: [], anchor: Data([1]), updatedAt: 6)
        row = try await store.externalWorkouts(from: 0, to: 5000).first
        XCTAssertEqual(row?.productType, "Watch6,1")
        XCTAssertEqual(row?.deviceModel, "Watch")
    }

    private static func seedV14(path: String) throws {
        let queue = try DatabaseQueue(path: path)
        try WhoopStore.makeMigrator().migrate(queue, upTo: "v14")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO external_workout
                (id, source, sportType, startDate, endDate, durationSec, sourceName, importedAt, sourceBundle)
                VALUES ('legacy', 'healthkit', 37, 1000, 1600, 600, 'Watch', 5, 'com.apple.health')
                """)
            try db.execute(sql: """
                INSERT INTO health_sample
                (uuid, type, startDate, endDate, value, unit, sourceName, sourceBundle, metadataOrigin, importedAt)
                VALUES ('hs', 'heartRate', 1000, 1060, 58, 'count/min', 'Apple Watch', 'com.apple.health', NULL, 5)
                """)
            for source in ["healthkit", "healthkit:heartRate"] {
                try db.execute(sql: "INSERT INTO external_sync_anchor (source, anchorData, updatedAt) VALUES (?, ?, ?)",
                               arguments: [source, Data([7]), 2])
            }
        }
        try queue.close()
    }

    private static func rawAnchor(path: String, source: String) throws -> Data? {
        try DatabaseQueue(path: path).read { db in
            try Data.fetchOne(db, sql: "SELECT anchorData FROM external_sync_anchor WHERE source = ?", arguments: [source])
        }
    }
}
