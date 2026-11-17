import XCTest
@testable import WhoopStore

/// Fixture SYNTHÉTIQUE écrite à la main (exercices fictifs) au format de l'export Hevy.
enum HevyFixture {
    static let header = #""title","start_time","end_time","description","exercise_title","superset_id","exercise_notes","set_index","set_type","weight_kg","reps","distance_km","duration_seconds","rpe""#

    /// 3 séances : A (2 échauffements + 3 séries, 2 exercices), B (emoji, CRLF dans une note),
    /// C (sans heure : invalide, fin = début) + une ligne à date illisible.
    static let csv = [
        header,
        #""Push 💪🔥","12 nov. 2026, 12:22","12 nov. 2026, 13:30","","Presse Zorblax","","","0","warmup","20","10","","","""#,
        #""Push 💪🔥","12 nov. 2026, 12:22","12 nov. 2026, 13:30","","Presse Zorblax","","","1","warmup","40","5","","","""#,
        #""Push 💪🔥","12 nov. 2026, 12:22","12 nov. 2026, 13:30","","Presse Zorblax","","","2","normal","60","8","","","""#,
        #""Push 💪🔥","12 nov. 2026, 12:22","12 nov. 2026, 13:30","","Tirage Quuxien","","","0","failure","50,5","6","","","""#,
        #""Push 💪🔥","12 nov. 2026, 12:22","12 nov. 2026, 13:30","","Tirage Quuxien","","","1","dropset","30","","","","""#,
        #""Jambes, ""dures"" 🦵","1 févr. 2026, 09:05","1 février 2026, 10:00,","Ligne 1"#,
        #"ligne 2","Squat Fictif","","","0","normal","100","5","","","""#,
        #""Repos","1 mars 2026","1 mars 2026","","Gainage Imaginaire","","","0","normal","","","","60","""#,
        #""Cassée","32 nov. 2026, 12:00","32 nov. 2026, 13:00","","Truc","","","0","normal","10","10","","","""#,
        ""
    ].joined(separator: "\r\n")

    /// Même export, séance A rallongée de 15 min, séance B absente.
    static let csvSecond = [
        header,
        #""Push 💪🔥","12 nov. 2026, 12:22","12 nov. 2026, 13:45","","Presse Zorblax","","","0","normal","60","8","","","""#
    ].joined(separator: "\n")
}

final class HevyCSVParserTests: XCTestCase {
    private let paris = TimeZone(identifier: "Europe/Paris")!

    private func ts(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ zone: TimeZone) -> Double {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = zone
        return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!.timeIntervalSince1970
    }

    func testFrenchDates() throws {
        func d(_ s: String) -> Double? { HevyCSVParser.date(s, timeZone: paris)?.timeIntervalSince1970 }
        XCTAssertEqual(d("12 nov. 2026, 12:22"), ts(2026, 11, 12, 12, 22, paris))
        XCTAssertEqual(d("1 févr. 2026, 09:05"), ts(2026, 2, 1, 9, 5, paris))
        XCTAssertEqual(d("1 mars 2026"), ts(2026, 3, 1, 0, 0, paris))
        XCTAssertEqual(d("1 mars 2026,"), ts(2026, 3, 1, 0, 0, paris))
        XCTAssertEqual(d("3 août 2026, 18:00,"), ts(2026, 8, 3, 18, 0, paris))
        XCTAssertEqual(d("3 aout 2026 18:00"), ts(2026, 8, 3, 18, 0, paris))
        XCTAssertEqual(d("1 février 2026, 09:05"), ts(2026, 2, 1, 9, 5, paris))
        XCTAssertEqual(d("15 décembre 2026, 07:30"), ts(2026, 12, 15, 7, 30, paris))
        XCTAssertEqual(d("15 Déc. 2026, 07:30"), ts(2026, 12, 15, 7, 30, paris))
        let abbreviations = ["janv.", "févr.", "mars", "avr.", "mai", "juin", "juil.", "août", "sept.", "oct.", "nov.", "déc."]
        for (i, m) in abbreviations.enumerated() {
            XCTAssertEqual(d("2 \(m) 2026, 10:00"), ts(2026, i + 1, 2, 10, 0, paris), m)
        }
        XCTAssertNil(d("31 févr. 2026, 10:00"))
        XCTAssertNil(d("12 foo. 2026, 10:00"))
        XCTAssertNil(d("12 nov. 2026, 25:00"))
        XCTAssertNil(d(""))
    }

