import Foundation
import GRDB
import WhoopProtocol

// MARK: - Unsynced decoded reads + mark-synced
//
// These mirror `pendingRawBatches` / `markRawBatchSynced` for the decoded streams. The Uploader
// drains each stream by reading a page of `synced = 0` rows (oldest ts first), POSTing them, and —
// ONLY on a 2xx — marking exactly those rows synced. This replaces the broken forward-only upload
// highwater, which permanently stranded backfilled (older-ts) rows once the highwater jumped ahead.
//
// MARKING CONTRACT: each `markSynced…` takes back the EXACT rows that were uploaded and flips
// `synced = 1` for each row's natural key:
//   - hr / spo2 / skinTemp / resp / gravity / battery  → key is (deviceId, ts)  [ts is unique]
//   - rr      → key is (deviceId, ts, rrMs)             [multiple RR rows per ts]
//   - events  → key is (deviceId, ts, kind)             [multiple events per ts]
// Marking the exact uploaded keys (rather than a `ts <= max` range) is safe even if more rows for
// the same ts were inserted between the SELECT and the mark: only the uploaded keys are flipped, so
// a concurrently-backfilled row at the same ts stays `synced = 0` and uploads next drain.
extension WhoopStore {

    public func unsyncedHR(deviceId: String, limit: Int) async throws -> [HRSample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, bpm FROM hrSample
                WHERE deviceId = ? AND synced = 0
                ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, limit])
                .map { HRSample(ts: $0["ts"], bpm: $0["bpm"]) }
        }
    }

    public func unsyncedRR(deviceId: String, limit: Int) async throws -> [RRInterval] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, rrMs FROM rrInterval
                WHERE deviceId = ? AND synced = 0
                ORDER BY ts ASC, rrMs ASC LIMIT ?
                """, arguments: [deviceId, limit])
                .map { RRInterval(ts: $0["ts"], rrMs: $0["rrMs"]) }
        }
    }

    public func unsyncedEvents(deviceId: String, limit: Int) async throws -> [WhoopEvent] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, kind, payloadJSON FROM event
                WHERE deviceId = ? AND synced = 0
                ORDER BY ts ASC, kind ASC LIMIT ?
                """, arguments: [deviceId, limit])
                .map { row in
                    let json: String = row["payloadJSON"]
                    let payload = (try? JSONDecoder().decode(
                        [String: ParsedValue].self,
                        from: Data(json.utf8))) ?? [:]
                    return WhoopEvent(ts: row["ts"], kind: row["kind"], payload: payload)
                }
        }
    }

    public func unsyncedBattery(deviceId: String, limit: Int) async throws -> [BatterySample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, soc, mv, charging FROM battery
                WHERE deviceId = ? AND synced = 0
                ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, limit])
                .map { BatterySample(ts: $0["ts"], soc: $0["soc"], mv: $0["mv"], charging: $0["charging"]) }
        }
    }

    public func unsyncedSpo2(deviceId: String, limit: Int) async throws -> [SpO2Sample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, red, ir FROM spo2Sample
                WHERE deviceId = ? AND synced = 0
                ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, limit])
                .map { SpO2Sample(ts: $0["ts"], red: $0["red"], ir: $0["ir"]) }
        }
    }

    public func unsyncedSkinTemp(deviceId: String, limit: Int) async throws -> [SkinTempSample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, raw FROM skinTempSample
                WHERE deviceId = ? AND synced = 0
                ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, limit])
                .map { SkinTempSample(ts: $0["ts"], raw: $0["raw"]) }
        }
    }

    public func unsyncedResp(deviceId: String, limit: Int) async throws -> [RespSample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, raw FROM respSample
                WHERE deviceId = ? AND synced = 0
                ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, limit])
                .map { RespSample(ts: $0["ts"], raw: $0["raw"]) }
        }
    }

    public func unsyncedGravity(deviceId: String, limit: Int) async throws -> [GravitySample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, x, y, z FROM gravitySample
                WHERE deviceId = ? AND synced = 0
                ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, limit])
                .map { GravitySample(ts: $0["ts"], x: $0["x"], y: $0["y"], z: $0["z"]) }
        }
    }

    // MARK: - Device reassignment (one-time repair)

    /// Move all already-stored decoded rows (and raw batches) from one deviceId to another. Used when
    /// the collection deviceId was a placeholder that didn't match the upload/server deviceId, leaving
    /// downloaded rows under an id the uploader never drains. `UPDATE OR IGNORE` skips any natural-key
    /// collision with a row already present under the target id; those skipped duplicate old-id rows are
    /// deleted after the move so total stats don't keep reporting orphan rows. Rows keep their `synced`
    /// flag. Returns rows moved or deduplicated across all stream tables.
    @discardableResult
    public func reassignDevice(from old: String, to new: String) async throws -> Int {
        guard old != new else { return 0 }
        return try syncWrite { db in
            var moved = 0
            for table in ["hrSample", "rrInterval", "event", "battery",
                          "spo2Sample", "skinTempSample", "respSample", "gravitySample", "rawBatch"] {
                try db.execute(sql: "UPDATE OR IGNORE \(table) SET deviceId = ? WHERE deviceId = ?",
                               arguments: [new, old])
                moved += db.changesCount
            }

            moved += try deleteDeviceCollisionRows(db, table: "hrSample", old: old, new: new, keys: ["ts"])
            moved += try deleteDeviceCollisionRows(db, table: "rrInterval", old: old, new: new, keys: ["ts", "rrMs"])
            moved += try deleteDeviceCollisionRows(db, table: "event", old: old, new: new, keys: ["ts", "kind"])
            for table in ["battery", "spo2Sample", "skinTempSample", "respSample", "gravitySample"] {
                moved += try deleteDeviceCollisionRows(db, table: table, old: old, new: new, keys: ["ts"])
            }
            return moved
        }
    }

    private func deleteDeviceCollisionRows(_ db: Database, table: String, old: String, new: String, keys: [String]) throws -> Int {
        let predicate = keys.map { "target.\($0) = \(table).\($0)" }.joined(separator: " AND ")
        try db.execute(sql: """
            DELETE FROM \(table)
            WHERE deviceId = ?
              AND EXISTS (
                  SELECT 1 FROM \(table) target
                  WHERE target.deviceId = ? AND \(predicate)
              )
            """, arguments: [old, new])
        return db.changesCount
    }

    // MARK: - Mark synced (by exact uploaded natural keys)

    public func markHRSynced(deviceId: String, rows: [HRSample]) async throws {
        guard !rows.isEmpty else { return }
        try syncWrite { db in
            for r in rows {
                try db.execute(sql: "UPDATE hrSample SET synced = 1 WHERE deviceId = ? AND ts = ?",
                               arguments: [deviceId, r.ts])
            }
        }
    }

    public func markRRSynced(deviceId: String, rows: [RRInterval]) async throws {
        guard !rows.isEmpty else { return }
        try syncWrite { db in
            for r in rows {
                try db.execute(sql: """
                    UPDATE rrInterval SET synced = 1 WHERE deviceId = ? AND ts = ? AND rrMs = ?
                    """, arguments: [deviceId, r.ts, r.rrMs])
            }
        }
    }

    public func markEventsSynced(deviceId: String, rows: [WhoopEvent]) async throws {
        guard !rows.isEmpty else { return }
        try syncWrite { db in
            for e in rows {
                try db.execute(sql: """
                    UPDATE event SET synced = 1 WHERE deviceId = ? AND ts = ? AND kind = ?
                    """, arguments: [deviceId, e.ts, e.kind])
            }
        }
    }

    public func markBatterySynced(deviceId: String, rows: [BatterySample]) async throws {
        guard !rows.isEmpty else { return }
        try syncWrite { db in
            for b in rows {
                try db.execute(sql: "UPDATE battery SET synced = 1 WHERE deviceId = ? AND ts = ?",
                               arguments: [deviceId, b.ts])
            }
        }
    }

    public func markSpo2Synced(deviceId: String, rows: [SpO2Sample]) async throws {
        guard !rows.isEmpty else { return }
        try syncWrite { db in
            for s in rows {
                try db.execute(sql: "UPDATE spo2Sample SET synced = 1 WHERE deviceId = ? AND ts = ?",
                               arguments: [deviceId, s.ts])
            }
        }
    }

    public func markSkinTempSynced(deviceId: String, rows: [SkinTempSample]) async throws {
        guard !rows.isEmpty else { return }
        try syncWrite { db in
            for s in rows {
                try db.execute(sql: "UPDATE skinTempSample SET synced = 1 WHERE deviceId = ? AND ts = ?",
                               arguments: [deviceId, s.ts])
            }
        }
    }

    public func markRespSynced(deviceId: String, rows: [RespSample]) async throws {
        guard !rows.isEmpty else { return }
        try syncWrite { db in
            for s in rows {
                try db.execute(sql: "UPDATE respSample SET synced = 1 WHERE deviceId = ? AND ts = ?",
                               arguments: [deviceId, s.ts])
            }
        }
    }

    public func markGravitySynced(deviceId: String, rows: [GravitySample]) async throws {
        guard !rows.isEmpty else { return }
        try syncWrite { db in
            for s in rows {
                try db.execute(sql: "UPDATE gravitySample SET synced = 1 WHERE deviceId = ? AND ts = ?",
                               arguments: [deviceId, s.ts])
            }
        }
    }

    // MARK: - Unsynced delta total

    /// Nombre total de lignes décodées non encore uploadées (synced=0) pour ce device,
    /// toutes tables confondues (hr/rr/events/battery/spo2/skin_temp/resp/gravity).
    public func unsyncedTotal(deviceId: String) async throws -> Int {
        try syncRead { db in
            var total = 0
            for table in ["hrSample", "rrInterval", "event", "battery",
                          "spo2Sample", "skinTempSample", "respSample", "gravitySample"] {
                total += try Int.fetchOne(db,
                    sql: "SELECT COUNT(*) FROM \(table) WHERE deviceId = ? AND synced = 0",
                    arguments: [deviceId]) ?? 0
            }
            return total
        }
    }

    // MARK: - Test helper

    /// Count of `synced = 0` rows in a decoded table (for tests).
    public func unsyncedCountForTest(table: String, deviceId: String) async throws -> Int {
        try syncRead { db in
            try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM \(table) WHERE deviceId = ? AND synced = 0",
                arguments: [deviceId]) ?? 0
        }
    }
}
