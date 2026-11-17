import XCTest
import Foundation
import ReplaySQLite
@testable import ReplayCore

final class ReplayTests: XCTestCase {
    private func fixture() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".loopbackup")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dir.appendingPathComponent("whoop.sqlite").path, &db), SQLITE_OK)
        guard let db else { throw ReplayError.sqlite("fixture") }
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE hrSample(deviceId TEXT, ts INTEGER, bpm INTEGER);
        CREATE TABLE rrInterval(deviceId TEXT, ts INTEGER, rrMs INTEGER);
        CREATE TABLE respSample(deviceId TEXT, ts INTEGER, raw INTEGER);
        CREATE TABLE gravitySample(deviceId TEXT, ts INTEGER, x REAL, y REAL, z REAL);
        CREATE TABLE external_workout(id TEXT, sportType INTEGER, startDate REAL, endDate REAL, distanceM REAL, source TEXT);
        CREATE TABLE health_sample(uuid TEXT, type TEXT, startDate REAL, endDate REAL, value REAL, sourceName TEXT);
        INSERT INTO external_workout VALUES('run',37,1200,1800,2000,'healthkit');
        INSERT INTO external_workout VALUES('walk',52,1800,2400,800,'healthkit');
        INSERT INTO health_sample VALUES('sleep','sleepAnalysis',20,120,2,'Synthetic');
        WITH RECURSIVE samples(n) AS (VALUES(0) UNION ALL SELECT n+1 FROM samples WHERE n<3599)
        INSERT INTO hrSample SELECT 'test', n, CASE WHEN n >= 1200 AND n < 1800 THEN 150 ELSE 60 END FROM samples;
        WITH RECURSIVE samples(n) AS (VALUES(0) UNION ALL SELECT n+1 FROM samples WHERE n<3599)
        INSERT INTO gravitySample SELECT 'test', n, 0, 0, 1 FROM samples;
        """
        var error: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(db, sql, nil, nil, &error)
        if let error { print(String(cString: error)); sqlite3_free(error) }
        XCTAssertEqual(status, SQLITE_OK)
        return dir
    }

    func testReplayIsDeterministicPreservesBackupAndSeparatesWorkouts() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let database = dir.appendingPathComponent("whoop.sqlite")
        let original = try Data(contentsOf: database)
        let options = ReplayOptions(backup: dir, start: 0, end: 3600, timezone: "Europe/Paris",
                                    restingHR: 60, maxHR: 190, engineRevision: "synthetic-v1")
        let first = try replay(options)
        XCTAssertEqual(first, try replay(options))
        XCTAssertEqual(first.sampleCounts["hr"], 3600)
        XCTAssertEqual(first.workouts.map(\.sportType), [37, 52])
        XCTAssertNotNil(first.load)
        XCTAssertEqual(first.healthSleep.count, 1)
        XCTAssertEqual(first.healthSleep.first?.value, 2)
        XCTAssertEqual(try Data(contentsOf: database), original)
        XCTAssertTrue(first.nights.isEmpty || first.nights.allSatisfy { $0.end > $0.start })
    }


    func testSyntheticNightRunsThroughSleepEngine() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dir.appendingPathComponent("whoop.sqlite").path, &db), SQLITE_OK)
        guard let db else { throw ReplayError.sqlite("fixture open") }
        let sql = """
        WITH RECURSIVE samples(n) AS (VALUES(0) UNION ALL SELECT n+1 FROM samples WHERE n<43199)
        INSERT INTO hrSample SELECT 'test',1704067200+n,CASE WHEN n < 7200 OR n >= 36000 THEN 90 ELSE 58 END FROM samples;
        WITH RECURSIVE samples(n) AS (VALUES(0) UNION ALL SELECT n+1 FROM samples WHERE n<43199)
        INSERT INTO gravitySample SELECT 'test',1704067200+n,CASE WHEN (n < 7200 OR n >= 36000) AND n%2=0 THEN 0.2 ELSE 0 END,0,1 FROM samples;
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let result = try replay(ReplayOptions(backup: dir, start: 1704067200, end: 1704110400, engineRevision: "night-v1"))
        XCTAssertEqual(result.sampleCounts["hr"], 43200)
        XCTAssertFalse(result.nights.isEmpty)
        XCTAssertTrue(result.nights.allSatisfy { $0.totalSleepMinutes > 0 && $0.end > $0.start })
    }

    func testReplayIncludesUncheckpointedWALWithoutTouchingInput() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("whoop.sqlite").path
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &connection), SQLITE_OK)
        guard let connection else { throw ReplayError.sqlite("fixture open") }
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; INSERT INTO hrSample VALUES('test', 4000, 65);", nil, nil, nil), SQLITE_OK)
        let wal = dir.appendingPathComponent("whoop.sqlite-wal")
        let before = try Data(contentsOf: wal)
        let output = try replay(ReplayOptions(backup: dir, start: 0, end: 5000, engineRevision: "wal-test"))
        XCTAssertEqual(output.sampleCounts["hr"], 3601)
        XCTAssertEqual(try Data(contentsOf: wal), before)
    }

    func testRejectsInvalidWindowAndHR() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertThrowsError(try replay(ReplayOptions(backup: dir, start: 10, end: 10, engineRevision: "x")))
        XCTAssertThrowsError(try replay(ReplayOptions(backup: dir, start: 0, end: 10, restingHR: 60, engineRevision: "x")))
    }
}