    func testDatesUseInjectedTimeZone() throws {
        let utc = TimeZone(secondsFromGMT: 0)!
        let p = try XCTUnwrap(HevyCSVParser.date("12 nov. 2026, 12:22", timeZone: paris))
        let u = try XCTUnwrap(HevyCSVParser.date("12 nov. 2026, 12:22", timeZone: utc))
        XCTAssertEqual(u.timeIntervalSince(p), 3600) // Paris = UTC+1 en novembre
    }

    func testGroupsSetsIntoSessions() throws {
        let r = try HevyCSVParser.parse(HevyFixture.csv, timeZone: paris)
        XCTAssertEqual(r.sessions.count, 2)
        let a = r.sessions[0]
        XCTAssertEqual(a.title, "Push 💪🔥")
        XCTAssertEqual(a.start.timeIntervalSince1970, ts(2026, 11, 12, 12, 22, paris))
        XCTAssertEqual(a.end.timeIntervalSince1970, ts(2026, 11, 12, 13, 30, paris))
        XCTAssertEqual(a.warmupSetCount, 2)
        XCTAssertEqual(a.workingSetCount, 3)
        XCTAssertEqual(a.setCount, 5)
        XCTAssertEqual(a.warmupVolumeKg, 20 * 10 + 40 * 5, accuracy: 1e-9)
        XCTAssertEqual(a.volumeKg, 60 * 8 + 50.5 * 6, accuracy: 1e-9) // dropset sans reps : 0
        let b = r.sessions[1]
        XCTAssertEqual(b.title, #"Jambes, "dures" 🦵"#)
        XCTAssertEqual(b.start.timeIntervalSince1970, ts(2026, 2, 1, 9, 5, paris))
        XCTAssertEqual(b.end.timeIntervalSince1970, ts(2026, 2, 1, 10, 0, paris))
        XCTAssertEqual(b.workingSetCount, 1)
        XCTAssertEqual(b.volumeKg, 500, accuracy: 1e-9)
        // « Repos » (fin = début) et « Cassée » (32 nov.) : comptées et ignorées.
        XCTAssertEqual(r.skippedRows, 2)
    }

    func testBOMAndLineEndings() throws {
        let lf = try HevyCSVParser.parse(HevyFixture.csv.replacingOccurrences(of: "\r\n", with: "\n"), timeZone: paris)
        let bom = try HevyCSVParser.parse("\u{FEFF}" + HevyFixture.csv, timeZone: paris)
        let crlf = try HevyCSVParser.parse(HevyFixture.csv, timeZone: paris)
        XCTAssertEqual(bom, crlf)
        XCTAssertEqual(lf, crlf)
        XCTAssertEqual(crlf.sessions.count, 2)
        // Sans gestion du BOM, l'en-tête « title » ne serait pas reconnu.
        XCTAssertEqual(HevyCSVParser.records("\u{FEFF}\"title\",x\r\n\"a\",b\r\n"), [["title", "x"], ["a", "b"]])
    }

    func testInvalidRowsNeverCrash() throws {
        let csv = HevyFixture.header + "\n" + #""X","12 nov. 2026, 13:00","12 nov. 2026, 12:00""# + "\n"
            + #""Y""# + "\n" + "\n" + #""Z","n'importe quoi","12 nov. 2026, 12:00","","E","","","0","normal","1","1""#
        let r = try HevyCSVParser.parse(csv, timeZone: paris)
        XCTAssertEqual(r.sessions.count, 0)
        XCTAssertEqual(r.skippedRows, 3)
        XCTAssertThrowsError(try HevyCSVParser.parse("", timeZone: paris)) {
            XCTAssertEqual($0 as? HevyCSVParser.ParseError, .empty)
        }
        XCTAssertThrowsError(try HevyCSVParser.parse("a,b\n1,2", timeZone: paris)) {
            XCTAssertEqual($0 as? HevyCSVParser.ParseError, .missingColumns(["title", "start_time", "end_time"]))
        }
    }
}

final class HevyImportStoreTests: XCTestCase {
    private let paris = TimeZone(identifier: "Europe/Paris")!
    private let now = Date(timeIntervalSince1970: 1_795_000_000)

