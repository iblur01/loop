import XCTest
import WhoopStore
@testable import Loop

final class HealthDayCumulativeReportTests: XCTestCase {
    private let start = 1_700_000_000.0

    private func sample(_ id: String, from: Double, to: Double, value: Double, bundle: String,
                        name: String = "Other app") -> HealthSample {
        HealthSample(uuid: id, type: "stepCount", startDate: start + from, endDate: start + to,
                     value: value, unit: "count", sourceName: name, sourceBundle: bundle,
                     metadataOrigin: nil, importedAt: start)
    }

    private func row(_ samples: [HealthSample], producerOrders: [String: [String]] = [:]) -> HealthDayRow {
        let raw = HealthDayRaw(date: "2023-11-14", from: start, to: start + 7_200,
                               samples: [.stepCount: samples], workouts: [], bandHR: [])
        return HealthDayReportBuilder.build(raw: raw, snapshot: nil, bandSleep: [], bandWorkouts: [],
                                            producerOrders: producerOrders).row(.stepCount)!
    }

    func testConflictSuppressesPartialDayTotalAndPreservesDetails() {
        let result = row([
            sample("uncontested", from: 0, to: 600, value: 100, bundle: "app.a"),
            sample("a", from: 3_600, to: 4_200, value: 200, bundle: "app.a"),
            sample("b", from: 3_600, to: 4_200, value: 200, bundle: "app.b")
        ])
        XCTAssertNil(result.value)
        XCTAssertTrue(result.hasConflicts)
        XCTAssertTrue(result.points.isEmpty)
        XCTAssertEqual(Set(result.conflicts.flatMap(\.candidates).compactMap(\.producerID)),
                       Set(["bundle:app.a", "bundle:app.b"]))
        XCTAssertEqual(result.conflictSourceNames, ["Other app"])
        XCTAssertFalse(result.hasUnknownConflictSource)
    }

    func testZeroIsAValidTotalDistinctFromMissingData() {
        let result = row([sample("zero", from: 0, to: 60, value: 0, bundle: "app.a")])
        XCTAssertNotNil(result.value)
        XCTAssertFalse(result.hasConflicts)
        XCTAssertEqual(result.points.first?.value, 0)
        let missing = row([])
        XCTAssertNil(missing.value)
        XCTAssertFalse(missing.hasConflicts)
    }

    func testDisjointProducersAreIncludedWithoutConflict() {
        let result = row([
            sample("a", from: 0, to: 60, value: 100, bundle: "app.a", name: "App A"),
            sample("b", from: 60, to: 120, value: 50, bundle: "app.b", name: "App B")
        ])
        XCTAssertNotNil(result.value)
        XCTAssertFalse(result.hasConflicts)
        XCTAssertEqual(result.points.first?.value, 150)
        XCTAssertEqual(result.source, "App A · App B")
    }

    func testUnknownProducerIsExplicitlyMarked() {
        let unknown = HealthSample(uuid: "unknown", type: "stepCount", startDate: start,
                                   endDate: start + 60, value: 20, unit: "count", sourceName: nil,
                                   sourceBundle: nil, metadataOrigin: nil, importedAt: start)
        let result = row([unknown])
        XCTAssertNil(result.value)
        XCTAssertTrue(result.hasConflicts)
        XCTAssertTrue(result.hasUnknownConflictSource)
        XCTAssertEqual(result.conflicts.first?.reason, .unknownProducer)
    }

    func testExplicitProducerOrderResolvesOverlapForSelectedMetricOnly() {
        let samples = [
            sample("a", from: 0, to: 60, value: 100, bundle: "app.a", name: "App A"),
            sample("b", from: 0, to: 60, value: 200, bundle: "app.b", name: "App B")
        ]
        let preferred = row(samples, producerOrders: [HealthSampleKind.stepCount.rawValue: ["bundle:app.b", "bundle:app.a"]])
        XCTAssertFalse(preferred.hasConflicts)
        XCTAssertEqual(preferred.points.first?.value, 200)
        XCTAssertEqual(preferred.source, "App B")
        let otherMetricOnly = row(samples, producerOrders: [HealthSampleKind.activeEnergyBurned.rawValue: ["bundle:app.b"]])
        XCTAssertTrue(otherMetricOnly.hasConflicts)
        XCTAssertNil(otherMetricOnly.value)
    }
}

final class HealthKitMappingTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func input(kcal: Double? = 320, dist: Double? = 5000, name: String? = "Apple Watch", bundle: String? = "com.apple.health") -> HealthWorkoutInput {
        HealthWorkoutInput(id: "UUID-1", activityTypeRaw: 37, start: start, end: start.addingTimeInterval(1800),
                           duration: 1750, energyKcal: kcal, distanceM: dist, sourceName: name, sourceBundle: bundle)
    }

    func testMapsCoreFields() {
        let w = HealthWorkoutMapping.map(input(), importedAt: start.addingTimeInterval(5000))
        XCTAssertEqual(w.id, "UUID-1")
        XCTAssertEqual(w.source, "healthkit")
        XCTAssertEqual(w.sportType, 37)
        XCTAssertEqual(w.startDate, 1_700_000_000)
        XCTAssertEqual(w.endDate, 1_700_001_800)
        XCTAssertEqual(w.durationSec, 1750)
        XCTAssertEqual(w.energyKcal, 320)
        XCTAssertEqual(w.distanceM, 5000)
        XCTAssertEqual(w.sourceName, "Apple Watch")
        XCTAssertEqual(w.sourceBundle, "com.apple.health")
        XCTAssertEqual(w.importedAt, 1_700_005_000)
    }

    func testNilEnergyAndDistanceStayNil() {
        let w = HealthWorkoutMapping.map(input(kcal: nil, dist: nil), importedAt: start)
        XCTAssertNil(w.energyKcal)
        XCTAssertNil(w.distanceM)
    }

    func testBundleIsNormalized() {
        XCTAssertEqual(HealthWorkoutMapping.map(input(bundle: "  com.example.app  "), importedAt: start).sourceBundle, "com.example.app")
        XCTAssertNil(HealthWorkoutMapping.map(input(bundle: "  "), importedAt: start).sourceBundle)
        XCTAssertNil(HealthWorkoutMapping.map(input(bundle: nil), importedAt: start).sourceBundle)
    }

    func testBlankSourceNameBecomesNil() {
        XCTAssertNil(HealthWorkoutMapping.map(input(name: "  "), importedAt: start).sourceName)
        XCTAssertNil(HealthWorkoutMapping.map(input(name: nil), importedAt: start).sourceName)
    }
}
