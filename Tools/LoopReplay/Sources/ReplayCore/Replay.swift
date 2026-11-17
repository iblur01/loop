import Foundation
import CryptoKit
import ReplaySQLite
import LoopStrapEngine

public enum ReplayError: Error, CustomStringConvertible {
    case invalid(String)
    case sqlite(String)
    public var description: String {
        switch self { case .invalid(let message), .sqlite(let message): return message }
    }
}

public struct ReplayOptions {
    public let backup: URL
    public let start: Int64
    public let end: Int64
    public let device: String?
    public let timezone: String
    public let restingHR: Double?
    public let maxHR: Double?
    public let engineRevision: String

    public init(backup: URL, start: Int64, end: Int64, device: String? = nil,
                timezone: String = "UTC", restingHR: Double? = nil, maxHR: Double? = nil,
                engineRevision: String) {
        self.backup = backup; self.start = start; self.end = end; self.device = device
        self.timezone = timezone; self.restingHR = restingHR; self.maxHR = maxHR
        self.engineRevision = engineRevision
    }
}

public struct Stage: Codable, Equatable { public let start: Double; public let end: Double; public let stage: String }
public struct Night: Codable, Equatable {
    public let start: Double; public let end: Double; public let totalSleepMinutes: Double
    public let wakeMinutes: Double; public let efficiency: Double; public let disturbances: Int
    public let stages: [Stage]
}
public struct Workout: Codable, Equatable {
    public let sportType: Int; public let start: Double; public let end: Double
    public let distanceM: Double?; public let source: String?
}
public struct SleepReference: Codable, Equatable {
    public let start: Double; public let end: Double; public let value: Double; public let sourceName: String?
}
public struct Load: Codable, Equatable {
    public let strain: Double; public let trimp: Double; public let zoneMinutes: [Double]
}
public struct Output: Codable, Equatable {
    public let schemaVersion: Int
    public let engineRevision: String
    public let inputSHA256: String
    public let start: Int64; public let end: Int64; public let timezone: String
    public let device: String
    public let restingHR: Double?; public let maxHR: Double?
    public let sampleCounts: [String: Int]
    public let nights: [Night]
    public let workouts: [Workout]
    public let healthSleep: [SleepReference]
    public let load: Load?
}

private final class Database {
    let db: OpaquePointer
    init(path: String) throws {
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(path, &pointer, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let pointer else {
            if let pointer { sqlite3_close(pointer) }
            throw ReplayError.sqlite("Cannot open snapshot database")
        }
        db = pointer
    }
    deinit { sqlite3_close(db) }
    func query(_ sql: String, bind: (OpaquePointer) -> Void = { _ in }, row: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ReplayError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return }
            guard result == SQLITE_ROW else { throw ReplayError.sqlite(String(cString: sqlite3_errmsg(db))) }
            try row(statement)
        }
    }
}
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
private func string(_ s: OpaquePointer, _ column: Int32) -> String? {
    guard let p = sqlite3_column_text(s, column) else { return nil }
    return String(cString: p)
}

