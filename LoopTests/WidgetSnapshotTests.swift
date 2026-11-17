import XCTest
@testable import Loop

final class WidgetSnapshotTests: XCTestCase {
    private func daily(date: String, sleep: Double?, recovery: Double?, strain: Double?, express: Bool = false) -> DailySnapshot {
        DailySnapshot(date: date, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                      lightMin: nil, disturbances: nil, sleepStart: nil, sleepEnd: nil,
                      sleepScore: sleep, restingHR: nil, avgHrv: nil, recovery: recovery,
                      recoveryStatus: "low", recoveryBand: nil, strain: strain,
                      sleepTargetMin: nil, targetStrain: nil, targetStrainConfidence: nil,
                      recentOverload: nil, adviceSignals: [], isExpress: express)
    }

    private func cache(_ days: [DailySnapshot], updatedAt: Date? = Date()) -> LoopCache {
        var cache = LoopCache.empty
        cache.daily = days
        cache.updatedAt = updatedAt
        return cache
    }

    func testLoadingPreservesPriorMetricsAndBattery() {
        let old = LoopWidgetSnapshotBuilder.make(cache: cache([daily(date: "2026-11-14", sleep: 80, recovery: 65, strain: 12)]),
                                                 previous: .placeholder, battery: 75, isCharging: false, isPurging: false)
        let loading = LoopWidgetSnapshotBuilder.make(cache: .empty, previous: old, battery: nil, isCharging: false, isPurging: false)
        XCTAssertEqual(loading, old)
    }

    func testUsesLatestDayWithoutPresentingOlderMetricsAsToday() {
        let days = [daily(date: "2026-11-15", sleep: nil, recovery: nil, strain: 4, express: true),
                    daily(date: "2026-11-14", sleep: 80, recovery: 65, strain: 12)]
        let result = LoopWidgetSnapshotBuilder.make(cache: cache(days), previous: .placeholder, battery: 0.5,
                                                    isCharging: true, isPurging: false)
        XCTAssertEqual(result.sleep.valueText, "--")
        XCTAssertEqual(result.recovery.valueText, "--")
        XCTAssertEqual(result.strain.valueText, "4.0")
        XCTAssertEqual(result.battery.valueText, "50%")
        XCTAssertEqual(result.battery.tintHex, "36B56A")
    }

    func testPurgeClearsMetricsInsteadOfPreservingLoadingSnapshot() {
        let old = LoopWidgetSnapshotBuilder.make(cache: cache([daily(date: "2026-11-14", sleep: 80, recovery: 65, strain: 12)]),
                                                 previous: .placeholder, battery: nil, isCharging: false, isPurging: false)
        let purged = LoopWidgetSnapshotBuilder.make(cache: .empty, previous: old, battery: nil, isCharging: false, isPurging: true)
        XCTAssertEqual(purged.sleep.valueText, "--")
        XCTAssertEqual(purged.recovery.valueText, "--")
        XCTAssertEqual(purged.strain.valueText, "--")
    }

    func testExpressMarkerSurvivesCacheRoundTripAndLegacyDefaultsToFull() throws {
        let provisional = daily(date: "2026-11-15", sleep: nil, recovery: nil, strain: 4, express: true)
        let data = try JSONEncoder().encode(provisional)
        XCTAssertTrue(try JSONDecoder().decode(DailySnapshot.self, from: data).isExpress)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "isExpress")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        XCTAssertFalse(try JSONDecoder().decode(DailySnapshot.self, from: legacyData).isExpress)
    }

    func testLegacyCacheKeepsMigrationPendingAcrossUnrelatedWrites() throws {
        let original = cache([daily(date: "2026-11-15", sleep: nil, recovery: nil, strain: 4)])
        let data = try JSONEncoder().encode(original)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "expressMigrationComplete")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        let restored = try JSONDecoder().decode(LoopCache.self, from: legacyData)
        XCTAssertFalse(restored.expressMigrationComplete)
        XCTAssertEqual(restored.daily, original.daily)

        let rewritten = try JSONDecoder().decode(LoopCache.self, from: JSONEncoder().encode(restored))
        XCTAssertFalse(rewritten.expressMigrationComplete)
        XCTAssertEqual(rewritten.daily, original.daily)
        var recomputed = rewritten
        recomputed.expressMigrationComplete = true
        let migrated = try JSONDecoder().decode(LoopCache.self, from: JSONEncoder().encode(recomputed))
        XCTAssertTrue(migrated.expressMigrationComplete)
    }
}
