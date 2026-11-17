import XCTest
@testable import WhoopStore

final class ManualWorkoutStoreTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_794_650_000)

    func testSaveThenReadBack() async throws {
        let ws = try await WhoopStore.inMemory()
        let store = ManualWorkoutStore(store: ws)
        let saved = try await store.save(sport: .strength, start: start, durationMinutes: 45, rpe: 7,
                                         note: " jambes ", id: "M1", now: Date(timeIntervalSince1970: 1_794_660_000))
        let fetched = try await store.get(id: "M1")
        let got = try XCTUnwrap(fetched)
        XCTAssertEqual(got, saved)
        XCTAssertEqual(got.source, ManualWorkout.source)
        XCTAssertEqual(got.sourceName, "Saisie manuelle")
        XCTAssertEqual(got.sourceBundle, "com.iblur01.loop.manual")
        XCTAssertEqual(got.sportType, 50)
        XCTAssertEqual(got.startDate, start.timeIntervalSince1970)
        XCTAssertEqual(got.endDate - got.startDate, 45 * 60)
        XCTAssertEqual(got.durationSec, 45 * 60)
        XCTAssertNil(got.energyKcal)
        XCTAssertNil(got.distanceM)
        XCTAssertNil(got.productType)
        XCTAssertNil(got.deviceModel)
        // Visible par la lecture du moteur (recouvrement) et RPE sous la clé partagée.
        let overlapping = try await ws.externalWorkouts(overlapping: start.timeIntervalSince1970,
                                                        to: start.timeIntervalSince1970 + 60)
        XCTAssertEqual(overlapping.map(\.id), ["M1"])
        let effort = try await ws.perceivedEffort(workoutId: "external:M1")
        XCTAssertEqual(effort?.rpe, 7)
        XCTAssertEqual(effort?.note, "jambes")
        XCTAssertTrue(ManualWorkout.isManual(got))
        let isManual = await store.isManual(id: "M1")
        XCTAssertTrue(isManual)
    }

    func testSportCodesAreHealthKitCodes() {
        XCTAssertEqual(ManualWorkoutSport.allCases.map(\.rawValue), [37, 46, 50, 3000])
    }

    func testInvalidDurationAndRPEAreRejectedWithoutWriting() async throws {
        let ws = try await WhoopStore.inMemory()
        let store = ManualWorkoutStore(store: ws)
        for minutes in [0, 4, 7, 301, 302] {
            do { try await store.save(sport: .run, start: start, durationMinutes: minutes, rpe: 5); XCTFail("\(minutes)") }
            catch { XCTAssertEqual(error as? ManualWorkoutStore.StoreError, .invalidDuration) }
        }
        do { try await store.save(sport: .run, start: start, durationMinutes: 30, rpe: 11); XCTFail() }
        catch { XCTAssertEqual(error as? ManualWorkoutStore.StoreError, .invalidRPE) }
        let count = try await ws.externalWorkoutCount()
        XCTAssertEqual(count, 0)
        XCTAssertNotNil(ManualWorkout.make(sport: .run, start: start, durationMinutes: 5))
        XCTAssertNotNil(ManualWorkout.make(sport: .run, start: start, durationMinutes: 300))
        XCTAssertNil(ManualWorkout.make(sport: .run, start: start, durationMinutes: 42))
    }

    func testWorkoutEndingInTheFutureIsRejected() async throws {
        let ws = try await WhoopStore.inMemory()
        let store = ManualWorkoutStore(store: ws)
        let now = Date(timeIntervalSince1970: 1_794_654_000)
        // Fin = maintenant + 5 min : refusée ; fin = maintenant (ou dans la tolérance de 60 s) : acceptée.
        let late = now.addingTimeInterval(-25 * 60)
        do { try await store.save(sport: .run, start: late, durationMinutes: 30, rpe: 5, now: now); XCTFail() }
        catch { XCTAssertEqual(error as? ManualWorkoutStore.StoreError, .endsInFuture) }
        // Début dans le futur : refusé aussi.
        do { try await store.save(sport: .run, start: now.addingTimeInterval(120), durationMinutes: 5, rpe: 5, now: now); XCTFail() }
        catch { XCTAssertEqual(error as? ManualWorkoutStore.StoreError, .endsInFuture) }
        let count = try await ws.externalWorkoutCount()
        XCTAssertEqual(count, 0)
        XCTAssertNil(ManualWorkout.make(sport: .run, start: late, durationMinutes: 30, now: now))
        XCTAssertNotNil(ManualWorkout.make(sport: .run, start: now.addingTimeInterval(-30 * 60 + 59), durationMinutes: 30, now: now))
        try await store.save(sport: .run, start: now.addingTimeInterval(-30 * 60), durationMinutes: 30, rpe: 5, now: now)
        let saved = try await ws.externalWorkoutCount()
        XCTAssertEqual(saved, 1)
    }

    func testManualSaveNeverOverwritesAnImportedRowAndIsAtomic() async throws {
        let ws = try await WhoopStore.inMemory()
        let t = start.timeIntervalSince1970
        let watch = ExternalWorkout(id: "W1", source: "healthkit", sportType: 50, startDate: t, endDate: t + 2700,
                                    durationSec: 2700, energyKcal: 300, distanceM: nil, sourceName: "Apple Watch",
                                    importedAt: 0, sourceBundle: "com.apple.health.123", productType: "Watch6,1")
        try await ws.upsertExternalWorkouts([watch])
        try await ws.upsertPerceivedEffort(WorkoutPerceivedEffort(workoutId: "external:W1", rpe: 6, recordedAt: 1)!)
        let store = ManualWorkoutStore(store: ws)
        do {
            try await store.save(sport: .run, start: start, durationMinutes: 30, rpe: 9, note: "écrase ?", id: "W1")
            XCTFail("un id existant doit faire échouer la saisie")
        } catch {}
        // Rien n'a été écrit : ni la séance, ni le RPE écrit avant elle dans la transaction.
        let kept = try await ws.externalWorkout(id: "W1")
        XCTAssertEqual(kept, watch)
        let effort = try await ws.perceivedEffort(workoutId: "external:W1")
        XCTAssertEqual(effort?.rpe, 6)
        XCTAssertNil(effort?.note)
        let count = try await ws.externalWorkoutCount()
        XCTAssertEqual(count, 1)
    }

    func testDeleteRemovesOnlyTheManualWorkout() async throws {
        let ws = try await WhoopStore.inMemory()
        let store = ManualWorkoutStore(store: ws)
        let t = start.timeIntervalSince1970
        let watch = ExternalWorkout(id: "W1", source: "healthkit", sportType: 50, startDate: t, endDate: t + 2700,
                                    durationSec: 2700, energyKcal: 300, distanceM: nil, sourceName: "Apple Watch de Théo",
                                    importedAt: 0, sourceBundle: "com.apple.health.123", productType: "Watch6,1")
        try await ws.upsertExternalWorkouts([watch])
        try await ws.upsertPerceivedEffort(WorkoutPerceivedEffort(workoutId: "external:W1", rpe: 6, recordedAt: 0)!)
        try await store.save(sport: .strength, start: start, durationMinutes: 45, rpe: 7, id: "M1")
        try await store.save(sport: .run, start: start.addingTimeInterval(86_400), durationMinutes: 30, rpe: 4, id: "M2")

        // Une séance importée n'est jamais supprimable par ce chemin.
        let refused = try await store.delete(id: "W1")
        XCTAssertFalse(refused)
        let isManual = await store.isManual(id: "W1")
        XCTAssertFalse(isManual)

        let deleted = try await store.delete(id: "M1")
        XCTAssertTrue(deleted)
        let m1 = try await store.get(id: "M1")
        XCTAssertNil(m1)
        let m1Effort = try await ws.perceivedEffort(workoutId: "external:M1")
        XCTAssertNil(m1Effort)
        let remaining = try await ws.externalWorkouts(from: 0, to: .greatestFiniteMagnitude).map(\.id).sorted()
        XCTAssertEqual(remaining, ["M2", "W1"])
        let w1Effort = try await ws.perceivedEffort(workoutId: "external:W1")
        XCTAssertEqual(w1Effort?.rpe, 6)
        let m2Effort = try await ws.perceivedEffort(workoutId: "external:M2")
        XCTAssertEqual(m2Effort?.rpe, 4)
        let again = try await store.delete(id: "M1")
        XCTAssertFalse(again)
    }

    func testSaveRejectsNonManualRow() async throws {
        let ws = try await WhoopStore.inMemory()
        let w = ExternalWorkout(id: "X", source: "healthkit", sportType: 37, startDate: 0, endDate: 600,
                                durationSec: 600, energyKcal: nil, distanceM: nil, sourceName: "Strava", importedAt: 0)
        do { try await ws.saveManualWorkout(w, effort: nil); XCTFail() }
        catch { XCTAssertEqual(error as? ManualWorkoutStore.StoreError, .notManual) }
    }
}
