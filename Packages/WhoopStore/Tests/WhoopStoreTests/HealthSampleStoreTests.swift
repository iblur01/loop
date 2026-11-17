import XCTest
@testable import WhoopStore

final class HealthSampleStoreTests: XCTestCase {
    private func s(_ uuid: String, type: String = "stepCount", start: Double = 1000,
                   value: Double? = 120, importedAt: Double = 5) -> HealthSample {
        HealthSample(uuid: uuid, type: type, startDate: start, endDate: start + 60, value: value,
                     unit: "count", sourceName: "iPhone", sourceBundle: "com.apple.health",
                     metadataOrigin: nil, importedAt: importedAt)
    }

    func testV10CreatesTableAndIndex() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("health_sample"))
        XCTAssertTrue(tables.contains("external_sync_anchor"))
        XCTAssertGreaterThanOrEqual(WhoopStoreInfo.schemaVersion, 10)
        let pk = try await store.primaryKeyColumns("health_sample")
        XCTAssertEqual(pk, ["uuid"])
        let cols = try await store.columnNamesForTest(table: "health_sample")
        for c in ["uuid", "type", "startDate", "endDate", "value", "unit", "sourceName",
                  "sourceBundle", "metadataOrigin", "importedAt"] {
            XCTAssertTrue(cols.contains(c), "missing column \(c)")
        }
    }

    func testUpsertIsIdempotentAndUpdates() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertHealthSamples([s("a"), s("b", start: 2000)])
        try await store.upsertHealthSamples([s("a", value: 999), s("a", value: 999)])
        let count = try await store.healthSampleCount(type: "stepCount")
        XCTAssertEqual(count, 2)
        let rows = try await store.healthSamples(type: "stepCount", from: 0, to: 5000)
        XCTAssertEqual(rows.map(\.uuid), ["a", "b"])
        XCTAssertEqual(rows.first?.value, 999)
        let late = try await store.healthSamples(type: "stepCount", from: 1500, to: 5000)
        XCTAssertEqual(late.map(\.uuid), ["b"])
    }

    func testReadIsFilteredByType() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertHealthSamples([s("a"), s("hr", type: "heartRate"), s("sleep", type: "sleepAnalysis", value: nil)])
        let hr = try await store.healthSamples(type: "heartRate", from: 0, to: 5000)
        XCTAssertEqual(hr.map(\.uuid), ["hr"])
        let sleep = try await store.healthSamples(type: "sleepAnalysis", from: 0, to: 5000)
        XCTAssertNil(sleep.first?.value)
        let summaries = try await store.healthSampleSummaries()
        XCTAssertEqual(Set(summaries.map(\.type)), ["stepCount", "heartRate", "sleepAnalysis"])
        XCTAssertEqual(summaries.first { $0.type == "stepCount" }?.count, 1)
        XCTAssertEqual(summaries.first { $0.type == "stepCount" }?.lastImportedAt, 5)
    }

    func testProducerDiscoveryAcrossHistoryByBundleAndMetric() async throws {
        let store = try await WhoopStore.inMemory()
        func sample(_ id: String, type: String = "stepCount", start: Double, bundle: String?,
                    name: String?, origin: String? = nil) -> HealthSample {
            HealthSample(uuid: id, type: type, startDate: start, endDate: start + 60,
                         value: 10, unit: "count", sourceName: name, sourceBundle: bundle,
                         metadataOrigin: origin, importedAt: start)
        }
        try await store.upsertHealthSamples([
            sample("old", start: 1, bundle: " Com.Example.App ", name: "Old name"),
            sample("new", start: 2, bundle: "com.example.app", name: "New name"),
            sample("other", start: 3, bundle: "com.example.other", name: "Other"),
            sample("unnamed", start: 4, bundle: "com.example.unnamed", name: nil),
            sample("unknown", start: 5, bundle: nil, name: "Unstable name"),
            sample("invalid", start: 6, bundle: "invalid bundle", name: "Invalid"),
            sample("loop", start: 7, bundle: "com.loop", name: "Loop", origin: "loop"),
            sample("differentMetric", type: "heartRate", start: 8, bundle: "com.heart", name: "Heart")
        ])
        let producers = try await store.healthSampleProducers(type: "stepCount")
        XCTAssertEqual(producers, [
            HealthSampleProducer(bundle: "com.example.app", name: "New name"),
            HealthSampleProducer(bundle: "com.example.other", name: "Other"),
            HealthSampleProducer(bundle: "com.example.unnamed", name: nil)
        ])
        let heartProducers = try await store.healthSampleProducers(type: "heartRate")
        XCTAssertEqual(heartProducers, [HealthSampleProducer(bundle: "com.heart", name: "Heart")])
    }

    func testOverlappingReadIncludesCrossBoundaryAndFractionalFinalSecond() async throws {
        let store = try await WhoopStore.inMemory()
        func sample(_ id: String, _ start: Double, _ end: Double, type: String = "stepCount") -> HealthSample {
            HealthSample(uuid: id, type: type, startDate: start, endDate: end, value: 10,
                         unit: "count", sourceName: "Phone", sourceBundle: "app.phone",
                         metadataOrigin: nil, importedAt: 0)
        }
        try await store.upsertHealthSamples([
            sample("touchesStart", 90, 100), sample("crossesStart", 95, 105),
            sample("pointStart", 100, 100), sample("middle", 125, 150),
            sample("finalFraction", 199.5, 199.5), sample("pointEnd", 200, 200),
            sample("startsAtEnd", 200, 210), sample("otherType", 110, 120, type: "heartRate")
        ])
        let result = try await store.healthSamplesOverlapping(type: "stepCount", from: 100, to: 200)
        XCTAssertEqual(result.map(\.uuid), ["crossesStart", "pointStart", "middle", "finalFraction"])
        let oldResult = try await store.healthSamples(type: "stepCount", from: 100, to: 199)
        XCTAssertFalse(oldResult.contains { $0.uuid == "crossesStart" || $0.uuid == "finalFraction" })
        let empty = try await store.healthSamplesOverlapping(type: "stepCount", from: 200, to: 100)
        XCTAssertTrue(empty.isEmpty)
    }

    func testRangedCountAcrossTypes() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertHealthSamples([s("a"), s("hr", type: "heartRate", start: 1500),
                                             s("rhr", type: "restingHeartRate", start: 3000),
                                             s("late", type: "heartRate", start: 9000)])
        let n = try await store.healthSampleCount(types: ["heartRate", "restingHeartRate"], from: 1000, to: 5000)
        XCTAssertEqual(n, 2)
        let none = try await store.healthSampleCount(types: [], from: 0, to: 10_000)
        XCTAssertEqual(none, 0)
    }

    func testDeleteByUUID() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertHealthSamples([s("a"), s("b")])
        try await store.deleteHealthSamples(uuids: ["a", "unknown"])
        let left = try await store.healthSamples(type: "stepCount", from: 0, to: 5000)
        XCTAssertEqual(left.map(\.uuid), ["b"])
    }

    func testAnchorIsPerTypeAndDoesNotTouchWorkoutAnchor() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.setExternalSyncAnchor(source: "healthkit", data: Data([7]), updatedAt: 1)
        let none = try await store.healthSyncAnchor(type: "stepCount")
        XCTAssertNil(none)
        try await store.setHealthSyncAnchor(type: "stepCount", data: Data([1]), updatedAt: 1)
        try await store.setHealthSyncAnchor(type: "heartRate", data: Data([2]), updatedAt: 1)
        try await store.setHealthSyncAnchor(type: "stepCount", data: Data([3]), updatedAt: 2)
        let steps = try await store.healthSyncAnchor(type: "stepCount")
        let hr = try await store.healthSyncAnchor(type: "heartRate")
        let workouts = try await store.externalSyncAnchor(source: "healthkit")
        XCTAssertEqual(steps, Data([3]))
        XCTAssertEqual(hr, Data([2]))
        XCTAssertEqual(workouts, Data([7]))
        let raw = try await store.externalSyncAnchor(source: "healthkit:stepCount")
        XCTAssertEqual(raw, Data([3]))
        let updated = try await store.healthSyncUpdatedAt()
        XCTAssertEqual(updated, ["stepCount": 2, "heartRate": 1])
    }

    func testBatchAppliesUpsertsDeletesAndAnchor() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertHealthSamples([s("old")])
        try await store.applyHealthSampleBatch(type: "stepCount", upserts: [s("new")], deletedUUIDs: ["old"],
                                               anchor: Data([9]), updatedAt: 3)
        let after = try await store.healthSamples(type: "stepCount", from: 0, to: 5000)
        XCTAssertEqual(after.map(\.uuid), ["new"])
        let anchor = try await store.healthSyncAnchor(type: "stepCount")
        XCTAssertEqual(anchor, Data([9]))
    }

    func testEmptyBatchStillAdvancesAnchor() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.applyHealthSampleBatch(type: "vo2Max", upserts: [], deletedUUIDs: [],
                                               anchor: Data([4]), updatedAt: 1)
        let anchor = try await store.healthSyncAnchor(type: "vo2Max")
        XCTAssertEqual(anchor, Data([4]))
    }

    func testDeviceIdentityRoundTrips() async throws {
        let store = try await WhoopStore.inMemory()
        let sample = HealthSample(uuid: "dev", type: "heartRate", startDate: 1000, endDate: 1060, value: 61,
                                  unit: "count/min", sourceName: "iPhone de Test", sourceBundle: "com.apple.health",
                                  metadataOrigin: nil, importedAt: 5, productType: "Watch6,1", deviceModel: "Watch")
        try await store.upsertHealthSamples([sample, s("plain", type: "heartRate", start: 2000)])
        let rows = try await store.healthSamples(type: "heartRate", from: 0, to: 5000)
        XCTAssertEqual(rows.first(where: { $0.uuid == "dev" }), sample)
        XCTAssertNil(rows.first(where: { $0.uuid == "plain" })?.productType)
        XCTAssertNil(rows.first(where: { $0.uuid == "plain" })?.deviceModel)
    }

    func testUpsertWithoutDeviceIdentityKeepsStoredValues() async throws {
        let store = try await WhoopStore.inMemory()
        func sample(_ product: String?, _ model: String?, value: Double) -> HealthSample {
            HealthSample(uuid: "keep", type: "heartRate", startDate: 1000, endDate: 1060, value: value,
                         unit: "count/min", sourceName: "Montre", sourceBundle: "com.apple.health.X",
                         metadataOrigin: nil, importedAt: 5, productType: product, deviceModel: model)
        }
        try await store.upsertHealthSamples([sample("Watch6,1", "Watch", value: 60)])
        try await store.applyHealthSampleBatch(type: "heartRate", upserts: [sample(nil, nil, value: 61)],
                                               deletedUUIDs: [], anchor: Data([1]), updatedAt: 6)
        let row = try await store.healthSamples(type: "heartRate", from: 0, to: 5000).first
        XCTAssertEqual(row?.value, 61)
        XCTAssertEqual(row?.productType, "Watch6,1")
        XCTAssertEqual(row?.deviceModel, "Watch")
    }
}
