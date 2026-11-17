import XCTest
import WhoopStore
import WhoopProtocol
import LoopStrapEngine
@testable import Loop

/// Personal HRmax (passed by the caller) and session RPE wired into LocalMetricsEngine.
final class PersonalInputsEngineTests: XCTestCase {
    private let now = 1_794_654_000
    private var date: Date { Date(timeIntervalSince1970: Double(now)) }

    /// 1 Hz band HR for the last hour of each of `days` days, plus a resting HR sample per day,
    /// and one imported 40 min run on the last day.
    private func makeStore(days: Int = 3) async throws -> WhoopStore {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "band", mac: nil, name: nil)
        let points = (0..<days).flatMap { day in
            (0..<3600).map { n in HRSample(ts: now - day * 86400 - 3600 + n, bpm: 80 + (n / 30) % 90) }
        }
        try await store.insert(Streams(hr: points), deviceId: "band")
        let rest = (0..<days).map { day in
            HealthSample(uuid: "rhr-\(day)", type: "restingHeartRate", startDate: Double(now - day * 86400 - 7200),
                         endDate: Double(now - day * 86400 - 7200), value: 52, unit: "count/min",
                         sourceName: "Test Watch", sourceBundle: "test.watch", metadataOrigin: nil, importedAt: 0)
        }
        try await store.upsertHealthSamples(rest)
        try await store.upsertExternalWorkouts([ExternalWorkout(
            id: "RUN-1", source: "healthkit", sportType: 37, startDate: Double(now - 3000),
            endDate: Double(now - 600), durationSec: 2400, energyKcal: 400, distanceM: 6000,
            sourceName: "Test Watch", importedAt: 0)])
        return store
    }

    private func personal(_ bpm: Double, _ provenance: String = "manual") -> MaxHeartRateReference {
        MaxHeartRateReference(bpm: bpm, provenance: provenance)!
    }

    // MARK: - HRmax

    func testPersonalMaxHeartRateIsUsedAndAbsentKeepsEstimate() async throws {
        let store = try await makeStore()
        let estimated = try await LocalMetricsEngine(store: store, deviceId: "band").compute(days: 3, now: date)
        let again = try await LocalMetricsEngine(store: store, deviceId: "band")
            .compute(days: 3, personalMaxHeartRate: nil, now: date)
        XCTAssertEqual(estimated.daily, again.daily, "absent personal value = unchanged behaviour")

        let withPersonal = try await LocalMetricsEngine(store: store, deviceId: "band")
            .compute(days: 3, personalMaxHeartRate: personal(200), now: date)
        let used = withPersonal.daily.compactMap(\.strainHRmaxUsed)
        XCTAssertFalse(used.isEmpty)
        XCTAssertTrue(used.allSatisfy { $0 == 200 })
        XCTAssertNotEqual(estimated.daily.compactMap(\.strainHRmaxUsed), used)
        XCTAssertNotEqual(estimated.daily.compactMap(\.strain), withPersonal.daily.compactMap(\.strain))
    }

    func testReplayOverrideWinsOverPersonalValue() async throws {
        let store = try await makeStore()
        let engine = LocalMetricsEngine(store: store, deviceId: "band", maxHeartRateOverride: 185)
        let result = try await engine.compute(days: 3, personalMaxHeartRate: personal(200), now: date)
        let used = result.daily.compactMap(\.strainHRmaxUsed)
        XCTAssertFalse(used.isEmpty)
        XCTAssertTrue(used.allSatisfy { $0 == 185 })
    }

    func testPersonalValueEntersSettingsKeyAndInvalidatesIncrementalCache() async throws {
        let p = HealthSourcePriority.default
        let base = healthComputeSettingsKey(p, deviceId: "band")
        XCTAssertEqual(base, healthComputeSettingsKey(p, personalMaxHeartRate: nil, deviceId: "band"))
        XCTAssertTrue(base.contains("maxHR=estimated"))
        let a = healthComputeSettingsKey(p, personalMaxHeartRate: personal(190), deviceId: "band")
        let b = healthComputeSettingsKey(p, personalMaxHeartRate: personal(191), deviceId: "band")
        let c = healthComputeSettingsKey(p, personalMaxHeartRate: personal(190, "measured"), deviceId: "band")
        XCTAssertEqual(Set([base, a, b, c]).count, 4)
        XCTAssertEqual(healthComputeSettingsKey(p, maxHeartRate: 185, personalMaxHeartRate: personal(190), deviceId: "band"),
                       healthComputeSettingsKey(p, maxHeartRate: 185, deviceId: "band"))

        let store = try await makeStore()
        let engine = LocalMetricsEngine(store: store, deviceId: "band", priorityOverride: p)
        let (first, counts) = try await engine.computeCore(days: 3, previous: nil, previousDayCounts: nil,
                                                          forceFull: true, now: date)
        XCTAssertEqual(counts[base], 1)
        // Same inputs, personal value now set: the persisted fingerprint no longer matches.
        let (second, nextCounts) = try await engine.computeCore(days: 3, previous: first, previousDayCounts: counts,
            forceFull: false, personalMaxHeartRate: personal(200), now: date)
        XCTAssertNil(nextCounts[base])
        XCTAssertEqual(nextCounts[healthComputeSettingsKey(p, personalMaxHeartRate: personal(200), deviceId: "band")], 1)
        XCTAssertTrue(second.daily.compactMap(\.strainHRmaxUsed).allSatisfy { $0 == 200 })
    }

    // MARK: - RPE

    func testRPEAbsentLeavesLoadNil() async throws {
        let store = try await makeStore()
        let result = try await LocalMetricsEngine(store: store, deviceId: "band").compute(days: 3, now: date)
        let run = try XCTUnwrap(result.workoutSessions.first { $0.externalID == "RUN-1" })
        XCTAssertNil(run.perceivedEffort)
        XCTAssertNil(run.rpeLoad)
    }

    func testRPEPresentGivesSessionLoadWithoutChangingStrain() async throws {
        let store = try await makeStore()
        let without = try await LocalMetricsEngine(store: store, deviceId: "band").compute(days: 3, now: date)
        let key = WorkoutPerceivedEffort.workoutKey(externalID: "RUN-1", deviceId: "healthkit", startTs: 0)
        XCTAssertEqual(key, "external:RUN-1")
        try await PerceivedEffortStore(store: store).save(workoutId: key, rpe: 7)
        let with = try await LocalMetricsEngine(store: store, deviceId: "band").compute(days: 3, now: date)

        let run = try XCTUnwrap(with.workoutSessions.first { $0.externalID == "RUN-1" })
        let runBefore = try XCTUnwrap(without.workoutSessions.first { $0.externalID == "RUN-1" })
        XCTAssertEqual(run.perceivedEffort, 7)
        XCTAssertEqual(try XCTUnwrap(run.rpeLoad), 7 * 40, accuracy: 1e-9)
        // No double counting: session cardio load and daily strain are untouched by the RPE.
        XCTAssertEqual(run.strain, runBefore.strain)
        XCTAssertEqual(with.daily, without.daily)
    }

    func testRPEReattachedOnNoOpIncrementalPass() async throws {
        let store = try await makeStore()
        let engine = LocalMetricsEngine(store: store, deviceId: "band")
        let (first, counts) = try await engine.computeCore(days: 3, previous: nil, previousDayCounts: nil,
                                                          forceFull: true, now: date)
        try await PerceivedEffortStore(store: store).save(workoutId: "external:RUN-1", rpe: 5)
        let (second, _) = try await engine.computeCore(days: 3, previous: first, previousDayCounts: counts,
                                                      forceFull: false, now: date)
        XCTAssertEqual(second.workoutSessions.first { $0.externalID == "RUN-1" }?.perceivedEffort, 5)
        XCTAssertEqual(second.daily, first.daily)
        let attached = await engine.attachPerceivedEfforts(first.workoutSessions)
        XCTAssertEqual(attached, second.workoutSessions)
    }

    func testOldCacheWithoutRPEFieldsStillDecodes() throws {
        let json = #"{"deviceId":"band","startTs":1,"endTs":61,"avgHr":null,"peakHr":null,"strain":3.5,"kind":"detected_cardio","durationS":60,"caloriesKcal":null}"#
        let w = try JSONDecoder().decode(WorkoutSession.self, from: Data(json.utf8))
        XCTAssertNil(w.perceivedEffort)
        XCTAssertNil(w.rpeLoad)
        XCTAssertEqual(w.perceivedEffortKey, "band:band:1")
        XCTAssertNil(w.withPerceivedEffort(nil).rpeLoad)
        XCTAssertEqual(w.withPerceivedEffort(6).rpeLoad, 6)
        XCTAssertEqual(w.withPerceivedEffort(6).strain, 3.5)
    }
}
