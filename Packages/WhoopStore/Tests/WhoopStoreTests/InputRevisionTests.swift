import XCTest
import WhoopProtocol
@testable import WhoopStore

final class InputRevisionTests: XCTestCase {
    func testReplacementAndDeletionWithUnchangedCount() async throws {
        let store = try await WhoopStore.inMemory()
        func sample(_ value: Double) -> HealthSample {
            HealthSample(uuid: "one", type: "heartRate", startDate: 86_350, endDate: 86_450,
                         value: value, unit: "bpm", sourceName: "Watch", sourceBundle: nil,
                         metadataOrigin: nil, importedAt: 1)
        }
        let initial = try await store.inputRevisions()
        try await store.upsertHealthSamples([sample(70)])
        let inserted = try await store.inputRevisions()
        XCTAssertGreaterThan(inserted.revision, initial.revision)
        XCTAssertNotNil(inserted.days["1970-01-01"])
        XCTAssertNotNil(inserted.days["1970-01-02"])
        try await store.upsertHealthSamples([sample(90)])
        let replaced = try await store.inputRevisions()
        XCTAssertGreaterThan(replaced.revision, inserted.revision)
        XCTAssertGreaterThan(replaced.days["1970-01-01"]!, inserted.days["1970-01-01"]!)
        let count = try await store.healthSampleCount(type: "heartRate")
        XCTAssertEqual(count, 1)
        try await store.deleteHealthSamples(uuids: ["one"])
        let deleted = try await store.inputRevisions()
        XCTAssertGreaterThan(deleted.revision, replaced.revision)
        XCTAssertEqual(initial.instance, deleted.instance)
    }

    func testWorkoutAndBandWritesAdvanceRevisionButAnchorsDoNot() async throws {
        let store = try await WhoopStore.inMemory()
        let initial = try await store.inputRevisions()
        try await store.setHealthSyncAnchor(type: "heartRate", data: Data([1]), updatedAt: 1)
        let anchor = try await store.inputRevisions()
        XCTAssertEqual(anchor.revision, initial.revision)
        let workout = ExternalWorkout(id: "w", source: "healthkit", sportType: 37, startDate: 1000,
            endDate: 2000, durationSec: 1000, energyKcal: nil, distanceM: nil, sourceName: nil, importedAt: 1)
        try await store.upsertExternalWorkouts([workout])
        let added = try await store.inputRevisions()
        XCTAssertGreaterThan(added.revision, anchor.revision)
        try await store.deleteExternalWorkouts(ids: ["w"])
        let deleted = try await store.inputRevisions()
        XCTAssertGreaterThan(deleted.revision, added.revision)
        try await store.upsertDevice(id: "d", mac: nil, name: nil)
        try await store.insert(Streams(hr: [HRSample(ts: 1000, bpm: 72)]), deviceId: "d")
        let band = try await store.inputRevisions()
        XCTAssertGreaterThan(band.revision, deleted.revision)
    }

    func testMultidaySampleMarksEveryAffectedDay() async throws {
        let store = try await WhoopStore.inMemory()
        let sample = HealthSample(uuid: "long", type: "sleepAnalysis", startDate: 1,
            endDate: 3 * 86_400 + 1, value: 1, unit: "category", sourceName: nil,
            sourceBundle: nil, metadataOrigin: nil, importedAt: 1)
        try await store.upsertHealthSamples([sample])
        let revisions = try await store.inputRevisions()
        for day in ["1970-01-01", "1970-01-02", "1970-01-03", "1970-01-04"] {
            XCTAssertNotNil(revisions.days[day], "missing \(day)")
        }
    }
}
