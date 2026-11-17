import XCTest
import WhoopStore
@testable import Loop

final class HealthProducerPrioritySettingsTests: XCTestCase {
    func testOrdersPersistPerMetricWithoutChangingCategoryPriority() throws {
        let suite = "HealthProducerPrioritySettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = HealthReconciliationSettings(defaults: defaults)
        settings.setOrder([.healthKit, .appleWatch], for: .stepCount)
        settings.setProducerOrder(["bundle:com.example.a", "bundle:com.example.b"], for: .stepCount)
        settings.setProducerOrder(["bundle:com.example.c"], for: .activeEnergyBurned)

        let restored = HealthReconciliationSettings(defaults: defaults)
        XCTAssertEqual(restored.producerOrder(for: .stepCount), ["bundle:com.example.a", "bundle:com.example.b"])
        XCTAssertEqual(restored.producerOrder(for: .activeEnergyBurned), ["bundle:com.example.c"])
        XCTAssertTrue(restored.producerOrder(for: .basalEnergyBurned).isEmpty)
        XCTAssertEqual(restored.load().order(for: .stepCount, context: .activity), [.healthKit, .appleWatch])
        restored.setProducerOrder([], for: .stepCount)
        XCTAssertTrue(restored.producerOrder(for: .stepCount).isEmpty)
        XCTAssertEqual(restored.producerOrder(for: .activeEnergyBurned), ["bundle:com.example.c"])
        restored.reset()
        XCTAssertTrue(restored.producerOrders().isEmpty)
        XCTAssertEqual(restored.load(), .default)
    }

    func testNormalizesBundlesAndRejectsUnstableProducerNames() throws {
        let suite = "HealthProducerPrioritySettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = HealthReconciliationSettings(defaults: defaults)
        settings.setProducerOrder([" BUNDLE:COM.EXAMPLE.APP ", "bundle:com.example.app", "name:watch",
                                   "bundle:", "bundle:two words"], for: .stepCount)
        XCTAssertEqual(settings.producerOrder(for: .stepCount), ["bundle:com.example.app"])
    }
}

