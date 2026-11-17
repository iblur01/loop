import XCTest
@testable import LoopStrapEngine
import Foundation

// MARK: - RealVolumeTests
//
// Fait tourner le moteur sommeil sur de VRAIES données décodées (1 Hz, ~86k échantillons/jour)
// tirées du serveur via `scripts/fetch_fixtures.sh` vers Resources/realdata/.
//
// But :
//  1. Reproduire / verrouiller le bug de la session multi-jours (64h55) — garde-fou anti-régression.
//  2. Mesurer le temps de compute réel sur le volume qui prenait 30-40 min côté app.
//
// Si aucune fixture n'est présente (CI sans données), tous les tests se SKIPent proprement.

final class RealVolumeTests: XCTestCase {

    /// Représentation d'un export `/v1/export/decoded` : streams parallèles ts/valeur.
    private struct ExportDay: Decodable {
        struct HR: Decodable { let ts: [Double]; let bpm: [Double] }
        struct RR: Decodable { let ts: [Double]; let rr_ms: [Double] }
        struct Grav: Decodable { let ts: [Double]; let x: [Double]; let y: [Double]; let z: [Double] }
        let date: String
        let hr: HR
        let rr: RR
        let gravity: Grav
    }

    // MARK: - Chargement des fixtures

    /// Toutes les fixtures realdata présentes, triées par date croissante.
    private func loadDays(subdir: String = "realdata") throws -> [ExportDay] {
        let urls = realdataURLs(subdir)
        try XCTSkipIf(urls.isEmpty,
                      "aucune fixture \(subdir) — lancer `scripts/fetch_fixtures.sh` puis `swift test`")
        let dec = JSONDecoder()
        return try urls.compactMap { url -> ExportDay? in
            let data = try Data(contentsOf: url)
            return try? dec.decode(ExportDay.self, from: data)
        }.sorted { $0.date < $1.date }
    }