    private func hevyRows(_ ws: WhoopStore) async throws -> [ExternalWorkout] {
        try await ws.externalWorkouts(from: 0, to: 4_000_000_000).filter(HevyImport.isHevy)
    }

    func testMappingToExternalWorkout() async throws {
        let ws = try await WhoopStore.inMemory()
        let report = try await HevyImportStore(store: ws).importCSV(HevyFixture.csv, timeZone: paris, now: now)
        XCTAssertEqual(report, HevyImportReport(inserted: 2, updated: 0, duplicates: 0, skippedRows: 2))
        let rows = try await hevyRows(ws)
        XCTAssertEqual(rows.count, 2)
        let a = try XCTUnwrap(rows.first { $0.endDate - $0.startDate == 68 * 60 })
        XCTAssertEqual(a.id, "hevy:\(Int(a.startDate))")
        XCTAssertEqual(Int(a.startDate) % 60, 0)
        XCTAssertEqual(a.source, "hevy")
        XCTAssertEqual(a.sourceName, "Hevy")
        XCTAssertEqual(a.sourceBundle, "com.hevy.csv")
        XCTAssertEqual(a.sportType, 50)
        XCTAssertEqual(a.durationSec, 68 * 60)
        XCTAssertNil(a.energyKcal)
        XCTAssertNil(a.distanceM)
        XCTAssertNil(a.productType)
        XCTAssertNil(a.deviceModel)
        XCTAssertFalse(ManualWorkout.isManual(a))
    }

    func testReimportSameFileCreatesNoDuplicate() async throws {
        let ws = try await WhoopStore.inMemory()
        let importer = HevyImportStore(store: ws)
        _ = try await importer.importCSV(HevyFixture.csv, timeZone: paris, now: now)
        let before = try await ws.externalWorkoutCount()
        let second = try await importer.importCSV(HevyFixture.csv, timeZone: paris, now: now)
        let after = try await ws.externalWorkoutCount()
        XCTAssertEqual(before, 2)
        XCTAssertEqual(after, before)
        XCTAssertEqual(second, HevyImportReport(inserted: 0, updated: 0, duplicates: 2, skippedRows: 2))
    }

    func testChangedEndUpdatesInPlaceAndAbsentSessionStays() async throws {
        let ws = try await WhoopStore.inMemory()
        let importer = HevyImportStore(store: ws)
        _ = try await importer.importCSV(HevyFixture.csv, timeZone: paris, now: now)
        let firstIDs = Set(try await hevyRows(ws).map(\.id))
        let report = try await importer.importCSV(HevyFixture.csvSecond, timeZone: paris, now: now)
        XCTAssertEqual(report, HevyImportReport(inserted: 0, updated: 1, duplicates: 0, skippedRows: 0))
        let rows = try await hevyRows(ws)
        XCTAssertEqual(rows.count, 2, "B absente du second export : conservée")
        XCTAssertEqual(Set(rows.map(\.id)), firstIDs, "ids conservés")
        let a = try XCTUnwrap(rows.first { $0.endDate - $0.startDate == 83 * 60 })
        XCTAssertEqual(a.durationSec, 83 * 60)
    }

