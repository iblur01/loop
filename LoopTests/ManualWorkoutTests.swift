import XCTest
import LoopStrapEngine
import WhoopProtocol
import WhoopStore
@testable import Loop

/// Séance saisie à la main : pipeline existant (moteur, fusion, rapport), rattachement à une
/// séance enregistrée, classement de source et suppression ciblée.
@MainActor
final class ManualWorkoutTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!
    /// 2026-11-14 11:00 UTC, fixe.
    private let now = 1_794_654_000
    private var nowDate: Date { Date(timeIntervalSince1970: Double(now)) }

    private func makeStore(hrAt: Int? = nil) async throws -> WhoopStore {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "band", mac: nil, name: nil)
        try await store.insert(Streams(hr: [HRSample(ts: hrAt ?? now - 6 * 3600, bpm: 60)]), deviceId: "band")
        return store
    }

    private func watch(id: String, sport: Int, start: Double, end: Double) -> ExternalWorkout {
        ExternalWorkout(id: id, source: "healthkit", sportType: sport, startDate: start, endDate: end,
                        durationSec: end - start, energyKcal: 320, distanceM: nil,
                        sourceName: "Apple Watch de Théo", importedAt: 0,
                        sourceBundle: "com.apple.health.ABC", productType: "Watch6,1", deviceModel: "Watch")
    }

    private func report(_ sessions: [WorkoutSession], today: String = "2026-11-14") throws -> TrainingReport {
        let cache = LoopCache(daily: [], sleepSessions: [], workoutSessions: sessions, stress: nil,
                              hrSamples: [], summary: nil, updatedAt: nil)
        return try XCTUnwrap(TrainingReportBuilder.make(cache: cache, today: today, deviceZone: utc))
    }

    private func strengthSRPE(_ sessions: [WorkoutSession]) throws -> Double {
        let volumes = try report(sessions).stats.weeklyVolumes.filter { $0.sport == .strength }
        return volumes.compactMap(\.srpeLoadSum).reduce(0, +)
    }

    private func draft(_ sport: ManualWorkoutSport, start: Double, minutes: Int, rpe: Int = 7) -> ManualWorkoutDraft {
        var d = ManualWorkoutDraft(start: Date(timeIntervalSince1970: start))
        d.sport = sport
        d.durationMinutes = minutes
        d.rpe = rpe
        d.note = "salle"
        return d
    }

    // MARK: - Rapport d'entraînement

    func testManualStrengthWorkoutEntersTrainingReportWithSRPELoad() async throws {
        let store = try await makeStore()
        let start = Date(timeIntervalSince1970: Double(now - 3 * 3600))
        let saved = try await ManualWorkoutStore(store: store).save(sport: .strength, start: start, durationMinutes: 45,
                                                                    rpe: 7, note: "jambes", now: nowDate)
        let engine = LocalMetricsEngine(store: store, deviceId: "band", timeZone: utc)
        let result = try await engine.compute(days: 2, now: nowDate)

        let session = try XCTUnwrap(result.workoutSessions.first { $0.externalID == saved.id })
        XCTAssertEqual(session.sportType, 50)
        XCTAssertEqual(session.durationS, 45 * 60)
        XCTAssertEqual(session.perceivedEffort, 7)
        XCTAssertEqual(session.rpeLoad, 315)
        XCTAssertEqual(TrainingInputsAdapter.sport(kind: session.kind, sportType: session.sportType), .strength)
        XCTAssertEqual(try strengthSRPE(result.workoutSessions), 315)
    }

    func testLateEveningWorkoutCrossingMidnightBelongsToItsStartDay() async throws {
        let start = 1_794_612_600 // 2026-11-13 23:30 UTC
        let store = try await makeStore(hrAt: start - 3600)
        let saved = try await ManualWorkoutStore(store: store).save(
            sport: .run, start: Date(timeIntervalSince1970: Double(start)), durationMinutes: 60, rpe: 6, now: nowDate)
        let engine = LocalMetricsEngine(store: store, deviceId: "band", timeZone: utc)
        let result = try await engine.compute(days: 3, now: nowDate)
        let sessions = result.workoutSessions.filter { $0.externalID == saved.id }
        XCTAssertEqual(sessions.count, 1, "compté une seule fois malgré minuit")
        let cache = LoopCache(daily: [], sleepSessions: [], workoutSessions: sessions, stress: nil,
                              hrSamples: [], summary: nil, updatedAt: nil)
        XCTAssertEqual(TrainingReportBuilder.localDay(of: sessions[0], cache: cache, deviceZone: utc), "2026-11-13")
    }

    // MARK: - Fusion et rattachement

    func testManualOverlappingWatchOfSameSportIsMerged() {
        let t = Double(now - 4 * 3600)
        let w = watch(id: "W1", sport: 50, start: t, end: t + 50 * 60)
        let m = ManualWorkout.make(id: "M1", sport: .strength, start: Date(timeIntervalSince1970: t + 5 * 60),
                                   durationMinutes: 45, now: nowDate)!
        let merged = HealthWorkoutCanonicalizer.merge(band: [], external: [w, m])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.externalID, "W1", "la montre reste primaire")

        // Témoin : même créneau, autre sport -> deux séances distinctes.
        let run = ManualWorkout.make(id: "M2", sport: .run, start: Date(timeIntervalSince1970: t + 5 * 60),
                                     durationMinutes: 45, now: nowDate)!
        XCTAssertEqual(HealthWorkoutCanonicalizer.merge(band: [], external: [w, run]).count, 2)
    }

    func testEntryAbsorbedByWatchWritesEffortOnWatchWithoutOrphanRow() async throws {
        let store = try await makeStore()
        let t = Double(now - 4 * 3600)
        try await store.upsertExternalWorkouts([watch(id: "W1", sport: 50, start: t, end: t + 50 * 60)])
        let engine = LocalMetricsEngine(store: store, deviceId: "band", timeZone: utc)
        let before = try await engine.compute(days: 2, now: nowDate).workoutSessions
        let entry = draft(.strength, start: t + 5 * 60, minutes: 45)
        guard case .attachEffort(let target, .merge) = entry.plan(existing: before) else {
            return XCTFail("la montre doit absorber la saisie")
        }
        XCTAssertEqual(target.externalID, "W1")

        let repo = LoopDataRepository()
        repo.attach(engine: engine)
        let outcome = try await repo.saveManualEntry(entry, existing: before, now: nowDate)
        XCTAssertEqual(outcome, .attachedEffort(sessionID: target.id))
        let rows = try await store.externalWorkouts(from: 0, to: .greatestFiniteMagnitude)
        XCTAssertEqual(rows.map(\.id), ["W1"], "aucune ligne manuelle orpheline")

        let after = try await engine.compute(days: 2, now: nowDate).workoutSessions
        let session = try XCTUnwrap(after.first { $0.externalID == "W1" })
        XCTAssertEqual(session.perceivedEffort, 7)
        let effort = try await store.perceivedEffort(workoutId: "external:W1")
        XCTAssertEqual(effort?.note, "salle")
        XCTAssertEqual(try strengthSRPE(after), 7 * 50)
    }

    func testPartialOverlapBelowMergeThresholdIsNotCountedTwice() async throws {
        let store = try await makeStore()
        let t = Double(now - 5 * 3600)
        let w = watch(id: "W1", sport: 50, start: t, end: t + 60 * 60)
        try await store.upsertExternalWorkouts([w])
        // 60 min à partir de t+36 : recouvrement 24 min = 40 % de chacune, sous la règle 50 %/70 %.
        let entry = draft(.strength, start: t + 36 * 60, minutes: 60)
        let asRow = ManualWorkout.make(id: "M1", sport: .strength, start: entry.start, durationMinutes: 60, now: nowDate)!
        XCTAssertEqual(HealthWorkoutCanonicalizer.merge(band: [], external: [w, asRow]).count, 2,
                       "la règle de fusion, inchangée, ne les fusionne pas")

        let engine = LocalMetricsEngine(store: store, deviceId: "band", timeZone: utc)
        let before = try await engine.compute(days: 2, now: nowDate).workoutSessions
        guard case .attachEffort(let target, .overlap) = entry.plan(existing: before) else {
            return XCTFail("recouvrement partiel compatible : rattachement attendu")
        }
        XCTAssertEqual(target.externalID, "W1")
        let repo = LoopDataRepository()
        repo.attach(engine: engine)
        _ = try await repo.saveManualEntry(entry, existing: before, now: nowDate)
        let count = try await store.externalWorkoutCount()
        XCTAssertEqual(count, 1)
        let after = try await engine.compute(days: 2, now: nowDate).workoutSessions
        XCTAssertEqual(after.compactMap(\.externalID), ["W1"])
        XCTAssertEqual(try strengthSRPE(after), 7 * 60, "une seule charge sRPE, pas deux")

        // Témoin : sport incompatible -> nouvelle séance.
        XCTAssertEqual(draft(.run, start: t + 36 * 60, minutes: 60).plan(existing: before), .create)
    }

    func testFewMinutesOfOverlapCreatesANewWorkout() {
        let t = Double(now - 5 * 3600)
        let cached = HealthWorkoutCanonicalizer.merge(band: [], external: [watch(id: "W1", sport: 50, start: t, end: t + 60 * 60)])
        // 30 min à partir de t+55 : 5 min recouvertes (17 % de la saisie).
        XCTAssertEqual(draft(.strength, start: t + 55 * 60, minutes: 30).plan(existing: cached), .create)
        // Témoin : 15 min recouvertes sur 30 (50 %) -> rattachement.
        XCTAssertEqual(draft(.strength, start: t + 45 * 60, minutes: 30).plan(existing: cached),
                       .attachEffort(to: cached[0], reason: .overlap))
    }

    func testShortFalseStartNextToManualEntryKeepsItsEffort() async throws {
        let store = try await makeStore()
        let t = Double(now - 5 * 3600)
        try await ManualWorkoutStore(store: store).save(sport: .strength, start: Date(timeIntervalSince1970: t),
                                                        durationMinutes: 45, rpe: 7, note: "A", id: "M1", now: nowDate)
        let engine = LocalMetricsEngine(store: store, deviceId: "band", timeZone: utc)
        let before = try await engine.compute(days: 2, now: nowDate).workoutSessions
        XCTAssertEqual(before.compactMap(\.externalID), ["M1"])
        // 5 min collées à la fin (faux départ) puis 5 min à l'intérieur : jamais de rattachement.
        let adjacent = draft(.strength, start: t + 45 * 60, minutes: 5, rpe: 2)
        XCTAssertEqual(adjacent.plan(existing: before), .create)
        XCTAssertEqual(draft(.strength, start: t + 10 * 60, minutes: 5, rpe: 2).plan(existing: before), .create)

        let repo = LoopDataRepository()
        repo.attach(engine: engine)
        let outcome = try await repo.saveManualEntry(adjacent, existing: before, now: nowDate)
        guard case .created = outcome else { return XCTFail("nouvelle saisie attendue") }
        let effort = try await store.perceivedEffort(workoutId: "external:M1")
        XCTAssertEqual(effort?.rpe, 7)
        XCTAssertEqual(effort?.note, "A")
    }

    func testAttachReplacesEffortAndNoteOnTargetOnly() async throws {
        let store = try await makeStore()
        let t = Double(now - 6 * 3600)
        try await store.upsertExternalWorkouts([watch(id: "W1", sport: 50, start: t, end: t + 50 * 60),
                                                watch(id: "W2", sport: 50, start: t + 3 * 3600, end: t + 4 * 3600)])
        try await store.upsertPerceivedEffort(WorkoutPerceivedEffort(workoutId: "external:W1", rpe: 4, recordedAt: 0, note: "ancien")!)
        try await store.upsertPerceivedEffort(WorkoutPerceivedEffort(workoutId: "external:W2", rpe: 6, recordedAt: 0, note: "garder")!)
        let engine = LocalMetricsEngine(store: store, deviceId: "band", timeZone: utc)
        let before = try await engine.compute(days: 2, now: nowDate).workoutSessions
        let repo = LoopDataRepository()
        repo.attach(engine: engine)
        let entry = draft(.strength, start: t + 5 * 60, minutes: 45, rpe: 8)
        let outcome = try await repo.saveManualEntry(entry, existing: before, now: nowDate)
        XCTAssertEqual(outcome, .attachedEffort(sessionID: try XCTUnwrap(before.first { $0.externalID == "W1" }).id))
        let w1 = try await store.perceivedEffort(workoutId: "external:W1")
        XCTAssertEqual(w1?.rpe, 8)
        XCTAssertEqual(w1?.note, "salle")
        let w2 = try await store.perceivedEffort(workoutId: "external:W2")
        XCTAssertEqual(w2?.rpe, 6)
        XCTAssertEqual(w2?.note, "garder")
        let count = try await store.externalWorkoutCount()
        XCTAssertEqual(count, 2)
    }

    func testTwoOverlappingManualEntriesStayDistinct() {
        let t = Double(now - 4 * 3600)
        let a = ManualWorkout.make(id: "A", sport: .strength, start: Date(timeIntervalSince1970: t),
                                   durationMinutes: 45, now: nowDate)!
        let b = ManualWorkout.make(id: "B", sport: .strength, start: Date(timeIntervalSince1970: t + 5 * 60),
                                   durationMinutes: 40, now: nowDate)!
        let merged = HealthWorkoutCanonicalizer.merge(band: [], external: [a, b])
        XCTAssertEqual(merged.compactMap(\.externalID).sorted(), ["A", "B"])
        // La feuille crée aussi une nouvelle saisie face à une saisie manuelle existante.
        let existing = HealthWorkoutCanonicalizer.merge(band: [], external: [a])
        XCTAssertEqual(draft(.strength, start: t + 5 * 60, minutes: 40).plan(existing: existing), .create)
    }

    func testManualAbsorbsOverlappingBandDetection() {
        let t = now - 4 * 3600
        let band = WorkoutSession(deviceId: "band", startTs: t, endTs: t + 40 * 60, avgHr: 130, peakHr: 160,
                                  strain: 6, kind: nil, durationS: 40 * 60, caloriesKcal: nil)
        let m = ManualWorkout.make(id: "M1", sport: .strength, start: Date(timeIntervalSince1970: Double(t)),
                                   durationMinutes: 45, now: nowDate)!
        XCTAssertEqual(HealthWorkoutCanonicalizer.merge(band: [band], external: [m]).map(\.externalID), ["M1"])
        XCTAssertEqual(draft(.strength, start: Double(t), minutes: 45).plan(existing: [band]), .create)
    }

    // MARK: - Classement

    func testManualWorkoutIsNeverAppleWatchNorBand() {
        let m = ManualWorkout.make(id: "M1", sport: .run, start: Date(timeIntervalSince1970: 0), durationMinutes: 30)!
        XCTAssertEqual(HealthDataSource.classify(m), .healthKit)
        XCTAssertEqual(WorkoutSourcePriority.classify(m), .otherHealth)
        // Même avec un nom ou une identité matérielle de montre, l'origine manuelle prime.
        let disguised = ExternalWorkout(id: "M2", source: ManualWorkout.source, sportType: 37, startDate: 0, endDate: 1800,
                                        durationSec: 1800, energyKcal: nil, distanceM: nil,
                                        sourceName: "Apple Watch", importedAt: 0,
                                        sourceBundle: ManualWorkout.sourceBundle, productType: "Watch6,1",
                                        deviceModel: "Watch")
        XCTAssertEqual(HealthDataSource.classify(disguised), .healthKit)
        XCTAssertEqual(WorkoutSourcePriority.classify(disguised), .otherHealth)
        XCTAssertEqual(HealthSourceActivity(disguised).source, .healthKit)
        // Témoin : la même ligne sans marque manuelle est bien une Apple Watch.
        let watchRow = ExternalWorkout(id: "W", source: "healthkit", sportType: 37, startDate: 0, endDate: 1800,
                                       durationSec: 1800, energyKcal: nil, distanceM: nil, sourceName: "Apple Watch",
                                       importedAt: 0, sourceBundle: "com.apple.health", productType: "Watch6,1",
                                       deviceModel: "Watch")
        XCTAssertEqual(WorkoutSourcePriority.classify(watchRow), .appleWatch)
    }

    // MARK: - Suppression

    func testDeletingManualWorkoutKeepsEveryOtherWorkout() async throws {
        let store = try await makeStore()
        let t = Double(now - 7 * 3600)
        try await store.upsertExternalWorkouts([watch(id: "W1", sport: 37, start: t, end: t + 1800)])
        let manual = ManualWorkoutStore(store: store)
        try await manual.save(sport: .strength, start: Date(timeIntervalSince1970: t + 2 * 3600),
                              durationMinutes: 45, rpe: 7, id: "M1", now: nowDate)
        try await manual.save(sport: .swim, start: Date(timeIntervalSince1970: t + 4 * 3600),
                              durationMinutes: 30, rpe: 5, id: "M2", now: nowDate)
        let engine = LocalMetricsEngine(store: store, deviceId: "band", timeZone: utc)
        let before = try await engine.compute(days: 2, now: nowDate).workoutSessions.compactMap(\.externalID).sorted()
        XCTAssertEqual(before, ["M1", "M2", "W1"])

        let repo = LoopDataRepository()
        repo.attach(engine: engine)
        let refused = try await repo.deleteManualWorkout(externalID: "W1")
        XCTAssertFalse(refused, "une séance importée n'est jamais supprimable")
        let watchIsManual = await repo.isManualWorkout(externalID: "W1")
        XCTAssertFalse(watchIsManual)

        let deleted = try await manual.delete(id: "M1")
        XCTAssertTrue(deleted)
        let after = try await engine.compute(days: 2, now: nowDate).workoutSessions.compactMap(\.externalID).sorted()
        XCTAssertEqual(after, ["M2", "W1"])
        let m2Effort = try await store.perceivedEffort(workoutId: "external:M2")
        XCTAssertEqual(m2Effort?.rpe, 5)
    }

    #if canImport(UIKit)
    /// Chemin de succès du dépôt : cache mis à jour tout de suite, puis recalcul déclenché.
    func testRepositoryDeleteUpdatesCacheAndTriggersRecompute() async throws {
        let realNow = Int(Date().timeIntervalSince1970)
        let store = try await makeStore(hrAt: realNow - 8 * 3600)
        let t = Double(realNow - 6 * 3600)
        try await store.upsertExternalWorkouts([watch(id: "W1", sport: 37, start: t, end: t + 1800)])
        let manual = ManualWorkoutStore(store: store)
        try await manual.save(sport: .strength, start: Date(timeIntervalSince1970: t + 2 * 3600),
                              durationMinutes: 45, rpe: 7, id: "M1")
        let engine = LocalMetricsEngine(store: store, deviceId: "band")
        let repo = LoopDataRepository()
        repo.attach(engine: engine)
        await repo.refresh(force: true)
        XCTAssertTrue(repo.cache.workoutSessions.contains { $0.externalID == "M1" })
        let manualIsManual = await repo.isManualWorkout(externalID: "M1")
        XCTAssertTrue(manualIsManual)

        let deleted = try await repo.deleteManualWorkout(externalID: "M1")
        XCTAssertTrue(deleted)
        XCTAssertFalse(repo.cache.workoutSessions.contains { $0.externalID == "M1" }, "retirée immédiatement")
        XCTAssertTrue(repo.cache.workoutSessions.contains { $0.externalID == "W1" })

        // Le test n'appelle pas refresh : seule la relance du dépôt peut enregistrer la nouvelle révision.
        let revision = try await engine.inputRevision()
        let key = "@inputRevision:\(revision.instance)"
        let deadline = Date().addingTimeInterval(60)
        while (repo.cache.dayCounts?[key] != revision.revision || repo.isRefreshing) && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(repo.cache.dayCounts?[key], revision.revision, "un recalcul a suivi la suppression")
        XCTAssertFalse(repo.cache.workoutSessions.contains { $0.externalID == "M1" })
        XCTAssertTrue(repo.cache.workoutSessions.contains { $0.externalID == "W1" })
    }
    #endif

    // MARK: - Feuille

    func testDraftDefaultsAndValidation() {
        let n = Date(timeIntervalSince1970: Double(now) + 7 * 60 + 13)
        let today = LocalDay.key(n.timeIntervalSince1970, in: utc)
        let start = ManualWorkoutDraft.defaultStart(day: today, now: n, zone: utc)
        XCTAssertEqual(start.timeIntervalSince1970, Double(now) + 5 * 60 - 60 * 60)
        var d = ManualWorkoutDraft(start: start)
        XCTAssertLessThanOrEqual(d.end, n, "la séance par défaut est terminée")
        XCTAssertTrue(d.isValid(now: n))

        let yesterday = LocalDay.adding(-1, to: today)
        XCTAssertEqual(ManualWorkoutDraft.defaultStart(day: yesterday, now: n, zone: utc).timeIntervalSince1970,
                       Double(now) + 5 * 60 - 60 * 60 - 86_400)

        d.durationMinutes = 4
        XCTAssertEqual(d.validationError(now: n), .invalidDuration)
        d.durationMinutes = 42
        XCTAssertEqual(d.validationError(now: n), .invalidDuration)
        d.durationMinutes = 301
        XCTAssertEqual(d.validationError(now: n), .invalidDuration)
        d.durationMinutes = 90
        XCTAssertEqual(d.validationError(now: n), .endsInFuture)
        d.start = n.addingTimeInterval(60)
        d.durationMinutes = 5
        XCTAssertEqual(d.validationError(now: n), .endsInFuture)
    }
}
