import Foundation
import CryptoKit
import WhoopStore
import ReplayCore
import ReplaySQLite
import LoopStrapEngine

struct Report: Encodable {
    let engineRevision: String
    let snapshotSHA256: String
    let endingLocalDay: String
    let timeZone: String
    let days: Int
    let device: String
    let healthSettings: String
    let strainDifficulty: Double?
    let maxHeartRateOverride: Double?
    let daily: [DailySnapshot]
    let sleepSessions: [SleepSession]
    let workoutSessions: [WorkoutSession]
}

let usage = """
Usage: loop-daily-replay BACKUP.loopbackup --date YYYY-MM-DD --days N --device ID --revision LABEL
                         [--timezone IANA_ID] [--difficulty NUMBER] [--max-hr NUMBER]
Runs the actual app LocalMetricsEngine on a private copy of a quiescent backup.
--date is the last LOCAL calendar day included, in --timezone (default: this Mac's zone).
Every day of the window uses that zone (no per-day history). JSON contains sensitive health data.
"""

do {
    let args = Array(CommandLine.arguments.dropFirst())
    if args == ["--help"] || args == ["-h"] { print(usage); exit(0) }
    guard let path = args.first, !path.hasPrefix("--"), args.count % 2 == 1 else { throw ReplayError.invalid(usage) }
    var values: [String: String] = [:]
    let known = Set(["--date", "--days", "--device", "--revision", "--difficulty", "--max-hr", "--timezone"])
    var i = 1
    while i < args.count {
        let key = args[i]
        guard known.contains(key), values[key] == nil else { throw ReplayError.invalid("Unknown or repeated option: \(key)") }
        values[key] = args[i + 1]; i += 2
    }
    let zoneID = values["--timezone"] ?? TimeZone.autoupdatingCurrent.identifier
    guard let zone = TimeZone(identifier: zoneID) else { throw ReplayError.invalid("Unknown time zone: \(zoneID)") }
    // "now" = last second of the requested local day, so that day is "today" for the engine.
    guard let day = values["--date"], LocalDay.components(day) != nil,
          let nextStart = LocalDay.start(LocalDay.adding(1, to: day), in: zone),
          case let now = Date(timeIntervalSince1970: Double(nextStart - 1)),
          LocalDay.key(now.timeIntervalSince1970, in: zone) == day,
          let days = values["--days"].flatMap(Int.init), (1...60).contains(days),
          let device = values["--device"], !device.isEmpty,
          let revision = values["--revision"], !revision.isEmpty else { throw ReplayError.invalid(usage) }
    let selectedDifficulty = values["--difficulty"].flatMap(Double.init)
    guard values["--difficulty"] == nil || (selectedDifficulty?.isFinite == true && (0.3...2).contains(selectedDifficulty!)) else {
        throw ReplayError.invalid("difficulty must be between 0.3 and 2")
    }
    let maxHeartRate = values["--max-hr"].flatMap(Double.init)
    guard values["--max-hr"] == nil || (maxHeartRate?.isFinite == true && (25...250).contains(maxHeartRate!)) else {
        throw ReplayError.invalid("max-hr must be between 25 and 250 bpm")
    }
    let fm = FileManager.default
    let source = URL(fileURLWithPath: path, isDirectory: true)
    let temp = fm.temporaryDirectory.appendingPathComponent("loop-daily-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: temp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: temp) }
    var hasher = SHA256()
    for name in ["whoop.sqlite", "whoop.sqlite-wal", "whoop.sqlite-shm", "cache.json"] {
        let input = source.appendingPathComponent(name), output = temp.appendingPathComponent(name)
        guard fm.fileExists(atPath: input.path) else {
            if name == "whoop.sqlite" { throw ReplayError.invalid("Backup has no whoop.sqlite") }
            continue
        }
        try fm.copyItem(at: input, to: output)
        if name != "whoop.sqlite-shm" {
            hasher.update(data: Data(name.utf8))
            let h = try FileHandle(forReadingFrom: output)
            defer { try? h.close() }
            while let chunk = try h.read(upToCount: 1_048_576), !chunk.isEmpty { hasher.update(data: chunk) }
        }
    }
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    let dbPath = temp.appendingPathComponent("whoop.sqlite").path
    var db: OpaquePointer?
    guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
        if let db { sqlite3_close(db) }; throw ReplayError.invalid("Cannot open copied database")
    }
    var statement: OpaquePointer?
    let valid = sqlite3_prepare_v2(db, "PRAGMA quick_check", -1, &statement, nil) == SQLITE_OK &&
        sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_text(statement, 0).map { String(cString: $0) } == "ok"
    sqlite3_finalize(statement); sqlite3_close(db)
    guard valid else { throw ReplayError.invalid("Copied database failed integrity check") }
    var cache: LoopCache? = nil
    let cacheURL = temp.appendingPathComponent("cache.json")
    if fm.fileExists(atPath: cacheURL.path) {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        cache = try decoder.decode(LoopCache.self, from: Data(contentsOf: cacheURL))
    }
    let difficulty = selectedDifficulty ?? cache?.strainDifficulty
    let rejected = (cache?.rejectedWorkouts ?? []).map { (start: $0.startTs, end: $0.endTs) }
    let store = try await WhoopStore(path: dbPath)
    let engine = LocalMetricsEngine(store: store, deviceId: device, maxHeartRateOverride: maxHeartRate, timeZone: zone)
    let result = try await engine.computeCore(days: days, previous: nil, previousDayCounts: nil,
                                              forceFull: true, strainDifficulty: difficulty,
                                              rejectedRanges: rejected, now: now).result
    let priority = HealthReconciliationSettings().load()
    let report = Report(engineRevision: revision, snapshotSHA256: digest, endingLocalDay: day,
                        timeZone: zone.identifier, days: days, device: device, healthSettings: healthComputeSettingsKey(priority, maxHeartRate: maxHeartRate, deviceId: device),
                        strainDifficulty: difficulty, maxHeartRateOverride: maxHeartRate, daily: result.daily,
                        sleepSessions: result.sleepSessions, workoutSessions: result.workoutSessions)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(report)); FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("loop-daily-replay: \(error)\n".utf8)); exit(1)
}