    func testExistingRowWithinSixtySecondsIsUpdatedKeepingItsID() async throws {
        let ws = try await WhoopStore.inMemory()
        let start = try XCTUnwrap(HevyCSVParser.date("12 nov. 2026, 12:22", timeZone: paris)).timeIntervalSince1970
        let legacy = ExternalWorkout(id: "legacy-hevy", source: HevyImport.source, sportType: 50,
                                     startDate: start + 40, endDate: start + 3600, durationSec: 3560,
                                     energyKcal: nil, distanceM: nil, sourceName: "Hevy", importedAt: 0,
                                     sourceBundle: HevyImport.sourceBundle)
        try await ws.upsertExternalWorkouts([legacy])
        _ = try await HevyImportStore(store: ws).importCSV(HevyFixture.csvSecond, timeZone: paris, now: now)
        let rows = try await hevyRows(ws)
        XCTAssertEqual(rows.map(\.id), ["legacy-hevy"])
        XCTAssertEqual(rows[0].startDate, start + 40)
        XCTAssertEqual(rows[0].endDate, start + 83 * 60)
        XCTAssertEqual(rows[0].durationSec, 83 * 60 - 40)
    }

    func testNonHevyRowAtSameTimeIsNeverTouched() async throws {
        let ws = try await WhoopStore.inMemory()
        let start = try XCTUnwrap(HevyCSVParser.date("12 nov. 2026, 12:22", timeZone: paris)).timeIntervalSince1970
        let health = ExternalWorkout(id: "HK-1", source: "healthkit", sportType: 50, startDate: start,
                                     endDate: start + 1800, durationSec: 1800, energyKcal: 200, distanceM: nil,
                                     sourceName: "Hevy", importedAt: 0, sourceBundle: "com.hevy.app")
        try await ws.upsertExternalWorkouts([health])
        let report = try await HevyImportStore(store: ws).importCSV(HevyFixture.csvSecond, timeZone: paris, now: now)
        XCTAssertEqual(report.inserted, 1)
        let all = try await ws.externalWorkouts(from: 0, to: 4_000_000_000)
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.first { $0.id == "HK-1" }, health)
    }

    func testSessionsOneMinuteApartStayDistinct() async throws {
        let ws = try await WhoopStore.inMemory()
        let csv = [HevyFixture.header,
                   #""A","12 nov. 2026, 12:22","12 nov. 2026, 13:00","","E","","","0","normal","10","10","","","""#,
                   #""B","12 nov. 2026, 12:23","12 nov. 2026, 13:10","","E","","","0","normal","10","10","","","""#
        ].joined(separator: "\n")
        let report = try await HevyImportStore(store: ws).importCSV(csv, timeZone: paris, now: now)
        XCTAssertEqual(report.inserted, 2)
        let n12033 = try await hevyRows(ws).count
        XCTAssertEqual(n12033, 2)
        // Ré-import : toujours 2 lignes, chacune retrouvée par son propre début.
        let again = try await HevyImportStore(store: ws).importCSV(csv, timeZone: paris, now: now)
        XCTAssertEqual(again, HevyImportReport(inserted: 0, updated: 0, duplicates: 2, skippedRows: 0))
        let n12374 = try await hevyRows(ws).count
        XCTAssertEqual(n12374, 2)
    }

    func testSameSessionTwiceInFileCountsAsDuplicate() async throws {
        let ws = try await WhoopStore.inMemory()
        // Même début, titre différent : deux groupes, une seule séance.
        let csv = [HevyFixture.header,
                   #""Push","12 nov. 2026, 12:22","12 nov. 2026, 13:00","","E","","","0","normal","10","10","","","""#,
                   #""Push bis","12 nov. 2026, 12:22","12 nov. 2026, 13:00","","E","","","0","normal","10","10","","","""#
        ].joined(separator: "\n")
        let report = try await HevyImportStore(store: ws).importCSV(csv, timeZone: paris, now: now)
        XCTAssertEqual(report, HevyImportReport(inserted: 1, updated: 0, duplicates: 1, skippedRows: 0))
        let n13150 = try await hevyRows(ws).count
        XCTAssertEqual(n13150, 1)
    }

