import XCTest
import WhoopProtocol
import WhoopStore
@testable import Loop

/// Local calendar-day policy end to end: strain, sleep, workouts, DST, incremental parity, travel.
final class LocalDayPipelineTests: XCTestCase {
    private let paris = TimeZone(identifier: "Europe/Paris")!
    private let newYork = TimeZone(identifier: "America/New_York")!

    private func ts(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0, in zone: TimeZone) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return Int(cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!.timeIntervalSince1970)
    }

    private func at(_ t: Int) -> Date { Date(timeIntervalSince1970: Double(t)) }

    private func heart(_ from: Int, _ to: Int, step: Int = 1, bpm: Int) -> [HRSample] {
        stride(from: from, to: to, by: step).map { HRSample(ts: $0, bpm: bpm) }
    }

    private func watchSample(_ id: String, _ type: String, _ start: Int, _ end: Int, _ value: Double) -> HealthSample {
        HealthSample(uuid: id, type: type, startDate: Double(start), endDate: Double(end), value: value,
                     unit: type == "sleepAnalysis" ? "HKCategoryValueSleepAnalysis" : "count/min",
                     sourceName: "Apple Watch", sourceBundle: "watch", metadataOrigin: nil, importedAt: 0)
    }

    private func makeStore() async throws -> WhoopStore {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "band", mac: nil, name: nil)
        return store
    }

    func testHeartRateDetailReadsCompleteRequestedInterval() async throws {
        let store = try await makeStore()
        let rows = heart(1_000, 4_000, bpm: 72)
        try await store.insert(Streams(hr: rows), deviceId: "band")
        let engine = LocalMetricsEngine(store: store, deviceId: "band")
        let samples = try await engine.heartRateSamples(from: 1_200, to: 3_800)
        XCTAssertEqual(samples.count, 2_601)
        XCTAssertEqual(samples.first?.ts, 1_200)
        XCTAssertEqual(samples.last?.ts, 3_800)
    }

    func testHeartRateChartPreservesExtremaAndBreaksGaps() {
        let samples = [HeartRateSample(ts: 100, bpm: 70), HeartRateSample(ts: 110, bpm: 130),
                       HeartRateSample(ts: 120, bpm: 50), HeartRateSample(ts: 130, bpm: 80),
                       HeartRateSample(ts: 1_000, bpm: 75)]
        let segments = HeartRateCoachModel.chartSegments(samples, bucketSeconds: 60)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.flatMap(\.samples).map(\.bpm), [70, 130, 50, 80, 75])
    }


    func testStepsUseWatchBeforePhoneAndIgnoreBand() throws {
        let start = Double(ts(2026, 11, 13, 0, in: paris))
        func sample(_ id: String, _ from: Double, _ to: Double, _ value: Double, _ name: String?, _ origin: String?, _ product: String?) -> HealthSample {
            HealthSample(uuid: id, type: "stepCount", startDate: start + from, endDate: start + to,
                         value: value, unit: "count", sourceName: name, sourceBundle: nil,
                         metadataOrigin: origin, importedAt: 0, productType: product, deviceModel: nil)
        }
        let samples = [sample("watch", 0, 60, 60, "Renommée", nil, "Watch6,1"),
                       sample("phone", 30, 90, 120, "watch de poche", nil, "iPhone15,2"),
                       sample("band", 0, 90, 999, "WHOOP", nil, "Watch6,1")]
        let raw = HealthDayRaw(date: "2026-11-13", from: start, to: start + 3600,
                               samples: [.stepCount: samples], workouts: [], bandHR: [])
        let report = HealthDayReportBuilder.build(raw: raw, snapshot: nil, bandSleep: [], bandWorkouts: [])
        let row = try XCTUnwrap(report.row(.stepCount))
        XCTAssertFalse(row.hasConflicts)
        XCTAssertEqual(row.points.reduce(0) { $0 + $1.value }, 120, accuracy: 0.001)
        XCTAssertEqual(row.source, "Apple Watch · iPhone")
    }

    func testStepsExcludeAmbiguousWindowsAndMarkPartialTotal() throws {
        let start = Double(ts(2026, 11, 13, 0, in: paris))
        func sample(_ id: String, _ from: Double, _ to: Double, _ bundle: String) -> HealthSample {
            HealthSample(uuid: id, type: "stepCount", startDate: start + from, endDate: start + to,
                         value: 120, unit: "count", sourceName: "Apple Watch", sourceBundle: bundle,
                         metadataOrigin: nil, importedAt: 0, productType: "Watch6,1", deviceModel: nil)
        }
        // Distinct producers and self-overlap have the same unambiguous tails.
        for secondBundle in ["watch.a", "watch.b"] {
            let raw = HealthDayRaw(date: "2026-11-13", from: start, to: start + 3600,
                                   samples: [.stepCount: [sample("a", 0, 120, "watch.a"), sample("b", 60, 180, secondBundle)]], workouts: [], bandHR: [])
            let row = try XCTUnwrap(HealthDayReportBuilder.build(raw: raw, snapshot: nil, bandSleep: [], bandWorkouts: []).row(.stepCount))
            XCTAssertTrue(row.isPartial)
            XCTAssertNotNil(row.value)
            XCTAssertEqual(row.source, "Apple Watch")
            let series = HealthSourceSeries.groupedByProducer(raw.samples[.stepCount]!, stepsOnly: true)
            let bucket = try XCTUnwrap(HealthReconciliation.mergeCumulativeSeries(kind: .stepCount, series: series,
                from: Date(timeIntervalSince1970: start), to: Date(timeIntervalSince1970: start + 180), bucket: 180).buckets.first)
            XCTAssertEqual(bucket.partialValue, 120)
            XCTAssertNil(bucket.value)
        }
    }

    func testStepsUnknownDeviceRemainsIncomplete() throws {
        let start = Double(ts(2026, 11, 13, 0, in: paris))
        let sample = HealthSample(uuid: "unknown", type: "stepCount", startDate: start, endDate: start + 60,
                                  value: 20, unit: "count", sourceName: "Autre", sourceBundle: "other.app",
                                  metadataOrigin: nil, importedAt: 0)
        let raw = HealthDayRaw(date: "2026-11-13", from: start, to: start + 3600,
                               samples: [.stepCount: [sample]], workouts: [], bandHR: [])
        let row = try XCTUnwrap(HealthDayReportBuilder.build(raw: raw, snapshot: nil, bandSleep: [], bandWorkouts: []).row(.stepCount))
        XCTAssertNil(row.value)
        XCTAssertTrue(row.conflicts.contains { $0.reason == .unknownProducer })
    }

    // MARK: - Strain between 00:00 and 02:00 local

    func testStrainBetweenMidnightAndTwoBelongsToTheLocalDay() async throws {
        let store = try await makeStore()
        // 00:15 → 01:45 Paris on 13 Nov = 23:15Z (12 Nov) → 00:45Z: split in two by a UTC policy.
        try await store.insert(Streams(hr: heart(ts(2026, 11, 13, 0, 15, in: paris), ts(2026, 11, 13, 1, 45, in: paris), bpm: 150)),
                               deviceId: "band")
        try await store.upsertHealthSamples([watchSample("rhr", "restingHeartRate", ts(2026, 11, 13, 1, in: paris),
                                                         ts(2026, 11, 13, 1, in: paris), 60)])
        let engine = LocalMetricsEngine(store: store, deviceId: "band", priorityOverride: .default,
                                        maxHeartRateOverride: 190, timeZone: paris)
        let result = try await engine.compute(days: 3, now: at(ts(2026, 11, 13, 12, in: paris)))
        XCTAssertEqual(result.daily.map(\.date), ["2026-11-13"])
        let day = try XCTUnwrap(result.daily.first)
        XCTAssertNotNil(day.strain)
        XCTAssertEqual(try XCTUnwrap(day.strainObservedMinutes), 90, accuracy: 1.5)
        XCTAssertEqual(day.timeZone, "Europe/Paris")
        XCTAssertEqual(result.dayTimeZones["2026-11-13"], "Europe/Paris")
    }

    // MARK: - Night crossing midnight

    func testHealthNightsAreAttributedByLocalEndDay() async throws {
        let store = try await makeStore()
        // Night 1: 23:00 (12 Nov) → 07:00 (13 Nov) local. Night 2 ends at 00:30 local on 14 Nov,
        // which is still 13 Nov in UTC.
        try await store.upsertHealthSamples([
            watchSample("n1", "sleepAnalysis", ts(2026, 11, 12, 23, in: paris), ts(2026, 11, 13, 7, in: paris), 3),
            watchSample("n2", "sleepAnalysis", ts(2026, 11, 13, 21, in: paris), ts(2026, 11, 14, 0, 30, in: paris), 3)
        ])
        let engine = LocalMetricsEngine(store: store, deviceId: "band", priorityOverride: .default, timeZone: paris)
        let result = try await engine.compute(days: 3, now: at(ts(2026, 11, 14, 12, in: paris)))
        let byDay = Dictionary(uniqueKeysWithValues: result.daily.map { ($0.date, $0) })
        XCTAssertEqual(try XCTUnwrap(byDay["2026-11-13"]?.totalSleepMin), 480, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(byDay["2026-11-14"]?.totalSleepMin), 210, accuracy: 0.01)
        XCTAssertNil(byDay["2026-11-12"])
    }

    // MARK: - Workout crossing midnight

    func testBandWorkoutCrossingLocalMidnightIsDetectedOnce() async throws {
        let store = try await makeStore()
        let start = ts(2026, 11, 13, 23, 40, in: paris), end = ts(2026, 11, 14, 0, 30, in: paris)
        let rows = heart(ts(2026, 11, 13, 20, in: paris), start, bpm: 60) + heart(start, end, bpm: 150)
            + heart(end, ts(2026, 11, 14, 3, in: paris), bpm: 60)
        try await store.insert(Streams(hr: rows), deviceId: "band")
        let engine = LocalMetricsEngine(store: store, deviceId: "band", priorityOverride: .default, timeZone: paris)
        let result = try await engine.compute(days: 3, now: at(ts(2026, 11, 14, 12, in: paris)))
        let band = result.workoutSessions.filter { $0.externalID == nil }
        XCTAssertEqual(band.count, 1)
        XCTAssertEqual(band.first?.startTs, start)
        XCTAssertEqual(band.first?.endTs, end - 1)
    }

    // MARK: - DST

    func testHealthDayReadsCumulativeIntervalsAcrossLocalMidnightAndFinalFraction() async throws {
        let store = try await makeStore()
        let from = ts(2026, 11, 13, 0, in: paris)
        let end = ts(2026, 11, 14, 0, in: paris)
        let cross = HealthSample(uuid: "cross", type: "stepCount", startDate: Double(from - 600),
                                 endDate: Double(from + 600), value: 100, unit: "count",
                                 sourceName: "iPhone", sourceBundle: "app.phone", metadataOrigin: nil, importedAt: 0)
        let fraction = HealthSample(uuid: "fraction", type: "stepCount", startDate: Double(end) - 0.5,
                                    endDate: Double(end) - 0.5, value: 10, unit: "count",
                                    sourceName: "iPhone", sourceBundle: "app.phone", metadataOrigin: nil, importedAt: 0)
        try await store.upsertHealthSamples([cross, fraction])
        let engine = LocalMetricsEngine(store: store, deviceId: "band", priorityOverride: .default, timeZone: paris)
        let raw = await engine.healthDayRaw(date: "2026-11-13")
        XCTAssertEqual(raw.from, Double(from))
        XCTAssertEqual(raw.to, Double(end))
        XCTAssertEqual(Set((raw.samples[.stepCount] ?? []).map(\.uuid)), Set(["cross", "fraction"]))
        let report = HealthDayReportBuilder.build(raw: raw, snapshot: nil, bandSleep: [], bandWorkouts: [])
        let steps = try XCTUnwrap(report.row(.stepCount))
        XCTAssertFalse(steps.hasConflicts)
        XCTAssertEqual(steps.points.reduce(0) { $0 + $1.value }, 60, accuracy: 0.001)
    }

    func testDSTDaysKeepAllTheirLocalHours() async throws {
        for (y, m, d, hours) in [(2026, 3, 29, 23), (2026, 10, 25, 25)] {
            let store = try await makeStore()
            let from = ts(y, m, d, 0, in: paris)
            let to = from + hours * 3600
            try await store.insert(Streams(hr: heart(from, to, step: 60, bpm: 70)), deviceId: "band")
            let engine = LocalMetricsEngine(store: store, deviceId: "band", priorityOverride: .default, timeZone: paris)
            let day = String(format: "%04d-%02d-%02d", y, m, d)
            let result = try await engine.compute(days: 3, now: at(to - 1))
            XCTAssertEqual(result.daily.map(\.date), [day])
            let bounds = await engine.dayBounds(day, now: at(to - 1))
            XCTAssertEqual(bounds.from, from)
            XCTAssertEqual(bounds.to + 1, to)
        }
    }

    // MARK: - Full vs incremental parity near local midnight

    func testIncrementalMatchesFullForChangesAroundLocalMidnight() async throws {
        let store = try await makeStore()
        let base = ts(2026, 11, 14, 12, in: paris)
        var rows: [HRSample] = []
        for day in 0..<5 { rows += heart(base - day * 86400 - 6 * 3600, base - day * 86400, step: 30, bpm: 70 + day) }
        try await store.insert(Streams(hr: rows), deviceId: "band")
        try await store.upsertHealthSamples([watchSample("rhr", "restingHeartRate", base - 3 * 86400, base - 3 * 86400, 58)])
        let engine = LocalMetricsEngine(store: store, deviceId: "band", priorityOverride: .default,
                                        maxHeartRateOverride: 190, timeZone: paris)
        let now = at(base)
        var (previous, counts) = try await engine.computeCore(days: 5, previous: nil, previousDayCounts: nil,
                                                              forceFull: true, now: now)
        // 23:30Z on 12 Nov is 00:30 local on 13 Nov; then a move of the same sample by UUID.
        let changes: [() async throws -> Void] = [
            { try await store.insert(Streams(hr: self.heart(self.ts(2026, 11, 13, 0, 20, in: self.paris),
                                                            self.ts(2026, 11, 13, 0, 50, in: self.paris), bpm: 160)), deviceId: "band") },
            { try await store.upsertHealthSamples([self.watchSample("rhr", "restingHeartRate",
                                                                     self.ts(2026, 11, 12, 23, 50, in: self.paris),
                                                                     self.ts(2026, 11, 12, 23, 50, in: self.paris), 55)]) }
        ]
        for change in changes {
            try await change()
            let (incremental, next) = try await engine.computeCore(days: 5, previous: previous, previousDayCounts: counts,
                                                                   forceFull: false, now: now)
            let fresh = try await LocalMetricsEngine(store: store, deviceId: "band", priorityOverride: .default,
                                                     maxHeartRateOverride: 190, timeZone: paris).compute(days: 5, now: now)
            XCTAssertEqual(incremental.daily, fresh.daily)
            XCTAssertEqual(incremental.sleepSessions, fresh.sleepSessions)
            XCTAssertEqual(incremental.workoutSessions, fresh.workoutSessions)
            XCTAssertNotEqual(next, counts)
            previous = incremental; counts = next
        }
    }

    // MARK: - Travel

    func testTravelKeepsComputedDayInItsOriginalZone() async throws {
        let store = try await makeStore()
        // Evening in Paris on 12 Nov, then the 13th in New York.
        let parisEvening = ts(2026, 11, 12, 23, 30, in: paris)
        let nyMorning = ts(2026, 11, 13, 3, in: newYork)
        try await store.insert(Streams(hr: heart(parisEvening - 3600, parisEvening, step: 10, bpm: 72)
                                       + heart(nyMorning, nyMorning + 3600, step: 10, bpm: 64)), deviceId: "band")
        let parisEngine = LocalMetricsEngine(store: store, deviceId: "band", priorityOverride: .default, timeZone: paris)
        let (first, counts) = try await parisEngine.computeCore(days: 3, previous: nil, previousDayCounts: nil,
                                                                forceFull: true, now: at(parisEvening))
        XCTAssertEqual(first.dayTimeZones["2026-11-12"], "Europe/Paris")
        let parisBounds = await parisEngine.dayBounds("2026-11-12", now: at(parisEvening))

        let nyEngine = LocalMetricsEngine(store: store, deviceId: "band", priorityOverride: .default, timeZone: newYork)
        let nyNow = at(ts(2026, 11, 13, 20, in: newYork))
        let (travel, _) = try await nyEngine.computeCore(days: 3, previous: first, previousDayCounts: counts,
                                                         forceFull: false, now: nyNow)
        XCTAssertEqual(travel.dayTimeZones["2026-11-12"], "Europe/Paris")
        XCTAssertEqual(travel.dayTimeZones["2026-11-13"], "America/New_York")
        XCTAssertEqual(travel.daily.first { $0.date == "2026-11-12" }?.timeZone, "Europe/Paris")
        XCTAssertEqual(travel.daily.first { $0.date == "2026-11-13" }?.timeZone, "America/New_York")
        let kept = await nyEngine.dayBounds("2026-11-12", now: nyNow)
        XCTAssertEqual(kept.from, parisBounds.from)
        XCTAssertEqual(kept.to, parisBounds.to)
        // The travel day starts where the Paris day ended and ends at New York midnight (30 h).
        let travelDay = await nyEngine.dayBounds("2026-11-13", now: nyNow)
        XCTAssertEqual(travelDay.from, parisBounds.to + 1)
        XCTAssertEqual(travelDay.to + 1, ts(2026, 11, 14, 0, in: newYork))
        XCTAssertEqual(travelDay.to - travelDay.from + 1, 30 * 3600)
        XCTAssertEqual(Set(travel.daily.map(\.date)), ["2026-11-12", "2026-11-13"])

        // A full recompute with the persisted registry gives the same history.
        let full = try await LocalMetricsEngine(store: store, deviceId: "band", priorityOverride: .default, timeZone: newYork)
            .computeCore(days: 3, previous: first, previousDayCounts: nil, forceFull: true, now: nyNow).result
        XCTAssertEqual(full.daily, travel.daily)
        XCTAssertEqual(full.dayTimeZones, travel.dayTimeZones)
    }

    // MARK: - Sleep source in the Santé report

    func testWatchOnlyNightIsLabelledWatchAndNotComparedWithItself() async throws {
        let store = try await makeStore()
        try await store.upsertHealthSamples([
            watchSample("n1", "sleepAnalysis", ts(2026, 11, 12, 23, in: paris), ts(2026, 11, 13, 7, in: paris), 3)
        ])
        let engine = LocalMetricsEngine(store: store, deviceId: "band", priorityOverride: .default, timeZone: paris)
        let result = try await engine.compute(days: 3, now: at(ts(2026, 11, 13, 12, in: paris)))
        let snapshot = try XCTUnwrap(result.daily.first { $0.date == "2026-11-13" })
        XCTAssertEqual(try XCTUnwrap(snapshot.totalSleepMin), 480, accuracy: 0.01)
        XCTAssertEqual(HealthDayReportBuilder.retainedSleepSource(snapshot: snapshot, sessions: result.sleepSessions),
                       .appleWatch)

        let raw = await engine.healthDayRaw(date: "2026-11-13")
        let report = HealthDayReportBuilder.build(raw: raw, snapshot: snapshot, bandSleep: result.sleepSessions,
                                                  bandWorkouts: result.workoutSessions)
        let sleep = try XCTUnwrap(report.row(.sleepAnalysis))
        XCTAssertEqual(sleep.source, HealthDataSource.appleWatch.label)
        XCTAssertNil(sleep.agreement, "the Watch night must not be compared with itself as if it were the band")
        XCTAssertTrue(sleep.isSingleSource)
    }

    // MARK: - Supplemental HR exclusions

    func testSupplementalHRNeverKeepsASourceExcludedFromTheActivityOrder() {
        var priority = HealthSourcePriority.default
        priority.orders[HealthSourcePriority.key(.heartRate, .activity)] = [.appleWatch, .whoop]
        let base = Double(ts(2026, 11, 13, 10, in: paris))
        let rows = (0..<5).map { i in
            HealthSample(uuid: "phone-\(i)", type: "heartRate", startDate: base + Double(i * 60),
                         endDate: base + Double(i * 60), value: 120, unit: "count/min",
                         sourceName: "iPhone", sourceBundle: "com.apple.health", metadataOrigin: nil, importedAt: 0)
        } + [watchSample("watch", "heartRate", Int(base) + 3600, Int(base) + 3600, 130)]
        let kept = HealthEngineInputs.supplementalHR(rows, priority: priority)
        XCTAssertEqual(kept.map(\.bpm), [130], "an excluded source (iPhone) must never fill band gaps")
        XCTAssertEqual(HealthEngineInputs.supplementalHR(rows, priority: .default).count, 6)
    }

    // MARK: - Workout order and cache invalidation

    func testWorkoutOrderSettingDoesNotChangeEngineWorkoutsNorCacheKey() async throws {
        let store = try await makeStore()
        let start = ts(2026, 11, 13, 18, in: paris), end = ts(2026, 11, 13, 18, 45, in: paris)
        try await store.insert(Streams(hr: heart(ts(2026, 11, 13, 16, in: paris), start, bpm: 60)
                                       + heart(start, end, bpm: 150)
                                       + heart(end, ts(2026, 11, 13, 21, in: paris), bpm: 60)), deviceId: "band")
        try await store.upsertExternalWorkouts([ExternalWorkout(
            id: "run", source: "healthkit", sportType: 37, startDate: Double(start + 300), endDate: Double(end - 300),
            durationSec: Double(end - start - 600), energyKcal: 300, distanceM: 5000,
            sourceName: "Apple Watch", importedAt: 0)])
        var bandFirst = HealthSourcePriority.default
        bandFirst.workouts = [.whoop, .healthKit, .appleWatch]
        XCTAssertNotEqual(bandFirst, .default)
        XCTAssertEqual(healthComputeSettingsKey(bandFirst, maxHeartRate: 190, deviceId: "band"),
                       healthComputeSettingsKey(.default, maxHeartRate: 190, deviceId: "band"),
                       "the engine applies WorkoutSourcePriority.order: the setting must not invalidate the cache")

        let now = at(ts(2026, 11, 13, 22, in: paris))
        var sessions: [[WorkoutSession]] = []
        for priority in [HealthSourcePriority.default, bandFirst] {
            let engine = LocalMetricsEngine(store: store, deviceId: "band", priorityOverride: priority,
                                            maxHeartRateOverride: 190, timeZone: paris)
            let result = try await engine.computeCore(days: 3, previous: nil, previousDayCounts: nil,
                                                      forceFull: true, now: now).result
            sessions.append(result.workoutSessions)
        }
        XCTAssertFalse(sessions[0].isEmpty)
        XCTAssertEqual(sessions[0], sessions[1])
    }

    // MARK: - Migration

    func testLegacyUTCCacheIsRecomputedWithLocalZones() async throws {
        let store = try await makeStore()
        try await store.insert(Streams(hr: heart(ts(2026, 11, 13, 0, 30, in: paris), ts(2026, 11, 13, 1, 30, in: paris),
                                                 step: 10, bpm: 70)), deviceId: "band")
        let engine = LocalMetricsEngine(store: store, deviceId: "band", priorityOverride: .default, timeZone: paris)
        let now = at(ts(2026, 11, 13, 12, in: paris))
        // A v5 cache: UTC day keys, previous engine key, no zones.
        let legacy = LocalComputeResult(daily: [DailySnapshot(date: "2026-11-12", totalSleepMin: nil, efficiency: nil,
            deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil, sleepStart: nil, sleepEnd: nil, sleepScore: nil,
            restingHR: nil, avgHrv: nil, recovery: nil, recoveryStatus: "low", recoveryBand: nil, strain: 3,
            sleepTargetMin: nil, targetStrain: nil, targetStrainConfidence: nil, recentOverload: nil, adviceSignals: [])],
            sleepSessions: [], workoutSessions: [], stress: nil, hrSamples: [])
        let legacyCounts = ["2026-11-12": 1, "@engine:v5|device=band": 1]
        let migrated = try await engine.computeCore(days: 3, previous: legacy, previousDayCounts: legacyCounts,
                                                    forceFull: false, now: now).result
        XCTAssertEqual(migrated.daily.map(\.date), ["2026-11-13"])
        XCTAssertEqual(migrated.daily.first?.timeZone, "Europe/Paris")
        XCTAssertEqual(Set(migrated.dayTimeZones.values), ["Europe/Paris"])

        let json = #"{"daily":[{"date":"2026-11-12","recoveryStatus":"low","adviceSignals":[]}],"sleepSessions":[],"workoutSessions":[],"hrSamples":[]}"#
        let cache = try JSONDecoder().decode(LoopCache.self, from: Data(json.utf8))
        XCTAssertNil(cache.dayTimeZones)
        XCTAssertNil(cache.daily.first?.timeZone)
        XCTAssertEqual(cache.daily.count, 1)
    }
}