final class HealthSampleMappingTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let now = Date(timeIntervalSince1970: 1_700_100_000)

    private func input(kind: HealthSampleKind = .heartRate, value: Double? = 62, endOffset: TimeInterval = 60,
                       name: String? = "Apple Watch", bundle: String? = "com.apple.health.ABC",
                       marker: String? = nil) -> HealthSampleInput {
        HealthSampleInput(uuid: "UUID-1", kind: kind, start: start, end: start.addingTimeInterval(endOffset),
                          value: value, sourceName: name, sourceBundle: bundle, originMarker: marker)
    }

    func testMapsQuantitySample() throws {
        let s = try XCTUnwrap(HealthSampleMapping.map(input(), importedAt: now))
        XCTAssertEqual(s.uuid, "UUID-1")
        XCTAssertEqual(s.type, "heartRate")
        XCTAssertEqual(s.startDate, 1_700_000_000)
        XCTAssertEqual(s.endDate, 1_700_000_060)
        XCTAssertEqual(s.value, 62)
        XCTAssertEqual(s.unit, "count/min")
        XCTAssertEqual(s.sourceName, "Apple Watch")
        XCTAssertEqual(s.sourceBundle, "com.apple.health.ABC")
        XCTAssertNil(s.metadataOrigin)
        XCTAssertEqual(s.importedAt, 1_700_100_000)
    }

    func testMapsSleepCategoryValue() throws {
        let s = try XCTUnwrap(HealthSampleMapping.map(input(kind: .sleepAnalysis, value: 4, endOffset: 3600),
                                                      importedAt: now))
        XCTAssertEqual(s.type, "sleepAnalysis")
        XCTAssertEqual(s.value, 4)
        XCTAssertEqual(s.unit, "HKCategoryValueSleepAnalysis")
    }

    func testRejectsInvalidSamples() {
        XCTAssertNil(HealthSampleMapping.map(input(value: nil), importedAt: now))
        XCTAssertNil(HealthSampleMapping.map(input(value: .nan), importedAt: now))
        XCTAssertNil(HealthSampleMapping.map(input(value: .infinity), importedAt: now))
        XCTAssertNil(HealthSampleMapping.map(input(endOffset: -1), importedAt: now))
    }

    func testInstantaneousSampleIsKept() {
        XCTAssertNotNil(HealthSampleMapping.map(input(kind: .bodyMass, value: 72.5, endOffset: 0), importedAt: now))
    }

    func testBlankSourceFieldsBecomeNil() throws {
        let s = try XCTUnwrap(HealthSampleMapping.map(input(name: "  ", bundle: ""), importedAt: now))
        XCTAssertNil(s.sourceName)
        XCTAssertNil(s.sourceBundle)
    }

    func testLoopOriginFromMetadataMarkerOrOwnBundle() throws {
        let byMarker = try XCTUnwrap(HealthSampleMapping.map(input(marker: " Loop "), importedAt: now))
        XCTAssertEqual(byMarker.metadataOrigin, "loop")
        let byBundle = try XCTUnwrap(HealthSampleMapping.map(input(bundle: "com.iblur01.Loop"), importedAt: now,
                                                             ownBundleId: "com.iblur01.Loop"))
        XCTAssertEqual(byBundle.metadataOrigin, "loop")
        let other = try XCTUnwrap(HealthSampleMapping.map(input(marker: "other"), importedAt: now,
                                                          ownBundleId: "com.iblur01.Loop"))
        XCTAssertNil(other.metadataOrigin)
    }

    func testCatalogIsStable() {
        // Les rawValue sont persistés (type + clé d'ancre) : toute modification casse les données.
        XCTAssertEqual(HealthSampleKind.allCases.map(\.rawValue), [
            "stepCount", "heartRate", "restingHeartRate", "heartRateVariabilitySDNN", "activeEnergyBurned",
            "basalEnergyBurned", "distanceWalkingRunning", "appleExerciseTime", "vo2Max", "bodyMass", "sleepAnalysis"
        ])
        XCTAssertEqual(HealthSampleKind.heartRateVariabilitySDNN.unit, "ms")
        XCTAssertEqual(HealthSampleKind.stepCount.backgroundCadence, .hourly)
        XCTAssertEqual(HealthSampleKind.sleepAnalysis.backgroundCadence, .immediate)
        XCTAssertTrue(HealthSampleKind.sleepAnalysis.isCategory)
        XCTAssertFalse(HealthSampleKind.bodyMass.isCategory)
        XCTAssertEqual(WhoopStore.healthAnchorSource(type: HealthSampleKind.vo2Max.rawValue), "healthkit:vo2Max")
    }
}


final class HealthContinuedSyncPlanTests: XCTestCase {
    func testIdentifierMatchesDeclaredWildcard() {
        XCTAssertEqual(HealthContinuedSyncPlan.wildcardIdentifier, "com.iblur01.Loop.healthsync.*")
        let id = HealthContinuedSyncPlan.makeIdentifier(suffix: "ABC")
        XCTAssertEqual(id, "com.iblur01.Loop.healthsync.ABC")
        XCTAssertTrue(HealthContinuedSyncPlan.isHealthSyncIdentifier(id))
        XCTAssertFalse(HealthContinuedSyncPlan.isHealthSyncIdentifier(HealthContinuedSyncPlan.identifierPrefix))
        XCTAssertFalse(HealthContinuedSyncPlan.isHealthSyncIdentifier("com.loop.background.refresh"))
    }

    func testIdentifiersAreUnique() {
        XCTAssertNotEqual(HealthContinuedSyncPlan.makeIdentifier(), HealthContinuedSyncPlan.makeIdentifier())
    }

    func testProgressUnitsAndFraction() {
        XCTAssertEqual(HealthContinuedSyncPlan.totalUnits, Int64(HealthSampleKind.allCases.count + 1))
        let total = HealthContinuedSyncPlan.totalUnits
        XCTAssertEqual(HealthContinuedSyncPlan.fraction(completed: 0, total: total), 0)
        XCTAssertEqual(HealthContinuedSyncPlan.fraction(completed: total, total: total), 1)
        XCTAssertEqual(HealthContinuedSyncPlan.fraction(completed: total + 5, total: total), 1)
        XCTAssertEqual(HealthContinuedSyncPlan.fraction(completed: 3, total: 0), 0)
    }
}