    func testIDCollisionWithOtherSourceRollsBackWholeImport() async throws {
        let ws = try await WhoopStore.inMemory()
        let parsed = try HevyCSVParser.parse(HevyFixture.csv, timeZone: paris)
        let b = parsed.sessions[1] // 2e séance du fichier : la 1re est insérée avant l'échec
        let squatter = ExternalWorkout(id: HevyImport.id(start: b.start), source: "healthkit", sportType: 37,
                                       startDate: 1_000, endDate: 2_000, durationSec: 1_000, energyKcal: nil,
                                       distanceM: nil, sourceName: "Autre", importedAt: 0, sourceBundle: "com.other")
        try await ws.upsertExternalWorkouts([squatter])
        do {
            _ = try await HevyImportStore(store: ws).importCSV(HevyFixture.csv, timeZone: paris, now: now)
            XCTFail("collision attendue")
        } catch {}
        let n14087 = try await hevyRows(ws).count
        XCTAssertEqual(n14087, 0, "aucune écriture partielle")
        let all = try await ws.externalWorkouts(from: 0, to: 4_000_000_000)
        XCTAssertEqual(all, [squatter])
    }

    func testRememberedTimeZoneIsReusedAcrossImports() async throws {
        let suite = "HevyImportTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ws = try await WhoopStore.inMemory()
        let importer = HevyImportStore(store: ws)
        let newYork = TimeZone(identifier: "America/New_York")!
        let first = try await importer.importCSV(HevyFixture.csv, defaults: defaults, deviceTimeZone: paris, now: now)
        XCTAssertEqual(first.inserted, 2)
        XCTAssertEqual(defaults.string(forKey: HevyImport.timeZoneDefaultsKey), "Europe/Paris")
        // Appareil passé à New York : le fuseau mémorisé (Paris) sert, aucun doublon.
        let second = try await importer.importCSV(HevyFixture.csv, defaults: defaults, deviceTimeZone: newYork, now: now)
        XCTAssertEqual(second, HevyImportReport(inserted: 0, updated: 0, duplicates: 2, skippedRows: 2))
        let n15293 = try await hevyRows(ws).count
        XCTAssertEqual(n15293, 2)
        // Sans mémoire, New York aurait décalé les débuts de 6 h : nouvelles lignes.
        let ws2 = try await WhoopStore.inMemory()
        _ = try await HevyImportStore(store: ws2).importCSV(HevyFixture.csv, timeZone: paris, now: now)
        let shifted = try await HevyImportStore(store: ws2).importCSV(HevyFixture.csv, timeZone: newYork, now: now)
        XCTAssertEqual(shifted.inserted, 2)
    }

    func testWindows1252FileIsDecoded() async throws {
        let text = HevyFixture.header + "\r\n" + #""Dos","1 févr. 2026, 09:05","1 févr. 2026, 10:00","","E","","","0","normal","10","10","","","""#
        let data = try XCTUnwrap(text.data(using: .windowsCP1252))
        XCTAssertNil(String(data: data, encoding: .utf8), "le fichier n'est pas de l'UTF-8 valide")
        let decoded = try XCTUnwrap(HevyCSVParser.decode(data))
        let ws = try await WhoopStore.inMemory()
        let report = try await HevyImportStore(store: ws).importCSV(decoded, timeZone: paris, now: now)
        XCTAssertEqual(report.inserted, 1)
        let rows = try await hevyRows(ws)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.startDate, HevyCSVParser.date("1 févr. 2026, 09:05", timeZone: paris)?.timeIntervalSince1970)
        XCTAssertEqual(HevyCSVParser.decode(Data("févr.".utf8)), "févr.")
    }

    func testImportNeverCreatesPerceivedEffort() async throws {
        let ws = try await WhoopStore.inMemory()
        _ = try await HevyImportStore(store: ws).importCSV(HevyFixture.csv, timeZone: paris, now: now)
        let efforts = try await ws.perceivedEfforts(recordedFrom: -1e12, to: 1e12)
        XCTAssertTrue(efforts.isEmpty)
        for w in try await hevyRows(ws) {
            let e = try await ws.perceivedEffort(workoutId: "external:\(w.id)")
            XCTAssertNil(e)
        }
    }
}
