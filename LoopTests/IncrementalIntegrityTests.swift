import XCTest
import WhoopProtocol
import WhoopStore
@testable import Loop

@MainActor
final class IncrementalIntegrityTests: XCTestCase {
    #if canImport(UIKit)
    func testBackgroundRefreshPreservesOlderHistoryAfterNewData() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "band", mac: nil, name: nil)
        let now = Int(Date().timeIntervalSince1970)
        try await store.insert(Streams(hr: [HRSample(ts: now - 8 * 86400, bpm: 72)]), deviceId: "band")
        let repo = LoopDataRepository()
        repo.attach(engine: LocalMetricsEngine(store: store, deviceId: "band"))
        await repo.refresh(force: true)
        let before = Set(repo.cache.daily.map(\.date))
        XCTAssertFalse(before.isEmpty)
        try await store.insert(Streams(hr: [HRSample(ts: now - 86400, bpm: 75)]), deviceId: "band")
        await repo.requestBackgroundRefresh()
        XCTAssertTrue(before.isSubset(of: Set(repo.cache.daily.map(\.date))))
        XCTAssertNil(repo.lastError)
    }
    #endif

    func testWorkoutDeletionTriggersRecomputeWithUnchangedBandRows() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "band", mac: nil, name: nil)
        let now = Int(Date().timeIntervalSince1970)
        try await store.insert(Streams(hr: [HRSample(ts: now - 4000, bpm: 80)]), deviceId: "band")
        let w = ExternalWorkout(id: "workout", source: "healthkit", sportType: 37,
            startDate: Double(now - 3600), endDate: Double(now - 1800), durationSec: 1800,
            energyKcal: nil, distanceM: 4000, sourceName: "Watch", importedAt: Double(now))
        try await store.upsertExternalWorkouts([w])
        let engine = LocalMetricsEngine(store: store, deviceId: "band")
        let (first, counts) = try await engine.computeCore(days: 3, previous: nil, previousDayCounts: nil, forceFull: true)
        XCTAssertTrue(first.workoutSessions.contains { $0.externalID == "workout" })
        try await store.deleteExternalWorkouts(ids: ["workout"])
        let (updated, updatedCounts) = try await engine.computeCore(days: 3, previous: first, previousDayCounts: counts, forceFull: false)
        XCTAssertNotEqual(counts, updatedCounts)
        XCTAssertFalse(updated.workoutSessions.contains { $0.externalID == "workout" })
    }

    func testWorkoutHeartRateUsesSessionBoundsAndRequiresCoverage() async throws {
        let store = try await WhoopStore.inMemory()
        let now = 1_794_654_000 // fixed timestamp, safely within one UTC day
        try await store.upsertDevice(id: "band", mac: nil, name: nil)
        let heart = (0..<1200).map { HRSample(ts: now - 1800 + $0, bpm: 140 + $0 % 20) }
        try await store.insert(Streams(hr: heart), deviceId: "band")
        let workout = ExternalWorkout(id: "run", source: "healthkit", sportType: 37,
            startDate: Double(now - 1800), endDate: Double(now - 600), durationSec: 1200,
            energyKcal: nil, distanceM: 4000, sourceName: "Watch", importedAt: Double(now))
        try await store.upsertExternalWorkouts([workout])
        let engine = LocalMetricsEngine(store: store, deviceId: "band")
        let result = try await engine.compute(days: 2, now: Date(timeIntervalSince1970: Double(now)))
        let session = try XCTUnwrap(result.workoutSessions.first { $0.externalID == "run" })
        XCTAssertEqual(try XCTUnwrap(session.avgHr), 149.5, accuracy: 0.01)
        XCTAssertEqual(session.peakHr, 159)
        // No reference resting HR is available, so no strain is invented.
        XCTAssertNil(session.strain)
    }

    func testExplicitActivityUsesPreferredExternalHeartRateWithoutDoubleCounting() async throws {
        let store = try await WhoopStore.inMemory()
        let now = 1_794_654_000
        try await store.upsertDevice(id: "band", mac: nil, name: nil)
        try await store.insert(Streams(hr: (0..<1200).map { HRSample(ts: now - 1800 + $0, bpm: 120) }), deviceId: "band")
        let samples = (0..<240).map { i in
            let t = Double(now - 1800 + i * 5)
            return HealthSample(uuid: "watch-\(i)", type: "heartRate", startDate: t, endDate: t,
                                value: 160, unit: "count/min", sourceName: "Apple Watch",
                                sourceBundle: "watch", metadataOrigin: nil, importedAt: Double(now))
        }
        try await store.upsertHealthSamples(samples)
        try await store.upsertExternalWorkouts([ExternalWorkout(id: "run", source: "healthkit", sportType: 37,
            startDate: Double(now - 1800), endDate: Double(now - 600), durationSec: 1200,
            energyKcal: nil, distanceM: 4000, sourceName: "Apple Watch", importedAt: Double(now))])
        let engine = LocalMetricsEngine(store: store, deviceId: "band", priorityOverride: .default)
        let result = try await engine.compute(days: 2, now: Date(timeIntervalSince1970: Double(now)))
        let session = try XCTUnwrap(result.workoutSessions.first { $0.externalID == "run" })
        XCTAssertEqual(try XCTUnwrap(session.avgHr), 160, accuracy: 0.01)
        XCTAssertEqual(session.peakHr, 160)
        var bandFirst = HealthSourcePriority.default
        bandFirst.orders[HealthSourcePriority.key(.heartRate, .activity)] = [.whoop, .appleWatch, .healthKit]
        let otherEngine = LocalMetricsEngine(store: store, deviceId: "band", priorityOverride: bandFirst)
        let other = try await otherEngine.compute(days: 2, now: Date(timeIntervalSince1970: Double(now)))
        let bandSession = try XCTUnwrap(other.workoutSessions.first { $0.externalID == "run" })
        XCTAssertEqual(try XCTUnwrap(bandSession.avgHr), 120, accuracy: 0.01)
    }

    func testRecoveryAndStrainEvidenceSurvivesSnapshotEncoding() throws {
        let snapshot = DailySnapshot(date: "2026-01-01", totalSleepMin: nil, efficiency: nil,
            deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil, sleepStart: nil, sleepEnd: nil,
            sleepScore: nil, restingHR: 60, avgHrv: 65, recovery: 52, recoveryStatus: "medium",
            recoveryBand: "yellow", strain: 8, sleepTargetMin: nil, targetStrain: nil,
            targetStrainConfidence: nil, recentOverload: nil, adviceSignals: [],
            recoveryZHrv: 0.3, recoveryZRhr: -0.2, recoveryZResp: nil,
            strainObservedMinutes: 75, strainBelowZoneMinutes: 20,
            strainHRmaxUsed: 185, strainRestingHRUsed: 60)
        let decoded = try JSONDecoder().decode(DailySnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.strainHRmaxUsed, 185)
        XCTAssertEqual(decoded.recoveryZHrv, 0.3)
    }

    func testExplicitMaximumHeartRateIsUsedAndVersioned() async throws {
        let store = try await WhoopStore.inMemory()
        let now = 1_794_654_000
        try await store.upsertDevice(id: "band", mac: nil, name: nil)
        try await store.insert(Streams(hr: (0..<1200).map { HRSample(ts: now - 1800 + $0, bpm: 150) }), deviceId: "band")
        try await store.upsertHealthSamples([HealthSample(uuid: "rhr", type: "restingHeartRate",
            startDate: Double(now - 1800), endDate: Double(now - 1800), value: 60, unit: "count/min",
            sourceName: "Apple Watch", sourceBundle: "watch", metadataOrigin: nil, importedAt: Double(now))])
        let engine = LocalMetricsEngine(store: store, deviceId: "band", priorityOverride: .default, maxHeartRateOverride: 190)
        let (result, counts) = try await engine.computeCore(days: 2, previous: nil, previousDayCounts: nil,
            forceFull: true, now: Date(timeIntervalSince1970: Double(now)))
        let day = try XCTUnwrap(result.daily.first { $0.strain != nil })
        XCTAssertEqual(day.strainHRmaxUsed, 190)
        XCTAssertEqual(counts[healthComputeSettingsKey(.default, maxHeartRate: 190, deviceId: "band")], 1)
        XCTAssertNil(counts[healthComputeSettingsKey(.default, maxHeartRate: 180, deviceId: "band")])
        let invalid = LocalMetricsEngine(store: store, deviceId: "band", maxHeartRateOverride: .infinity)
        do {
            _ = try await invalid.compute(days: 2, now: Date(timeIntervalSince1970: Double(now)))
            XCTFail("Invalid manual heart rate must not silently fall back to an estimate")
        } catch { }
    }

    func testHealthRecoveryObservationsKeepSourcesAndRequireCoverage() throws {
        func sample(_ id: String, _ type: String, _ time: Double, _ value: Double,
                    _ source: String, _ bundle: String) -> HealthSample {
            HealthSample(uuid: id, type: type, startDate: time, endDate: time, value: value,
                unit: type == "heartRate" ? "count/min" : "ms", sourceName: source,
                sourceBundle: bundle, metadataOrigin: nil, importedAt: 0)
        }
        let raw = (0..<6).map { sample("hr\($0)", "heartRate", Double($0 * 400), 60 + Double($0), "Apple Watch", "watch-a") }
        let hr = try XCTUnwrap(HealthRecoveryInputs.observation(raw, kind: .heartRate, priority: .default))
        XCTAssertEqual(hr.value, 62.5)
        XCTAssertEqual(hr.sampleCount, 6)
        XCTAssertTrue(hr.sourceID.contains("sleep-median-hr-v1"))
        XCTAssertNil(HealthRecoveryInputs.observation(Array(raw.prefix(4)), kind: .heartRate, priority: .default))
        let sdnn = [sample("a", "heartRateVariabilitySDNN", 1, 50, "Apple Watch", "watch-a"),
                    sample("b", "heartRateVariabilitySDNN", 2, 70, "Apple Watch", "watch-a"),
                    sample("c", "heartRateVariabilitySDNN", 3, 200, "Other app", "other")]
        let measurement = try XCTUnwrap(HealthRecoveryInputs.observation(sdnn, kind: .heartRateVariabilitySDNN, priority: .default))
        XCTAssertEqual(measurement.value, 60)
        XCTAssertEqual(measurement.sampleCount, 2)
        XCTAssertTrue(measurement.sourceID.contains("watch-a"))
    }

    func testWatchOnlyRecoveryUsesSeparateHistoryAndSurvivesIncrementalReplay() async throws {
        let store = try await WhoopStore.inMemory()
        let now = 1_794_654_000
        let midnight = now / 86400 * 86400
        var rows: [HealthSample] = []
        func sample(_ id: String, _ type: String, _ start: Int, _ end: Int, _ value: Double) -> HealthSample {
            HealthSample(uuid: id, type: type, startDate: Double(start), endDate: Double(end), value: value,
                unit: type == "sleepAnalysis" ? "HKCategoryValueSleepAnalysis" : (type == "heartRate" ? "count/min" : "ms"),
                sourceName: "Apple Watch", sourceBundle: "watch-a", metadataOrigin: nil, importedAt: Double(now))
        }
        for offset in -5...0 {
            let start = midnight + offset * 86400 + 3600
            rows.append(sample("sleep\(offset)", "sleepAnalysis", start, start + 6 * 3600, 3))
            rows.append(sample("sdnn\(offset)", "heartRateVariabilitySDNN", start + 1200, start + 1200, 55 + Double(offset)))
            for i in 0..<6 {
                rows.append(sample("hr\(offset)-\(i)", "heartRate", start + i * 600, start + i * 600, 60 + Double(i)))
            }
        }
        try await store.upsertHealthSamples(rows)
        let engine = LocalMetricsEngine(store: store, deviceId: "band", priorityOverride: .default)
        let (initial, fingerprints) = try await engine.computeCore(days: 6, previous: nil, previousDayCounts: nil,
            forceFull: true, now: Date(timeIntervalSince1970: Double(now)))
        let day = try XCTUnwrap(initial.daily.last)
        XCTAssertNotNil(day.recovery)
        XCTAssertEqual(day.recoveryHRVMetric, "sdnn")
        XCTAssertEqual(day.recoveryStatus, "medium")
        XCTAssertNil(day.avgHrv, "SDNN must never be stored in the bracelet's RMSSD field")
        XCTAssertTrue(try XCTUnwrap(day.recoveryRHRObservation).sourceID.contains("sleep-median-hr"))
        let revised = sample("sdnn-1", "heartRateVariabilitySDNN", midnight - 86400 + 3600 + 1200,
                             midnight - 86400 + 3600 + 1200, 70)
        try await store.upsertHealthSamples([revised])
        let incremental = try await engine.computeCore(days: 6, previous: initial, previousDayCounts: fingerprints,
            forceFull: false, now: Date(timeIntervalSince1970: Double(now))).result
        let full = try await engine.compute(days: 6, now: Date(timeIntervalSince1970: Double(now)))
        XCTAssertEqual(incremental.daily, full.daily)
    }

    func testLocalDayBoundsFollowParisDST() async throws {
        let store = try await WhoopStore.inMemory()
        let zone = try XCTUnwrap(TimeZone(identifier: "Europe/Paris"))
        let engine = LocalMetricsEngine(store: store, deviceId: "band", timeZone: zone)
        var paris = Calendar(identifier: .gregorian)
        paris.timeZone = zone
        for (day, expectedHours) in [("2026-03-29", 23), ("2026-10-25", 25)] {
            let pieces = day.split(separator: "-").compactMap { Int($0) }
            let start = try XCTUnwrap(paris.date(from: DateComponents(year: pieces[0], month: pieces[1], day: pieces[2])))
            let end = try XCTUnwrap(paris.date(byAdding: .day, value: 1, to: start))
            let local = await engine.dayBounds(day, now: end)
            XCTAssertEqual(end.timeIntervalSince(start), Double(expectedHours * 3600))
            XCTAssertEqual(local.to - local.from + 1, expectedHours * 3600)
            XCTAssertEqual(Double(local.from), start.timeIntervalSince1970)
        }
    }
}
