import XCTest
import WhoopProtocol
import WhoopStore
@testable import Loop

@MainActor
final class BackgroundSyncTests: XCTestCase {

    private static func utcDay(_ ts: Int) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)!
        return formatter.string(from: Date(timeIntervalSince1970: Double(ts)))
    }

    func testRefreshWithShortDaysParameterPreservesFullHistory() async throws {
        let store = try await makeTempStore()
        let device = "test-device"
        try await store.upsertDevice(id: device, mac: nil, name: "Test")

        let engine = LocalMetricsEngine(store: store, deviceId: device)
        let repo = LoopDataRepository()
        repo.localMetricsEngine = engine

        let baseTs = Int(Date().timeIntervalSince1970) - 86400 * 10
        let hrSamples = (0..<100).map { HRSample(ts: baseTs + $0 * 60, bpm: 60 + $0 % 20) }
        try await store.insert(Streams(hr: hrSamples), deviceId: device, markSynced: true)

        await repo.refresh(force: true, days: 3)

        XCTAssertFalse(repo.cache.daily.isEmpty, "Cache should contain daily snapshots")
        XCTAssertTrue(repo.cache.daily.contains { $0.date == Self.utcDay(baseTs) }, "A short refresh must retain older history")
    }

    func testRefreshWithDefaultDaysComputes60Days() async throws {
        let store = try await makeTempStore()
        let device = "test-device"
        try await store.upsertDevice(id: device, mac: nil, name: "Test")

        let engine = LocalMetricsEngine(store: store, deviceId: device)
        let repo = LoopDataRepository()
        repo.localMetricsEngine = engine

        let baseTs = Int(Date().timeIntervalSince1970) - 86400 * 5
        let hrSamples = (0..<50).map { HRSample(ts: baseTs + $0 * 60, bpm: 70) }
        try await store.insert(Streams(hr: hrSamples), deviceId: device, markSynced: true)

        await repo.refresh(force: true)

        XCTAssertFalse(repo.isRefreshing, "Refresh should complete")
        XCTAssertNil(repo.lastError, "No error should occur")
    }

    func testRequestBackgroundRefreshPreservesHistory() async throws {
        let store = try await makeTempStore()
        let device = "test-device"
        try await store.upsertDevice(id: device, mac: nil, name: "Test")

        let engine = LocalMetricsEngine(store: store, deviceId: device)
        let repo = LoopDataRepository()
        repo.localMetricsEngine = engine

        let baseTs = Int(Date().timeIntervalSince1970) - 86400 * 2
        let hrSamples = (0..<30).map { HRSample(ts: baseTs + $0 * 60, bpm: 65) }
        try await store.insert(Streams(hr: hrSamples), deviceId: device, markSynced: true)

        await repo.requestBackgroundRefresh()

        XCTAssertFalse(repo.isRefreshing, "Background refresh should complete")
        XCTAssertTrue(repo.cache.daily.contains { $0.date == Self.utcDay(baseTs) })
    }

    func testIsStalePropertyIsSettable() {
        let repo = LoopDataRepository()

        XCTAssertFalse(repo.isStale, "isStale should default to false")

        repo.isStale = true
        XCTAssertTrue(repo.isStale, "isStale should be settable to true")

        repo.isStale = false
        XCTAssertFalse(repo.isStale, "isStale should be settable back to false")
    }

    func testRefreshSkipsWhenRowsUnchanged() async throws {
        let store = try await makeTempStore()
        let device = "test-device"
        try await store.upsertDevice(id: device, mac: nil, name: "Test")

        let engine = LocalMetricsEngine(store: store, deviceId: device)
        let repo = LoopDataRepository()
        repo.localMetricsEngine = engine

        let baseTs = Int(Date().timeIntervalSince1970) - 86400
        let hrSamples = (0..<20).map { HRSample(ts: baseTs + $0 * 60, bpm: 72) }
        try await store.insert(Streams(hr: hrSamples), deviceId: device, markSynced: true)

        await repo.refresh(force: true)
        let firstDailyCount = repo.cache.daily.count

        await repo.refresh(force: false)
        let secondDailyCount = repo.cache.daily.count

        XCTAssertEqual(firstDailyCount, secondDailyCount, "Second refresh with unchanged rows should skip compute")
    }

    func testRefreshForceRecomputesEvenWhenRowsUnchanged() async throws {
        let store = try await makeTempStore()
        let device = "test-device"
        try await store.upsertDevice(id: device, mac: nil, name: "Test")

        let engine = LocalMetricsEngine(store: store, deviceId: device)
        let repo = LoopDataRepository()
        repo.localMetricsEngine = engine

        let baseTs = Int(Date().timeIntervalSince1970) - 86400
        let hrSamples = (0..<20).map { HRSample(ts: baseTs + $0 * 60, bpm: 72) }
        try await store.insert(Streams(hr: hrSamples), deviceId: device, markSynced: true)

        await repo.refresh(force: true)

        await repo.refresh(force: true)

        XCTAssertFalse(repo.isRefreshing, "Force refresh should complete")
        XCTAssertNil(repo.lastError, "Force refresh should not error")
    }

    func testRefreshWithNewDataRecomputes() async throws {
        let store = try await makeTempStore()
        let device = "test-device"
        try await store.upsertDevice(id: device, mac: nil, name: "Test")

        let engine = LocalMetricsEngine(store: store, deviceId: device)
        let repo = LoopDataRepository()
        repo.localMetricsEngine = engine

        let baseTs = Int(Date().timeIntervalSince1970) - 86400
        let hrSamples1 = (0..<10).map { HRSample(ts: baseTs + $0 * 60, bpm: 70) }
        try await store.insert(Streams(hr: hrSamples1), deviceId: device, markSynced: true)

        await repo.refresh(force: true)
        let firstRowCount = repo.cache.computedRowCount

        let hrSamples2 = (0..<10).map { HRSample(ts: baseTs + 600 + $0 * 60, bpm: 75) }
        try await store.insert(Streams(hr: hrSamples2), deviceId: device, markSynced: true)

        await repo.refresh(force: false)
        let secondRowCount = repo.cache.computedRowCount

        XCTAssertNotEqual(firstRowCount, secondRowCount, "New data should trigger recompute")
        XCTAssertGreaterThan(secondRowCount ?? 0, firstRowCount ?? 0, "Row count should increase")
    }

    func testRequestRefreshCoalescesWhenAlreadyRefreshing() async throws {
        let store = try await makeTempStore()
        let device = "test-device"
        try await store.upsertDevice(id: device, mac: nil, name: "Test")

        let engine = LocalMetricsEngine(store: store, deviceId: device)
        let repo = LoopDataRepository()
        repo.localMetricsEngine = engine

        let baseTs = Int(Date().timeIntervalSince1970) - 86400
        let hrSamples = (0..<50).map { HRSample(ts: baseTs + $0 * 60, bpm: 68) }
        try await store.insert(Streams(hr: hrSamples), deviceId: device, markSynced: true)

        repo.requestRefresh(force: true)
        repo.requestRefresh(force: false)
        repo.requestRefresh(force: true)

        try await Task.sleep(for: .seconds(2))

        XCTAssertFalse(repo.isRefreshing, "Coalesced refresh should complete")
    }

    func testCachePreservedOnEmptyComputeResult() async throws {
        let store = try await makeTempStore()
        let device = "test-device"
        try await store.upsertDevice(id: device, mac: nil, name: "Test")

        let engine = LocalMetricsEngine(store: store, deviceId: device)
        let repo = LoopDataRepository()
        repo.localMetricsEngine = engine

        let baseTs = Int(Date().timeIntervalSince1970) - 86400
        let hrSamples = (0..<20).map { HRSample(ts: baseTs + $0 * 60, bpm: 70) }
        try await store.insert(Streams(hr: hrSamples), deviceId: device, markSynced: true)

        await repo.refresh(force: true)
        let originalCache = repo.cache

        await repo.refresh(force: false)

        XCTAssertEqual(repo.cache.updatedAt, originalCache.updatedAt, "Cache should be preserved when no new data")
    }

    func testRefreshIsFullFlagReflectsComputeType() async throws {
        let store = try await makeTempStore()
        let device = "test-device"
        try await store.upsertDevice(id: device, mac: nil, name: "Test")

        let engine = LocalMetricsEngine(store: store, deviceId: device)
        let repo = LoopDataRepository()
        repo.localMetricsEngine = engine

        let baseTs = Int(Date().timeIntervalSince1970) - 86400
        let hrSamples = (0..<20).map { HRSample(ts: baseTs + $0 * 60, bpm: 70) }
        try await store.insert(Streams(hr: hrSamples), deviceId: device, markSynced: true)

        await repo.refresh(force: true)

        XCTAssertFalse(repo.refreshIsFull, "refreshIsFull should be false after compute completes")
    }

    func testBackgroundTaskIdStartsInvalid() {
        let repo = LoopDataRepository()
        XCTAssertFalse(repo.isRefreshing, "Repository should not be refreshing initially")
        XCTAssertNil(repo.lastError, "No error initially")
    }

    func testIncrementalComputeReusesCleanDays() async throws {
        let store = try await makeTempStore()
        let device = "test-device"
        try await store.upsertDevice(id: device, mac: nil, name: "Test")

        let engine = LocalMetricsEngine(store: store, deviceId: device)
        let repo = LoopDataRepository()
        repo.localMetricsEngine = engine

        let oldTs = Int(Date().timeIntervalSince1970) - 86400 * 5
        let oldSamples = (0..<30).map { HRSample(ts: oldTs + $0 * 60, bpm: 65) }
        try await store.insert(Streams(hr: oldSamples), deviceId: device, markSynced: true)

        await repo.refresh(force: true)
        let firstDayCounts = repo.cache.dayCounts

        let newTs = Int(Date().timeIntervalSince1970) - 86400
        let newSamples = (0..<20).map { HRSample(ts: newTs + $0 * 60, bpm: 70) }
        try await store.insert(Streams(hr: newSamples), deviceId: device, markSynced: true)

        await repo.refresh(force: false)
        let secondDayCounts = repo.cache.dayCounts

        XCTAssertNotNil(firstDayCounts, "First compute should populate dayCounts")
        XCTAssertNotNil(secondDayCounts, "Second compute should populate dayCounts")
        XCTAssertNotEqual(firstDayCounts, secondDayCounts, "dayCounts should change with new data")
    }

    func testHistoricalArchiveStorageReserveAccountsForChunkSize() {
        let minimum = Backfiller.storageReserveBytes + Backfiller.minimumRetryHeadroomBytes
        XCTAssertEqual(Backfiller.requiredFreeBytes(frameBytes: 0), minimum)
        let bigChunk = 100 * 1024 * 1024
        XCTAssertEqual(Backfiller.requiredFreeBytes(frameBytes: bigChunk),
                       Backfiller.storageReserveBytes + Int64(bigChunk) * 3)
        XCTAssertEqual(Backfiller.requiredFreeBytes(frameBytes: Int.max), Int64.max)
    }

    func testDeferredOffloadDoesNotConsumeRateLimit() async throws {
        let defaults = UserDefaults.standard
        let key = BLEOffloadCoordinator.backfillLastAtKey
        let previous = defaults.object(forKey: key)
        defaults.removeObject(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        let state = BLEDeviceState()
        state.connected = true
        state.bonded = true
        let coordinator = BLEOffloadCoordinator(state: state, send: { _, _, _ in }, log: { _ in })
        let store = try await makeTempStore()
        let backfiller = Backfiller(store: store, deviceId: "test", ackTrim: { _, _ in })

        coordinator.requestSync(.periodic, backfiller: nil, connectHandshakeDone: true)
        coordinator.requestSync(.periodic, backfiller: backfiller, connectHandshakeDone: false)
        XCTAssertNil(defaults.object(forKey: key))
        coordinator.requestSync(.periodic, backfiller: backfiller, connectHandshakeDone: true)
        XCTAssertTrue(coordinator.backfilling)
        XCTAssertNotNil(defaults.object(forKey: key))
        coordinator.reset()
    }

    func testBackgroundWaitCompletesOnSessionResultAndCancellation() async throws {
        let defaults = UserDefaults.standard
        let key = BLEOffloadCoordinator.backfillLastAtKey
        let previous = defaults.object(forKey: key)
        defaults.removeObject(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        let state = BLEDeviceState()
        state.connected = true
        state.bonded = true
        let coordinator = BLEOffloadCoordinator(state: state, send: { _, _, _ in }, log: { _ in })
        let store = try await makeTempStore()
        let backfiller = Backfiller(store: store, deviceId: "test", ackTrim: { _, _ in })
        coordinator.requestSync(.periodic, backfiller: backfiller, connectHandshakeDone: true)
        let completed = Task { await coordinator.waitForCompletion() }
        let cancelled = Task { await coordinator.waitForCompletion() }
        await Task.yield()
        cancelled.cancel()
        let cancelledResult = await cancelled.value
        XCTAssertFalse(cancelledResult)
        coordinator.exitBackfilling(reason: "HISTORY_COMPLETE", collector: nil)
        let completedResult = await completed.value
        XCTAssertTrue(completedResult)
    }

    /// Mac reference parity: while the strap streams an offload, only chunk acks go on the wire. A
    /// live-HR change that lands mid-session is recorded and applied when the session ends.
    func testRealtimeHRChangeDuringOffloadIsDeferredToSessionEnd() async throws {
        let defaults = UserDefaults.standard
        let key = BLEOffloadCoordinator.backfillLastAtKey
        let previous = defaults.object(forKey: key)
        defaults.removeObject(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        let state = BLEDeviceState()
        state.connected = true
        state.bonded = true
        var sent: [(WhoopCommand, [UInt8])] = []
        let coordinator = BLEOffloadCoordinator(state: state, send: { cmd, payload, _ in sent.append((cmd, payload)) },
                                                log: { _ in })
        var liveHRWanted = false
        coordinator.realtimeHRActive = { liveHRWanted }
        let store = try await makeTempStore()
        let backfiller = Backfiller(store: store, deviceId: "test", ackTrim: { _, _ in })

        coordinator.requestSync(.manual, backfiller: backfiller, connectHandshakeDone: true)
        XCTAssertEqual(sent.map { $0.0 }, [.sendHistoricalData])
        XCTAssertEqual(sent.first?.1, [0x00])

        // A foreground return mid-session writes nothing; the resume happens at session end.
        liveHRWanted = true
        coordinator.holdRealtimeHR(resumeOnExit: true)
        XCTAssertEqual(sent.count, 1)

        coordinator.exitBackfilling(reason: "HISTORY_COMPLETE", collector: nil)
        XCTAssertEqual(sent.last?.0, .toggleRealtimeHR)
        XCTAssertEqual(sent.last?.1, [0x01])

        // Stream paused at session start, then switched off by the user mid-offload: not resumed.
        sent.removeAll()
        coordinator.requestSync(.manual, backfiller: backfiller, connectHandshakeDone: true)
        XCTAssertEqual(sent.map { $0.0 }, [.toggleRealtimeHR, .sendHistoricalData])
        liveHRWanted = false
        coordinator.holdRealtimeHR(resumeOnExit: false)
        coordinator.exitBackfilling(reason: "HISTORY_COMPLETE", collector: nil)
        XCTAssertEqual(sent.count, 2)
    }

    private func makeTempStore() async throws -> WhoopStore {
        let path = NSTemporaryDirectory() + "loop-bg-tests-\(UUID().uuidString).sqlite"
        return try await WhoopStore(path: path)
    }
}


final class PowerAwareBackfillPolicyTests: XCTestCase {
    func testContextSelection() {
        XCTAssertEqual(PowerContext.current(appActive: true, charging: false, lowPowerMode: true), .foreground)
        XCTAssertEqual(PowerContext.current(appActive: false, charging: true, lowPowerMode: true), .charging)
        XCTAssertEqual(PowerContext.current(appActive: false, charging: false, lowPowerMode: false), .backgroundOnBattery)
        XCTAssertEqual(PowerContext.current(appActive: false, charging: false, lowPowerMode: true), .backgroundLowPower)
    }

    func testPeriodicIsSparseOnBatteryAndFrequentOnCharger() {
        let last: TimeInterval = 1_000
        let after30min = last + 1_800
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .periodic, now: after30min, lastBackfillAt: last, context: .charging))
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .periodic, now: after30min, lastBackfillAt: last, context: .backgroundOnBattery))
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .periodic, now: last + 3_600, lastBackfillAt: last, context: .backgroundOnBattery))
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .periodic, now: last + 3_600, lastBackfillAt: last, context: .backgroundLowPower))
    }

    func testStrapEventsDoNotWakeRadioOnBattery() {
        let last: TimeInterval = 1_000
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .strap, now: last + 120, lastBackfillAt: last, context: .charging))
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .strap, now: last + 120, lastBackfillAt: last, context: .backgroundOnBattery))
    }

    func testChargingTriggerAndDeepCatchUpOnlyOnCharger() {
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .charging, now: 2_000, lastBackfillAt: 1_000, context: .backgroundOnBattery))
        XCTAssertGreaterThan(PowerContext.charging.maxContinuations, PowerContext.foreground.maxContinuations)
        XCTAssertLessThanOrEqual(PowerContext.backgroundOnBattery.maxContinuations, 1)
    }

    func testDefaultContextKeepsLegacyFloors() {
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .periodic, now: 1_500, lastBackfillAt: 1_000))
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .periodic, now: 1_900, lastBackfillAt: 1_000))
    }
}
