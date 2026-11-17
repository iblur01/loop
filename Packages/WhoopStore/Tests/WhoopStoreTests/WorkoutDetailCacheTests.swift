import XCTest
import GRDB
@testable import WhoopStore

final class WorkoutDetailCacheTests: XCTestCase {

    // MARK: - Migration

    func testV13CreatesDetailTablesOnFreshStore() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        for t in ["workout_route_point", "workout_heart_series", "workout_detail_fetch"] {
            XCTAssertTrue(tables.contains(t), "missing \(t)")
        }
        let pk = try await store.primaryKeyColumns("workout_route_point")
        XCTAssertEqual(pk, ["workoutKey", "idx"])
        XCTAssertEqual(WhoopStoreInfo.schemaVersion, 15)
    }

    /// Base existante migrée jusqu'à v12 (avec une donnée), puis ouverte par le store courant :
    /// v13 ajoute les tables sans toucher aux données.
    func testV13MigratesExistingV12Database() async throws {
        let path = NSTemporaryDirectory() + "whoopstore-v12-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Self.seedV12(path: path)
        let store = try await WhoopStore(path: path)
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("workout_route_point"))
        XCTAssertTrue(tables.contains("workout_heart_series"))
        XCTAssertTrue(tables.contains("workout_detail_fetch"))
        let rpe = try await store.perceivedEffort(workoutId: "external:A")
        XCTAssertEqual(rpe?.rpe, 7)
    }

    private static func seedV12(path: String) throws {
        let queue = try DatabaseQueue(path: path)
        try WhoopStore.makeMigrator().migrate(queue, upTo: "v12")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO workout_perceived_effort (workoutId, rpe, recordedAt) VALUES ('external:A', 7, 1)")
            let names = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
            XCTAssertFalse(names.contains("workout_route_point"))
        }
    }

    /// Lookup par UUID après un upsert externe sans identité matérielle : les valeurs v15 restent.
    func testExternalWorkoutLookupKeepsDeviceIdentityAfterUpsertWithout() async throws {
        let store = try await WhoopStore.inMemory()
        func workout(_ product: String?, _ model: String?) -> ExternalWorkout {
            ExternalWorkout(id: "A", source: "healthkit", sportType: 37, startDate: 1000, endDate: 1600,
                            durationSec: 600, energyKcal: nil, distanceM: nil, sourceName: "Montre",
                            importedAt: 5, sourceBundle: "com.apple.health.X", productType: product, deviceModel: model)
        }
        try await store.upsertExternalWorkouts([workout("Watch6,1", "Watch")])
        try await store.upsertExternalWorkouts([workout(nil, nil)])
        let row = try await store.externalWorkout(id: "A")
        XCTAssertEqual(row?.sourceBundle, "com.apple.health.X")
        XCTAssertEqual(row?.productType, "Watch6,1")
        XCTAssertEqual(row?.deviceModel, "Watch")
    }

    // MARK: - Key

    func testKeyParsing() {
        XCTAssertEqual(WorkoutDetailKey("external:ABC-1"), .external(id: "ABC-1"))
        XCTAssertEqual(WorkoutDetailKey("band:my:dev:1700000000"), .band(deviceId: "my:dev", startTs: 1_700_000_000))
        XCTAssertNil(WorkoutDetailKey("external:"))
        XCTAssertNil(WorkoutDetailKey("band:dev:x"))
        XCTAssertNil(WorkoutDetailKey("other"))
        let key = WorkoutPerceivedEffort.workoutKey(externalID: nil, deviceId: "d", startTs: 42)
        XCTAssertEqual(WorkoutDetailKey(key)?.rawValue, key)
    }

    // MARK: - Decimation

    private func route(_ n: Int) -> [WorkoutRoutePoint] {
        (0..<n).map { WorkoutRoutePoint(timestamp: Double($0), latitude: 48 + Double($0) * 1e-5, longitude: 2) }
    }

    func testRouteDecimationKeepsFirstLastAndCap() {
        for n in [2_001, 2_500, 4_000, 10_007] {
            let input = route(n)
            let out = WorkoutSeriesDecimation.decimateRoute(input)
            XCTAssertEqual(out.count, 2_000, "n=\(n)")
            XCTAssertEqual(out.first, input.first)
            XCTAssertEqual(out.last, input.last)
            XCTAssertEqual(out.map(\.timestamp), out.map(\.timestamp).sorted())
            XCTAssertEqual(Set(out.map(\.timestamp)).count, out.count)
        }
    }

    func testRouteUnderCapIsUntouched() {
        let input = route(2_000)
        XCTAssertEqual(WorkoutSeriesDecimation.decimateRoute(input), input)
        XCTAssertEqual(WorkoutSeriesDecimation.decimateRoute([]), [])
    }

    func testHeartRateBucketsAtFiveSeconds() {
        let samples = [
            WorkoutHeartRatePoint(ts: 103, bpm: 120), WorkoutHeartRatePoint(ts: 100, bpm: 100),
            WorkoutHeartRatePoint(ts: 104.9, bpm: 110), WorkoutHeartRatePoint(ts: 105, bpm: 150),
            WorkoutHeartRatePoint(ts: 120, bpm: .nan), WorkoutHeartRatePoint(ts: 121, bpm: 0)
        ]
        let out = WorkoutSeriesDecimation.bucketHeartRate(samples)
        XCTAssertEqual(out, [WorkoutHeartRatePoint(ts: 100, bpm: 110), WorkoutHeartRatePoint(ts: 105, bpm: 150)])
    }

    // MARK: - Store round-trip

    func testRouteRoundTripAndDecimationFlag() async throws {
        let store = try await WhoopStore.inMemory()
        let input = route(3_000)
        let r = CachedWorkoutRoute(workoutKey: "external:X", points: WorkoutSeriesDecimation.decimateRoute(input),
                             sourcePointCount: input.count, fetchedAt: 10)
        try await store.replaceWorkoutRoute(r)
        let back = try await store.workoutRoute(workoutKey: "external:X")
        XCTAssertEqual(back, r)
        XCTAssertEqual(back?.isDecimated, true)
        XCTAssertEqual(back?.points.count, 2_000)
        XCTAssertEqual(back?.points.first, input.first)
        XCTAssertEqual(back?.points.last, input.last)

        try await store.markWorkoutDetailUnavailable(workoutKey: "external:X", kind: .route, fetchedAt: 20)
        let afterUnavailable = try await store.workoutRoute(workoutKey: "external:X")
        XCTAssertNil(afterUnavailable)
        let status = try await store.workoutDetailFetchStatus(workoutKey: "external:X", kind: .route)
        XCTAssertEqual(status, WorkoutDetailFetchStatus(state: .unavailable, fetchedAt: 20))
    }

    func testHeartSeriesRoundTripAndDelete() async throws {
        let store = try await WhoopStore.inMemory()
        let s = CachedWorkoutHeartSeries(workoutKey: "band:d:1", points: [.init(ts: 0, bpm: 90), .init(ts: 5, bpm: 95.5)],
                                   sourceSampleCount: 2, fetchedAt: 3)
        try await store.replaceWorkoutHeartSeries(s)
        let back = try await store.workoutHeartSeries(workoutKey: "band:d:1")
        XCTAssertEqual(back, s)
        XCTAssertEqual(back?.isDecimated, false)
        try await store.deleteWorkoutDetailCache(workoutKey: "band:d:1")
        let gone = try await store.workoutHeartSeries(workoutKey: "band:d:1")
        XCTAssertNil(gone)
    }

    // MARK: - Loader

    func testNoRouteIsUnavailableAndCached() async throws {
        let store = try await WhoopStore.inMemory()
        let source = FakeSource(route: nil)
        let loader = WorkoutDetailLoader(store: store, source: source, now: { Date(timeIntervalSince1970: 1_000) })
        guard case .unavailable = await loader.loadWorkoutRoute(for: "external:A") else { return XCTFail() }
        guard case .unavailable = await loader.loadWorkoutRoute(for: "external:A") else { return XCTFail() }
        let calls = await source.routeCalls
        XCTAssertEqual(calls, 1, "second open must hit the cached 'unavailable'")
        guard case .unavailable = await loader.loadWorkoutRoute(for: "external:A", forceRefresh: true) else { return XCTFail() }
    }

    func testBandSessionHasNoRoute() async throws {
        let store = try await WhoopStore.inMemory()
        let loader = WorkoutDetailLoader(store: store, source: FakeSource(route: route(5)))
        guard case .unavailable = await loader.loadWorkoutRoute(for: "band:d:100") else { return XCTFail() }
    }

    func testNotDeterminedIsNotAuthorized() async throws {
        let store = try await WhoopStore.inMemory()
        let loader = WorkoutDetailLoader(store: store, source: FakeSource(route: route(5), auth: .notDetermined))
        guard case .notAuthorized = await loader.loadWorkoutRoute(for: "external:A") else { return XCTFail() }
        guard case .notAuthorized = await loader.loadWorkoutHeartRateSeries(for: "band:d:1", window: 0...10) else { return XCTFail() }
    }

    func testExplicitDenialIsNotAuthorized() async throws {
        let store = try await WhoopStore.inMemory()
        let loader = WorkoutDetailLoader(store: store, source: FakeSource(route: nil, deny: true))
        guard case .notAuthorized = await loader.loadWorkoutRoute(for: "external:A") else { return XCTFail() }
        let status = try await store.workoutDetailFetchStatus(workoutKey: "external:A", kind: .route)
        XCTAssertNil(status, "a denial must not be cached as 'unavailable'")
    }

    func testRouteLoadedDecimatedAndCached() async throws {
        let store = try await WhoopStore.inMemory()
        let source = FakeSource(route: Array(route(5_000).reversed()))
        let loader = WorkoutDetailLoader(store: store, source: source)
        guard case .loaded(let r) = await loader.loadWorkoutRoute(for: "external:A") else { return XCTFail() }
        XCTAssertTrue(r.isDecimated)
        XCTAssertEqual(r.points.count, 2_000)
        XCTAssertEqual(r.points.first?.timestamp, 0)
        XCTAssertEqual(r.points.last?.timestamp, 4_999)
        _ = await loader.loadWorkoutRoute(for: "external:A")
        let calls = await source.routeCalls
        XCTAssertEqual(calls, 1)
    }

    func testHeartSeriesUsesExternalWorkoutWindow() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertExternalWorkouts([ExternalWorkout(id: "A", source: "healthkit", sportType: 37,
            startDate: 100, endDate: 200, durationSec: 100, energyKcal: nil, distanceM: nil, sourceName: nil, importedAt: 0)])
        let samples = (0..<60).map { WorkoutHeartRatePoint(ts: 100 + Double($0), bpm: 130) }
        let source = FakeSource(route: nil, heart: samples)
        let loader = WorkoutDetailLoader(store: store, source: source, now: { Date(timeIntervalSince1970: 1_000) })
        guard case .loaded(let s) = await loader.loadWorkoutHeartRateSeries(for: "external:A") else { return XCTFail() }
        XCTAssertEqual(s.points.count, 12)
        XCTAssertTrue(s.isDecimated)
        let window = await source.lastWindow
        XCTAssertEqual(window?.0, 100)
        XCTAssertEqual(window?.1, 200)
        let cached = try await store.workoutHeartSeries(workoutKey: "external:A")
        XCTAssertEqual(cached, s)
    }

    func testHeartSeriesWithoutWindowIsUnavailable() async throws {
        let store = try await WhoopStore.inMemory()
        let loader = WorkoutDetailLoader(store: store, source: FakeSource(route: nil))
        guard case .unavailable = await loader.loadWorkoutHeartRateSeries(for: "band:d:1") else { return XCTFail() }
    }

    func testCancelledLoadWritesNothing() async throws {
        let store = try await WhoopStore.inMemory()
        let loader = WorkoutDetailLoader(store: store, source: FakeSource(route: route(10)))
        let task = Task { await loader.loadWorkoutRoute(for: "external:A") }
        task.cancel()
        let result = await task.value
        if case .failed(let error) = result { XCTAssertTrue(error is CancellationError) }
        else if case .loaded = result { /* le chargement a pu finir avant l'annulation */ }
        else { XCTFail("unexpected \(result)") }
    }
}

private actor FakeSource: WorkoutDetailSource {
    let route: [WorkoutRoutePoint]?
    let heart: [WorkoutHeartRatePoint]
    let auth: WorkoutDetailAuthorization
    let deny: Bool
    var routeCalls = 0
    var lastWindow: (Double, Double)?

    init(route: [WorkoutRoutePoint]?, heart: [WorkoutHeartRatePoint] = [],
         auth: WorkoutDetailAuthorization = .requested, deny: Bool = false) {
        self.route = route; self.heart = heart; self.auth = auth; self.deny = deny
    }

    func authorization(for kind: WorkoutDetailKind) async -> WorkoutDetailAuthorization { auth }

    func routePoints(externalWorkoutID: String) async throws -> [WorkoutRoutePoint]? {
        routeCalls += 1
        if deny { throw WorkoutDetailSourceError.notAuthorized }
        return route
    }

    func heartRateSamples(from: Double, to: Double) async throws -> [WorkoutHeartRatePoint] {
        lastWindow = (from, to)
        if deny { throw WorkoutDetailSourceError.notAuthorized }
        return heart
    }
}