/// Runs the actual LoopStrapEngine on a private temporary copy, never opening the input database.
/// The input package must be quiescent while copied. Windows are half-open [start, end).
public func replay(_ options: ReplayOptions) throws -> Output {
    let (duration, overflow) = options.end.subtractingReportingOverflow(options.start)
    guard !overflow, duration > 0, duration <= 172_800 else {
        throw ReplayError.invalid("Window must be positive and at most 48 hours")
    }
    guard TimeZone(identifier: options.timezone) != nil else { throw ReplayError.invalid("Invalid IANA timezone") }
    guard !options.engineRevision.isEmpty else { throw ReplayError.invalid("Engine revision is required") }
    guard (options.restingHR == nil) == (options.maxHR == nil),
          options.restingHR.map({ $0.isFinite && $0 > 0 }) ?? true,
          options.maxHR.map({ $0.isFinite && $0 > (options.restingHR ?? 0) }) ?? true else {
        throw ReplayError.invalid("Specify valid resting and maximum HR together")
    }
    let fm = FileManager.default
    let temp = fm.temporaryDirectory.appendingPathComponent("loop-replay-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: temp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: temp) }
    var hash = SHA256()
    for name in ["whoop.sqlite", "whoop.sqlite-wal", "whoop.sqlite-shm"] {
        let source = options.backup.appendingPathComponent(name)
        let destination = temp.appendingPathComponent(name)
        guard fm.fileExists(atPath: source.path) else {
            if name == "whoop.sqlite" { throw ReplayError.invalid("Backup has no whoop.sqlite") }
            continue
        }
        try fm.copyItem(at: source, to: destination)
        // -shm is a transient index and does not contribute to the SQLite logical input.
        if name != "whoop.sqlite-shm" {
            hash.update(data: Data(name.utf8))
            let handle = try FileHandle(forReadingFrom: destination)
            defer { try? handle.close() }
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        }
    }
    let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
    let db = try Database(path: temp.appendingPathComponent("whoop.sqlite").path)
    var integrity = ""
    try db.query("PRAGMA quick_check") { s in integrity = string(s, 0) ?? "" }
    guard integrity == "ok" else { throw ReplayError.sqlite("Snapshot integrity check failed: \(integrity)") }
    var devices: [String] = []
    try db.query("SELECT DISTINCT deviceId FROM hrSample WHERE ts >= ? AND ts < ? ORDER BY deviceId", bind: { s in
        sqlite3_bind_int64(s, 1, options.start); sqlite3_bind_int64(s, 2, options.end)
    }) { s in if let d = string(s, 0) { devices.append(d) } }
    let device: String
    if let selected = options.device { device = selected }
    else if devices.count == 1 { device = devices[0] }
    else { throw ReplayError.invalid("Specify --device: found \(devices.count) devices with HR in window") }
    func values(_ table: String, _ column: String, order: String = "ts") throws -> [(t: Double, v: Double)] {
        var result: [(t: Double, v: Double)] = []
        try db.query("SELECT ts, \(column) FROM \(table) WHERE deviceId = ? AND ts >= ? AND ts < ? ORDER BY \(order)", bind: { s in
            sqlite3_bind_text(s, 1, device, -1, sqliteTransient); sqlite3_bind_int64(s, 2, options.start); sqlite3_bind_int64(s, 3, options.end)
        }) { s in result.append((sqlite3_column_double(s, 0), sqlite3_column_double(s, 1))) }
        return result
    }
    let hr = try values("hrSample", "bpm")
    let rr = try values("rrInterval", "rrMs", order: "ts, rrMs")
    let resp = try values("respSample", "raw")
    var gravity: [(t: Double, x: Double, y: Double, z: Double)] = []
    try db.query("SELECT ts, x, y, z FROM gravitySample WHERE deviceId = ? AND ts >= ? AND ts < ? ORDER BY ts", bind: { s in
        sqlite3_bind_text(s, 1, device, -1, sqliteTransient); sqlite3_bind_int64(s, 2, options.start); sqlite3_bind_int64(s, 3, options.end)
    }) { s in gravity.append((sqlite3_column_double(s, 0), sqlite3_column_double(s, 1), sqlite3_column_double(s, 2), sqlite3_column_double(s, 3))) }
    let nights = detectSleep(streams: SleepStreams(hr: hr, rr: rr, resp: resp, gravity: gravityDeltaProxy(gravity))).map { n in
        Night(start: n.start, end: n.end, totalSleepMinutes: n.tst, wakeMinutes: n.waso,
              efficiency: n.efficiency, disturbances: n.nDisturbances,
              stages: n.stages.map { Stage(start: $0.start, end: $0.end, stage: $0.stage.rawValue) })
    }
    var workouts: [Workout] = []
    try db.query("SELECT sportType, startDate, endDate, distanceM, source FROM external_workout WHERE startDate < ? AND endDate > ? ORDER BY startDate, endDate, sportType, id", bind: { s in
        sqlite3_bind_double(s, 1, Double(options.end)); sqlite3_bind_double(s, 2, Double(options.start))
    }) { s in
        workouts.append(Workout(sportType: Int(sqlite3_column_int(s, 0)), start: sqlite3_column_double(s, 1), end: sqlite3_column_double(s, 2), distanceM: sqlite3_column_type(s, 3) == SQLITE_NULL ? nil : sqlite3_column_double(s, 3), source: string(s, 4)))
    }
    var countHealth = 0
    try db.query("SELECT COUNT(*) FROM health_sample WHERE startDate < ? AND endDate >= ?", bind: { s in
        sqlite3_bind_double(s, 1, Double(options.end)); sqlite3_bind_double(s, 2, Double(options.start))
    }) { s in countHealth = Int(sqlite3_column_int64(s, 0)) }
    var healthSleep: [SleepReference] = []
    try db.query("SELECT startDate, endDate, value, sourceName FROM health_sample WHERE type = 'sleepAnalysis' AND startDate < ? AND endDate > ? AND value IS NOT NULL ORDER BY startDate, endDate, sourceName, uuid", bind: { s in
        sqlite3_bind_double(s, 1, Double(options.end)); sqlite3_bind_double(s, 2, Double(options.start))
    }) { s in
        healthSleep.append(SleepReference(start: sqlite3_column_double(s, 0), end: sqlite3_column_double(s, 1), value: sqlite3_column_double(s, 2), sourceName: string(s, 3)))
    }
    var load: Load?
    if let rest = options.restingHR, let max = options.maxHR {
        do {
            let r = try strain(hrSeries: hr.map { (ts: $0.t, bpm: $0.v) }, restingHR: rest, hrmaxEstimate: max, sex: .male)
            load = Load(strain: r.strain, trimp: r.trimp, zoneMinutes: r.hrZoneMinutes)
        } catch StrainError.insufficientData { load = nil }
    }
    return Output(schemaVersion: 1, engineRevision: options.engineRevision, inputSHA256: digest,
                  start: options.start, end: options.end, timezone: options.timezone, device: device,
                  restingHR: options.restingHR, maxHR: options.maxHR, sampleCounts: ["hr": hr.count, "rr": rr.count, "resp": resp.count,
                                 "gravity": gravity.count, "health": countHealth], nights: nights,
                  workouts: workouts, healthSleep: healthSleep, load: load)
}
