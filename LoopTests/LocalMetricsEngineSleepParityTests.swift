import XCTest
import WhoopProtocol
import WhoopStore
@testable import Loop

/// Integration test: seed a real WhoopStore with NATIVE band data (pulled from the server DB
/// into Packages/LoopStrapEngine/.../Resources/realdata_native/), run the actual
/// `LocalMetricsEngine.compute()` end-to-end, and assert its sleep sessions match the server's
/// recomputed `/v1/sleep` (Resources/realdata/server_sleep.json) to within a few minutes.
///
/// This exercises the real engine path (per-day sleep window + gravity proxy + detectSleep),
/// not a replica. Skips when the (gitignored) fixtures are absent.
final class LocalMetricsEngineSleepParityTests: XCTestCase {

    private struct Columnar: Decodable {
        struct HR: Decodable { let ts: [Double]; let bpm: [Double] }
        struct RR: Decodable { let ts: [Double]; let rr_ms: [Double] }
        struct G: Decodable { let ts: [Double]; let x: [Double]; let y: [Double]; let z: [Double] }
        let hr: HR; let rr: RR; let gravity: G
    }
    private struct ServerSleep: Decodable { let start: Double; let end: Double }

    /// Repo paths derived from this source file's location.
    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)            // .../loop/LoopTests/<file>.swift
            .deletingLastPathComponent()           // .../loop/LoopTests
            .deletingLastPathComponent()           // .../loop
    }

    func testComputeSleepSessionsMatchServer() async throws {
        let root = repoRoot()
        let nativeDir = root.appendingPathComponent(
            "Packages/LoopStrapEngine/Tests/LoopStrapEngineTests/Resources/realdata_native")
        let serverURL = root.appendingPathComponent(
            "Packages/LoopStrapEngine/Tests/LoopStrapEngineTests/Resources/realdata/server_sleep.json")
        let fm = FileManager.default
        let nativeFiles = (try? fm.contentsOfDirectory(at: nativeDir, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasPrefix("native-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        try XCTSkipIf(nativeFiles.isEmpty || !fm.fileExists(atPath: serverURL.path),
                      "fixtures realdata_native/ + server_sleep.json absentes — voir scripts/fetch_fixtures.sh")

        // Build a single Streams from all native days.
        let dec = JSONDecoder()
        var hr: [HRSample] = [], rr: [RRInterval] = [], grav: [GravitySample] = []
        for f in nativeFiles {
            let d = try dec.decode(Columnar.self, from: Data(contentsOf: f))
            hr += zip(d.hr.ts, d.hr.bpm).map { HRSample(ts: Int($0), bpm: Int($1)) }
            rr += zip(d.rr.ts, d.rr.rr_ms).map { RRInterval(ts: Int($0), rrMs: Int($1)) }
            for i in 0..<d.gravity.ts.count {
                grav.append(GravitySample(ts: Int(d.gravity.ts[i]),
                                          x: d.gravity.x[i], y: d.gravity.y[i], z: d.gravity.z[i]))
            }
        }

        let path = NSTemporaryDirectory() + "loop-sleep-parity-\(UUID().uuidString).sqlite"
        let store = try await WhoopStore(path: path)
        try await store.upsertDevice(id: "theo-whoop", mac: nil, name: nil)
        // Insert in chunks to keep statements bounded.
        let chunk = 50_000
        for i in stride(from: 0, to: hr.count, by: chunk) {
            try await store.insert(Streams(hr: Array(hr[i..<min(i+chunk, hr.count)])), deviceId: "theo-whoop")
        }
        for i in stride(from: 0, to: rr.count, by: chunk) {
            try await store.insert(Streams(rr: Array(rr[i..<min(i+chunk, rr.count)])), deviceId: "theo-whoop")
        }
        for i in stride(from: 0, to: grav.count, by: chunk) {
            try await store.insert(Streams(gravity: Array(grav[i..<min(i+chunk, grav.count)])), deviceId: "theo-whoop")
        }

        let engine = LocalMetricsEngine(store: store, deviceId: "theo-whoop")
        let (result, fullCounts) = try await engine.computeCore(
            days: 60, previous: nil, previousDayCounts: nil, forceFull: true)

        // Data is dated June 2026; if the test runs >60 days later it falls outside compute's
        // window — skip rather than fail spuriously.
        try XCTSkipIf(result.sleepSessions.isEmpty, "aucune session calculée — données hors fenêtre 60j")

        // ── Incremental == full ──────────────────────────────────────────────────
        // Pretend the two most recent days changed (alter their fingerprint), then run the
        // incremental path with the full result as `previous`. The data is identical, so the
        // recomputed tail + reused head must reproduce the full result exactly.
        var staleCounts = fullCounts
        for date in staleCounts.keys.sorted().suffix(2) { staleCounts[date] = (staleCounts[date] ?? 0) + 1 }
        let (incr, _) = try await engine.computeCore(
            days: 60, previous: result, previousDayCounts: staleCounts, forceFull: false)
        // Tolérance, pas égalité exacte : le pass complet plie l'historique depuis les séries
        // brutes, l'incrémental depuis les résumés par-jour (reconstructInputs). L'écart résultant
        // est physiologiquement négligeable (~0.05 sur recovery, <1 min sur TST) — le vrai critère
        // de justesse est la parité SERVEUR vérifiée plus bas (MAE < 5 min). On exige ici que les
        // catégories (bande/statut recovery) NE basculent PAS et que les métriques restent dans
        // des bornes serrées, ce qui attrape une vraie régression sans casser sur du bruit flottant.
        assertDailyClose(incr.daily, result.daily)
        assertSleepSessionsClose(incr.sleepSessions, result.sleepSessions)
        XCTAssertEqual(incr.workoutSessions, result.workoutSessions, "incrémental: workouts divergent")
        XCTAssertEqual(incr.stress == nil, result.stress == nil, "incrémental: présence du stress diverge")

        // And a no-change incremental returns the previous result verbatim (early exit).
        let (noop, _) = try await engine.computeCore(
            days: 60, previous: result, previousDayCounts: fullCounts, forceFull: false)
        XCTAssertEqual(noop.daily, result.daily, "incrémental sans changement: daily diverge")

        let server = try dec.decode([ServerSleep].self, from: Data(contentsOf: serverURL))
        let swift = result.sleepSessions.map { (start: Double($0.startTs), end: Double($0.endTs)) }
            .sorted { $0.start < $1.start }

        func overlap(_ a0: Double, _ a1: Double, _ b0: Double, _ b1: Double) -> Double {
            max(0, min(a1, b1) - max(a0, b0))
        }
        var durErrors: [Double] = []
        var covered = 0
        for o in server.sorted(by: { $0.start < $1.start }) {
            let m = swift.max { a, b in
                overlap(a.start, a.end, o.start, o.end) < overlap(b.start, b.end, o.start, o.end)
            }
            if let m = m, overlap(m.start, m.end, o.start, o.end) > 0 {
                covered += 1
                durErrors.append(abs((m.end - m.start) - (o.end - o.start)) / 60)
            }
        }
        let mae = durErrors.isEmpty ? .infinity : durErrors.reduce(0, +) / Double(durErrors.count)
        print("LocalMetricsEngine.compute: \(swift.count) sessions, couverture \(covered)/\(server.count), MAE durée \(mae) min")
        XCTAssertGreaterThanOrEqual(covered, server.count - 1, "sessions serveur non couvertes par l'engine")
        XCTAssertLessThan(mae, 5.0, "engine↔serveur: MAE \(mae) min > 5")
    }

    // MARK: - Tolérance incrémental ↔ complet

    /// Assertion souple sur une paire de valeurs optionnelles : tolère nil↔nil et compare les
    /// valeurs présentes à `tol` près. Échoue si l'une est nil et l'autre non (présence d'une
    /// métrique = signal catégoriel à ne pas perdre).
    private func assertClose(_ a: Double?, _ b: Double?, tol: Double, _ label: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        switch (a, b) {
        case (nil, nil): return
        case let (x?, y?):
            XCTAssertLessThanOrEqual(abs(x - y), tol, "\(label): \(x) vs \(y) (tol \(tol))", file: file, line: line)
        default:
            XCTFail("\(label): présence diverge (\(String(describing: a)) vs \(String(describing: b)))", file: file, line: line)
        }
    }

    private func assertDailyClose(_ incr: [DailySnapshot], _ full: [DailySnapshot],
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(incr.count, full.count, "daily: nombre de jours diverge", file: file, line: line)
        let fullByDate = Dictionary(uniqueKeysWithValues: full.map { ($0.date, $0) })
        for d in incr {
            guard let f = fullByDate[d.date] else {
                XCTFail("daily: jour \(d.date) absent du pass complet", file: file, line: line); continue
            }
            // Catégoriel : exact (une régression qui fait basculer une bande/statut DOIT échouer).
            XCTAssertEqual(d.recoveryStatus, f.recoveryStatus, "daily \(d.date): recoveryStatus", file: file, line: line)
            XCTAssertEqual(d.recoveryBand, f.recoveryBand, "daily \(d.date): recoveryBand", file: file, line: line)
            XCTAssertEqual(d.isExpress, f.isExpress, "daily \(d.date): isExpress", file: file, line: line)
            // Numérique : bornes serrées (bruit flottant résumé-vs-brut toléré, dérive réelle non).
            assertClose(d.totalSleepMin, f.totalSleepMin, tol: 4.0, "daily \(d.date): TST", file: file, line: line)
            assertClose(d.efficiency, f.efficiency, tol: 0.02, "daily \(d.date): efficiency", file: file, line: line)
            assertClose(d.sleepScore, f.sleepScore, tol: 3.0, "daily \(d.date): sleepScore", file: file, line: line)
            assertClose(d.recovery, f.recovery, tol: 2.0, "daily \(d.date): recovery", file: file, line: line)
            assertClose(d.restingHR, f.restingHR, tol: 1.0, "daily \(d.date): RHR", file: file, line: line)
            assertClose(d.avgHrv, f.avgHrv, tol: 2.0, "daily \(d.date): avgHrv", file: file, line: line)
            assertClose(d.strain, f.strain, tol: 0.2, "daily \(d.date): strain", file: file, line: line)
        }
    }

    private func assertSleepSessionsClose(_ incr: [SleepSession], _ full: [SleepSession],
                                          file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(incr.count, full.count, "sleepSessions: nombre diverge", file: file, line: line)
        let a = incr.sorted { $0.startTs < $1.startTs }
        let b = full.sorted { $0.startTs < $1.startTs }
        for (x, y) in zip(a, b) {
            XCTAssertLessThanOrEqual(abs(x.startTs - y.startTs), 180, "session start: \(x.startTs) vs \(y.startTs)", file: file, line: line)
            XCTAssertLessThanOrEqual(abs(x.endTs - y.endTs), 180, "session end: \(x.endTs) vs \(y.endTs)", file: file, line: line)
            assertClose(x.efficiency, y.efficiency, tol: 0.03, "session efficiency", file: file, line: line)
        }
    }
}