    /// Localise les fichiers `Resources/<subdir>/*.json` dans le bundle de test.
    private func realdataURLs(_ subdir: String = "realdata") -> [URL] {
        if let inSub = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: subdir),
           !inSub.isEmpty {
            return inSub
        }
        if subdir != "realdata" { return [] }
        // `.process` peut aplatir l'arborescence : retomber sur les .json nommés YYYY-MM-DD.
        let all = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        let dateRE = try? NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}$"#)
        return all.filter { url in
            let name = url.deletingPathExtension().lastPathComponent
            let r = NSRange(name.startIndex..., in: name)
            return dateRE?.firstMatch(in: name, range: r) != nil
        }
    }

    /// Concatène plusieurs jours en un seul `SleepStreams` (gravity → magnitude L2),
    /// comme le fait `LocalMetricsEngine` sur ses chunks de 7 jours.
    private func combinedStreams(_ days: [ExportDay]) -> SleepStreams {
        var hr: [(t: Double, v: Double)] = []
        var rr: [(t: Double, v: Double)] = []
        var xyz: [(t: Double, x: Double, y: Double, z: Double)] = []
        for d in days {
            hr += zip(d.hr.ts, d.hr.bpm).map { (t: $0, v: $1) }
            rr += zip(d.rr.ts, d.rr.rr_ms).map { (t: $0, v: $1) }
            for i in 0..<d.gravity.ts.count {
                xyz.append((t: d.gravity.ts[i], x: d.gravity.x[i], y: d.gravity.y[i], z: d.gravity.z[i]))
            }
        }
        hr.sort { $0.t < $1.t }; rr.sort { $0.t < $1.t }; xyz.sort { $0.t < $1.t }
        // gravity = per-record movement proxy (matches Python _gravity_deltas), NOT magnitude.
        return SleepStreams(hr: hr, rr: rr, resp: [], gravity: gravityDeltaProxy(xyz))
    }

    // MARK: - Tests

    /// GARDE-FOU : aucune session ne doit dépasser le plafond physiologique (16h).
    /// Sans le fix InBedDetection, la fenêtre multi-jours produisait une session de 64h55.
    func testNoSessionExceedsPhysiologicalCap() throws {
        let days = try loadDays()
        let streams = combinedStreams(days)
        let sessions = detectSleep(streams: streams)

        let capHours = 16.0
        for s in sessions {
            let h = (s.end - s.start) / 3600.0
            XCTAssertLessThanOrEqual(
                h, capHours,
                "session \(Date(timeIntervalSince1970: s.start)) → \(Date(timeIntervalSince1970: s.end)) "
                + "dure \(String(format: "%.1f", h))h — dépasse le cap \(capHours)h"
            )
        }
        print("RealVolume: \(days.count) jours, \(sessions.count) session(s) détectée(s)")
        for s in sessions.sorted(by: { $0.start < $1.start }) {
            let h = (s.end - s.start) / 3600.0
            print(String(format: "  %@ → %@  %.1fh  TST=%.0fmin eff=%.2f",
                         iso(s.start), iso(s.end), h, s.tst, s.efficiency))
        }
    }

    /// PERF : la détection sommeil sur toute la fenêtre réelle doit rester rapide.
    /// (Le coût explosait avant le fix car la grille d'époques couvrait des spans multi-jours.)
    func testSleepDetectionPerformanceOnRealVolume() throws {
        let days = try loadDays()
        let streams = combinedStreams(days)
        let t0 = Date()
        let sessions = detectSleep(streams: streams)
        let elapsed = Date().timeIntervalSince(t0)
        let perDay = elapsed / Double(max(1, days.count))
        print(String(format: "RealVolume: detectSleep sur %d jours en %.2fs (%.1fs/jour, %d sessions)",
                     days.count, elapsed, perDay, sessions.count))
        // Garde-fou de RÉGRESSION (pas un objectif de perf absolu). Le coût "sain" est dominé par
        // la Welch PSD par-ancre, inhérente au modèle de sommeil, et mesurée ici en DEBUG (release
        // via Accelerate ≈ 5-10× plus rapide). Le seuil par jour attrape la pathologie historique
        // (sessions multi-jours → grilles de milliers d'époques → FFT en rafale = des minutes/jour).
        // Avec le cap 16h, le coût par jour reste borné.
        XCTAssertLessThan(perDay, 30.0,
                          "régression perf: \(perDay)s/jour (debug) — vérifier le cap de session et l'O(n) de classifyStill")
    }

    /// Session sommeil calculée par le serveur (Python, déjà validée).
    private struct ServerSleep: Decodable {
        let start: Double
        let end: Double
        let efficiency: Double?
    }

    /// COMPARAISON : sessions Swift vs sessions serveur (Python validé). Imprime un tableau
    /// apparié par recouvrement temporel et chiffre l'écart de bornes/durée. Garde-fou doux :
    /// chaque session serveur doit être recouverte par une session Swift (pas de nuit manquée).
    func testCompareWithServerSleep() throws {
        let days = try loadDays()
        guard let url = Bundle.module.url(forResource: "server_sleep", withExtension: "json")
                ?? Bundle.module.url(forResource: "server_sleep", withExtension: "json", subdirectory: "realdata") else {
            throw XCTSkip("server_sleep.json absent — relancer le fetch des sessions serveur")
        }
        let server = try JSONDecoder().decode([ServerSleep].self, from: Data(contentsOf: url))
        let swift = detectSleep(streams: combinedStreams(days)).sorted { $0.start < $1.start }

        print("=== Swift vs Serveur (Python validé) ===")
        print(String(format: "%-26@ | %-26@ | %@", "SERVEUR" as NSString, "SWIFT (match overlap)" as NSString, "Δdébut/Δfin/Δdurée min"))
        var durErrors: [Double] = []
        var covered = 0
        for srv in server.sorted(by: { $0.start < $1.start }) {
            // Meilleur match = recouvrement temporel max.
            let match = swift.max { a, b in overlap(a.start, a.end, srv.start, srv.end) < overlap(b.start, b.end, srv.start, srv.end) }
            let ov = match.map { overlap($0.start, $0.end, srv.start, srv.end) } ?? 0
            if let m = match, ov > 0 {
                covered += 1
                let dStart = (m.start - srv.start) / 60.0
                let dEnd = (m.end - srv.end) / 60.0
                let srvDur = (srv.end - srv.start) / 60.0
                let swDur = (m.end - m.start) / 60.0
                durErrors.append(abs(swDur - srvDur))
                print(String(format: "%@→%@ (%.0fm) | %@→%@ (%.0fm) | %+.0f/%+.0f/%+.0f",
                             iso(srv.start), iso(srv.end), srvDur,
                             iso(m.start), iso(m.end), swDur, dStart, dEnd, swDur - srvDur))
            } else {
                print(String(format: "%@→%@ | AUCUN MATCH SWIFT", iso(srv.start), iso(srv.end)))
            }
        }
        let mae = durErrors.isEmpty ? 0 : durErrors.reduce(0,+) / Double(durErrors.count)
        print(String(format: "Couverture: %d/%d sessions serveur ; MAE durée = %.0f min",
                     covered, server.count, mae))
        print(String(format: "Swift: %d sessions vs Serveur: %d", swift.count, server.count))

        // Garde-fou doux : aucune nuit serveur ne doit être totalement manquée.
        XCTAssertEqual(covered, server.count, "des sessions serveur ne sont pas couvertes par Swift")
    }

    /// DEBUG: dump Swift's intermediate runs (after merge) + confirmed spans, for parity
    /// diffing against the Python oracle probe.
    func testDumpSwiftRuns() throws {
        let days = try loadDays()
        let s = combinedStreams(days)
        let runs = debugInBedPipeline(
            gravTimes: s.gravity.map { $0.t }, gravValues: s.gravity.map { $0.v },
            hrTimes: s.hr.map { $0.t }, hrValues: s.hr.map { $0.v })
        print("=== SWIFT runs after merge (\(runs.count)) ===")
        for r in runs {
            let conf = r.confirmed.map { "\(iso($0.0))->\(iso($0.1))" }.joined(separator: ",")
            print(String(format: "%@ %@->%@ %.1fh gaps=%d conf=[%@]",
                         r.stage, iso(r.start), iso(r.end), (r.end - r.start)/3600, r.nWakeGaps, conf))
        }
    }

    /// PARITÉ ALGO PURE : Swift vs Python-local exécuté sur le MÊME raw exporté (local_python_sleep.json).
    /// Isole la fidélité de l'algorithme (vs server_sleep.json qui vient de la VM sur un raw différent).
    func testCompareWithLocalPython() throws {
        let days = try loadDays()
        guard let url = Bundle.module.url(forResource: "local_python_sleep", withExtension: "json")
                ?? Bundle.module.url(forResource: "local_python_sleep", withExtension: "json", subdirectory: "realdata") else {
            throw XCTSkip("local_python_sleep.json absent — générer via /tmp/dump_py_sessions.py")
        }
        let py = try JSONDecoder().decode([ServerSleep].self, from: Data(contentsOf: url))
        let swift = detectSleep(streams: combinedStreams(days)).sorted { $0.start < $1.start }
        print("=== Swift vs Python-LOCAL (même raw) ===")
        var durErrors: [Double] = []
        var covered = 0
        for o in py.sorted(by: { $0.start < $1.start }) {
            let match = swift.max { a, b in overlap(a.start, a.end, o.start, o.end) < overlap(b.start, b.end, o.start, o.end) }
            if let m = match, overlap(m.start, m.end, o.start, o.end) > 0 {
                covered += 1
                let dStart = (m.start - o.start)/60, dEnd = (m.end - o.end)/60
                durErrors.append(abs((m.end-m.start) - (o.end-o.start))/60)
                print(String(format: "%@→%@ (%.0fm) | %@→%@ (%.0fm) | %+.0f/%+.0f",
                             iso(o.start), iso(o.end), (o.end-o.start)/60,
                             iso(m.start), iso(m.end), (m.end-m.start)/60, dStart, dEnd))
            }
        }
        let mae = durErrors.isEmpty ? 0 : durErrors.reduce(0,+)/Double(durErrors.count)
        print(String(format: "Couverture %d/%d ; MAE durée = %.1f min ; Swift %d vs PyLocal %d",
                     covered, py.count, mae, swift.count, py.count))
        XCTAssertLessThan(mae, 5.0, "parité algo Swift↔Python-local: MAE \(mae) min > 5")
    }

    /// DOCUMENTATION (pas d'assert) : Swift sur 9 jours NATIFS CONCATÉNÉS (sans fenêtrage par-jour)
    /// vs le serveur. L'écart résiduel (~22 min sur 06-14 sieste & 06-15 doze) vient du FENÊTRAGE,
    /// pas de l'algorithme : le serveur détecte par jour sur [day-1 18:00 UTC, day+1 00:00), ce qui
    /// exclut le doze du soir précédent. testCompareWindowedWithServer (qui applique cette fenêtre,
    /// = ce que fait LocalMetricsEngine) tombe à MAE 0.4 min. Ce test montre l'effet du fenêtrage.
    func testCompareNativeWithServer() throws {
        // Native fixtures are named native-YYYY-MM-DD.json (flat bundle, no name clash with realdata).
        let urls = (Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("native-") }
        try XCTSkipIf(urls.isEmpty, "fixtures natives absentes (realdata_native/)")
        let dec = JSONDecoder()
        let days = try urls.compactMap { try dec.decode(ExportDay.self, from: Data(contentsOf: $0)) }
            .sorted { $0.date < $1.date }
        guard let url = Bundle.module.url(forResource: "server_sleep", withExtension: "json")
                ?? Bundle.module.url(forResource: "server_sleep", withExtension: "json", subdirectory: "realdata") else {
            throw XCTSkip("server_sleep.json absent")
        }
        let server = try JSONDecoder().decode([ServerSleep].self, from: Data(contentsOf: url))
        let swift = detectSleep(streams: combinedStreams(days)).sorted { $0.start < $1.start }
        print("=== Swift(NATIF) vs Serveur VM ===")
        var durErrors: [Double] = []; var covered = 0
        for o in server.sorted(by: { $0.start < $1.start }) {
            let match = swift.max { a, b in overlap(a.start, a.end, o.start, o.end) < overlap(b.start, b.end, o.start, o.end) }
            if let m = match, overlap(m.start, m.end, o.start, o.end) > 0 {
                covered += 1
                durErrors.append(abs((m.end-m.start) - (o.end-o.start))/60)
                print(String(format: "%@→%@ (%.0fm) | %@→%@ (%.0fm) | %+.0f/%+.0f",
                             iso(o.start), iso(o.end), (o.end-o.start)/60,
                             iso(m.start), iso(m.end), (m.end-m.start)/60,
                             (m.start-o.start)/60, (m.end-o.end)/60))
            }
        }
        let mae = durErrors.isEmpty ? 0 : durErrors.reduce(0,+)/Double(durErrors.count)
        print(String(format: "Couverture %d/%d ; MAE durée NATIF = %.1f min ; Swift %d vs Serveur %d",
                     covered, server.count, mae, swift.count, server.count))
    }

    /// PRODUCTION PARITY: replicate LocalMetricsEngine's per-day sleep window
    /// [day-1 18:00 UTC, day+1 00:00) on native data and compare to the (recomputed) server.
    /// This is the windowing that makes the app match the server's per-day compute_day.
    func testCompareWindowedWithServer() throws {
        let urls = (Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("native-") }
        try XCTSkipIf(urls.isEmpty, "fixtures natives absentes")
        let dec = JSONDecoder()
        let days = try urls.compactMap { try dec.decode(ExportDay.self, from: Data(contentsOf: $0)) }.sorted { $0.date < $1.date }
        guard let surl = Bundle.module.url(forResource: "server_sleep", withExtension: "json")
                ?? Bundle.module.url(forResource: "server_sleep", withExtension: "json", subdirectory: "realdata") else {
            throw XCTSkip("server_sleep.json absent")
        }
        let server = try JSONDecoder().decode([ServerSleep].self, from: Data(contentsOf: surl))

        // Native combined raw, sorted.
        var hr: [(t: Double, v: Double)] = [], rr: [(t: Double, v: Double)] = []
        var xyz: [(t: Double, x: Double, y: Double, z: Double)] = []
        for d in days {
            hr += zip(d.hr.ts, d.hr.bpm).map { (t: $0, v: $1) }
            rr += zip(d.rr.ts, d.rr.rr_ms).map { (t: $0, v: $1) }
            for i in 0..<d.gravity.ts.count { xyz.append((d.gravity.ts[i], d.gravity.x[i], d.gravity.y[i], d.gravity.z[i])) }
        }
        hr.sort { $0.t < $1.t }; rr.sort { $0.t < $1.t }; xyz.sort { $0.t < $1.t }

        let cal = Calendar(identifier: .gregorian)
        let utc = TimeZone(identifier: "UTC")!
        let paris = TimeZone(identifier: "Europe/Paris")!
        func parisDate(_ ts: Double) -> String {
            var c = cal; c.timeZone = paris
            let comps = c.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: ts))
            return String(format: "%04d-%02d-%02d", comps.year!, comps.month!, comps.day!)
        }
        let fmt = ISO8601DateFormatter(); fmt.formatOptions = [.withFullDate]; fmt.timeZone = utc
        let dates = days.map { $0.date }
        var detected: [(start: Double, end: Double)] = []
        var seen = Set<String>()
        for date in dates {
            guard let day = fmt.date(from: date) else { continue }
            var c = cal; c.timeZone = utc
            let dayFrom = c.startOfDay(for: day).timeIntervalSince1970
            let dayTo = dayFrom + 86400
            let lo = dayFrom - 6*3600, hi = dayTo
            let s = SleepStreams(
                hr: hr.filter { $0.t >= lo && $0.t < hi },
                rr: rr.filter { $0.t >= lo && $0.t < hi },
                resp: [],
                gravity: gravityDeltaProxy(xyz.filter { $0.t >= lo && $0.t < hi }))
            for sess in detectSleep(streams: s) where parisDate(sess.end) == date {
                let id = "\(Int(sess.start))-\(Int(sess.end))"
                if seen.insert(id).inserted { detected.append((sess.start, sess.end)) }
            }
        }
        detected.sort { $0.start < $1.start }
        print("=== Swift(fenêtré par-jour) vs Serveur recalculé ===")
        var durErrors: [Double] = []; var covered = 0
        for o in server.sorted(by: { $0.start < $1.start }) {
            let m = detected.max { a, b in overlap(a.start, a.end, o.start, o.end) < overlap(b.start, b.end, o.start, o.end) }
            if let m = m, overlap(m.start, m.end, o.start, o.end) > 0 {
                covered += 1; durErrors.append(abs((m.end-m.start)-(o.end-o.start))/60)
                print(String(format: "%@→%@ (%.0fm) | %@→%@ (%.0fm) | %+.0f/%+.0f",
                             iso(o.start), iso(o.end), (o.end-o.start)/60,
                             iso(m.start), iso(m.end), (m.end-m.start)/60, (m.start-o.start)/60, (m.end-o.end)/60))
            }
        }
        let mae = durErrors.isEmpty ? 0 : durErrors.reduce(0,+)/Double(durErrors.count)
        print(String(format: "Couverture %d/%d ; MAE durée = %.1f min ; Swift %d vs Serveur %d",
                     covered, server.count, mae, detected.count, server.count))
        XCTAssertLessThan(mae, 5.0, "parité fenêtrée Swift↔serveur: MAE \(mae) min > 5")
    }

    private func overlap(_ a0: Double, _ a1: Double, _ b0: Double, _ b1: Double) -> Double {
        max(0, min(a1, b1) - max(a0, b0))
    }

    // MARK: - Helpers

    private func iso(_ ts: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        f.timeZone = TimeZone(identifier: "Europe/Paris")
        return f.string(from: Date(timeIntervalSince1970: ts))
    }
}
