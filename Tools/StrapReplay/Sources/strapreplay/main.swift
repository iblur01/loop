import Foundation
import CryptoKit
import SQLite3
import WhoopProtocol
import WhoopStore

// strapreplay — offline replay of a StrapCapture JSONL offload into a COPY of a Loop database.
//
// Reads the `rx_frame` lines (already reassembled), keeps only offload frames (types 47/48/49/50)
// in file order, rebuilds HISTORY_END chunks exactly like Loop/Core/Collect/Backfiller.swift
// (one START, repeated ENDs, records after an END form the next chunk) and persists each chunk via
// WhoopStore.commitHistoricalChunk (decoded streams ON CONFLICT DO NOTHING + raw batch keyed by a
// content hash + strap_trim cursor). No BLE, no ack, no tx replay. Never touches health_sample.

let usage = """
usage: strapreplay --capture <capture.jsonl> --db <copy.sqlite> [--device-id <id>] [--dry-run]

  --capture     StrapCapture JSONL (read only)
  --db          the COPY of whoop.sqlite to merge into (must already exist, schema v10)
  --device-id   deviceId rows are inserted under (default: theo-whoop, from the backup meta.json)
  --dry-run     parse + verify + decode, print what would be written, open nothing for writing
"""

struct Options {
    var capture = ""
    var db = ""
    var deviceId = "theo-whoop"
    var dryRun = false
}

func die(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(code)
}

func parseOptions() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let a = args.removeFirst()
        func value() -> String {
            guard !args.isEmpty else { die("missing value for \(a)\n\(usage)") }
            return args.removeFirst()
        }
        switch a {
        case "--capture": o.capture = value()
        case "--db": o.db = value()
        case "--device-id": o.deviceId = value()
        case "--dry-run": o.dryRun = true
        case "-h", "--help": print(usage); exit(0)
        default: die("unknown argument \(a)\n\(usage)")
        }
    }
    if o.capture.isEmpty || o.db.isEmpty { die(usage) }
    return o
}

// MARK: - Read-only SQLite helpers (counts, migrations, integrity) — never writes

final class ReadOnlyDB {
    private var handle: OpaquePointer?

    init(path: String) {
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            die("cannot open \(path) read-only")
        }
    }

    deinit { sqlite3_close(handle) }

    func strings(_ sql: String) -> [String] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            die("sql failed: \(sql): \(String(cString: sqlite3_errmsg(handle)))")
        }
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "NULL")
        }
        return out
    }

    func int(_ sql: String) -> Int { Int(strings(sql).first ?? "0") ?? 0 }

    func tableCounts() -> [(String, Int)] {
        strings("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
            .map { ($0, int("SELECT COUNT(*) FROM \"\($0)\"")) }
    }
}

// MARK: - Capture parsing

struct Capture {
    var offloadFrames: [[UInt8]] = []
    var rxFrameTypes: [UInt8: Int] = [:]
    var summaryNote: String?
    var badLines = 0
}

func bytes(fromHex hex: String) -> [UInt8]? {
    let chars = Array(hex.utf8)
    guard chars.count % 2 == 0 else { return nil }
    var out = [UInt8](); out.reserveCapacity(chars.count / 2)
    var i = 0
    while i < chars.count {
        guard let b = UInt8(String(decoding: chars[i..<i + 2], as: UTF8.self), radix: 16) else { return nil }
        out.append(b); i += 2
    }
    return out
}

func readCapture(path: String) -> Capture {
    guard let data = FileManager.default.contents(atPath: path) else { die("cannot read \(path)") }
    var cap = Capture()
    for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let kind = obj["kind"] as? String else { cap.badLines += 1; continue }
        switch kind {
        case "rx_frame":
            guard let hex = obj["hex"] as? String, let frame = bytes(fromHex: hex), frame.count > 4 else {
                cap.badLines += 1; continue
            }
            cap.rxFrameTypes[frame[4], default: 0] += 1
            if [47, 48, 49, 50].contains(frame[4]) { cap.offloadFrames.append(frame) }
        case "session":
            if let note = obj["note"] as? String, note.hasPrefix("end ") { cap.summaryNote = note }
        default:
            continue   // rx_raw (pre-reassembly duplicate) and tx (never replayed)
        }
    }
    return cap
}

/// Parses `chunks=300 ... types=[36:305 47:13844 ...]` from the session end note.
func parseSummary(_ note: String) -> (chunks: Int, types: [UInt8: Int])? {
    guard let c = note.range(of: "chunks="),
          let chunks = Int(note[c.upperBound...].prefix { $0.isNumber }),
          let open = note.range(of: "types=["),
          let close = note[open.upperBound...].firstIndex(of: "]") else { return nil }
    var types: [UInt8: Int] = [:]
    for pair in note[open.upperBound..<close].split(separator: " ") {
        let kv = pair.split(separator: ":")
        guard kv.count == 2, let t = UInt8(kv[0]), let n = Int(kv[1]) else { return nil }
        types[t] = n
    }
    return (chunks, types)
}

// MARK: - Chunk assembly (mirror of Backfiller.ingest / finishChunk / prepareChunk, minus BLE/UI)

struct PlannedChunk {
    let trim: UInt32
    let unix: UInt32
    let frames: [[UInt8]]
}

struct Assembly {
    var chunks: [PlannedChunk] = []      // one per HISTORY_END (frames may be empty)
    var startCount = 0
    var endCount = 0
    var completeCount = 0
    var invalidFrames = 0
    var trailingFrames = 0              // offload frames after the last END/COMPLETE: never committed
    var framesBeforeStart = 0
}

func assemble(_ frames: [[UInt8]]) -> Assembly {
    var a = Assembly()
    var chunk: [[UInt8]] = []
    var chunkOpen = true                 // Backfiller.begin(): accumulate from the outset
    var seenStart = false
    for frame in frames {
        guard verifyFrame(frame).ok else { a.invalidFrames += 1; continue }
        let meta: HistoricalMeta = frame[4] == 49 ? classifyHistoricalMeta(parseFrame(frame)) : .other
        switch meta {
        case .start:
            a.startCount += 1
            seenStart = true
            chunk.removeAll(keepingCapacity: true)
            chunkOpen = true
        case .end(let unix, let trim):
            a.endCount += 1
            // Backfiller.endData guard: a HISTORY_END shorter than 25 bytes is malformed.
            guard frame.count >= 25 else { die("malformed HISTORY_END (\(frame.count) bytes)") }
            a.chunks.append(PlannedChunk(trim: trim, unix: unix, frames: chunk))
            chunk.removeAll(keepingCapacity: true)
        case .complete:
            a.completeCount += 1
            a.trailingFrames += chunk.count
            chunk.removeAll(keepingCapacity: true)
            chunkOpen = false
        case .other:
            if !seenStart { a.framesBeforeStart += 1 }
            if chunkOpen { chunk.append(frame) }
        }
    }
    a.trailingFrames += chunk.count
    return a
}

/// Same as Backfiller.prepareChunk, but deterministic: the clock ref is the identity at the END's
/// own unix time instead of `Date()` (type-47/48 carry real unix timestamps, so the ref is unused
/// for decoding), and capturedAt = that same time. batchId = hist-<device>-<trim>-<sha256(frames)>.
func prepareChunk(_ c: PlannedChunk, deviceId: String) -> WhoopStore.HistoricalChunk {
    let parsed = c.frames.map { parseFrame($0) }
    let ref = ClockRef(device: Int(c.unix), wall: Int(c.unix))
    let decoded = extractHistoricalStreams(parsed, deviceClockRef: ref.device, wallClockRef: ref.wall)
    var digest = SHA256()
    var byteSize = 0
    for frame in c.frames {
        var size = UInt64(frame.count).littleEndian
        withUnsafeBytes(of: &size) { digest.update(data: Data($0)) }
        digest.update(data: Data(frame))
        byteSize += frame.count
    }
    let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
    let meta = RawBatchMeta(
        batchId: "hist-\(deviceId)-\(c.trim)-\(hash)",
        deviceId: deviceId,
        clockRef: ref,
        capturedAt: ref.wall,
        startTs: ref.wall,
        endTs: ref.wall,
        frameCount: c.frames.count,
        byteSize: byteSize)
    return WhoopStore.HistoricalChunk(streams: decoded, meta: meta, frames: c.frames, maxBytes: Int.max)
}

func iso(_ ts: Int) -> String {
    let f = ISO8601DateFormatter()
    return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
}

// MARK: - Main

let opts = parseOptions()
let dbURL = URL(fileURLWithPath: opts.db).standardizedFileURL.resolvingSymlinksInPath()
let dbPath = dbURL.path

// Safety: refuse anything that looks like an original backup or an app container.
for forbidden in [".loopbackup", "/Containers/", "/CoreSimulator/", "/Mobile Documents/"] where dbPath.contains(forbidden) {
    die("refusing to write to \(dbPath) (looks like an original, not a working copy)")
}
guard FileManager.default.fileExists(atPath: dbPath) else { die("\(dbPath) does not exist — copy the backup first") }

// 1. Capture: parse + verify against the session summary.
let cap = readCapture(path: opts.capture)
guard let note = cap.summaryNote, let summary = parseSummary(note) else { die("no session end summary in capture") }
print("capture: \(opts.capture)")
print("  summary: \(note)")
let typeLine = cap.rxFrameTypes.keys.sorted().map { "\($0):\(cap.rxFrameTypes[$0]!)" }.joined(separator: " ")
print("  rx_frame types: [\(typeLine)]  bad lines: \(cap.badLines)")
guard cap.rxFrameTypes == summary.types else { die("rx_frame type counts do not match the session summary") }

let assembly = assemble(cap.offloadFrames)
print("  offload frames (47/48/49/50): \(cap.offloadFrames.count)")
print("  START=\(assembly.startCount) END=\(assembly.endCount) COMPLETE=\(assembly.completeCount) invalid=\(assembly.invalidFrames) beforeStart=\(assembly.framesBeforeStart) trailing(uncommitted)=\(assembly.trailingFrames)")
guard assembly.endCount == summary.chunks else {
    die("HISTORY_END count \(assembly.endCount) != summary chunks=\(summary.chunks)")
}
guard assembly.invalidFrames == 0 else { die("\(assembly.invalidFrames) invalid offload frames (Backfiller would fail the session)") }
let trims = assembly.chunks.map(\.trim)
if zip(trims, trims.dropFirst()).contains(where: { $0 >= $1 }) { print("  WARNING: trim cursors are not strictly increasing") }
print("  trim range: \(trims.first ?? 0) → \(trims.last ?? 0)")

// 2. Decode every chunk (pure, no I/O).
let prepared: [(PlannedChunk, WhoopStore.HistoricalChunk?)] = assembly.chunks.map {
    ($0, $0.frames.isEmpty ? nil : prepareChunk($0, deviceId: opts.deviceId))
}
var decodedTotals: [String: Int] = [:]
var sampleTs: [Int] = []
var batchIds = Set<String>(), duplicateChunks = 0
for case let (_, chunk?) in prepared {
    let s = chunk.streams
    decodedTotals["hrSample", default: 0] += s.hr.count
    decodedTotals["rrInterval", default: 0] += s.rr.count
    decodedTotals["event", default: 0] += s.events.count
    decodedTotals["battery", default: 0] += s.battery.count
    decodedTotals["spo2Sample", default: 0] += s.spo2.count
    decodedTotals["skinTempSample", default: 0] += s.skinTemp.count
    decodedTotals["respSample", default: 0] += s.resp.count
    decodedTotals["gravitySample", default: 0] += s.gravity.count
    sampleTs += s.hr.map(\.ts)
    if !batchIds.insert(chunk.meta.batchId).inserted { duplicateChunks += 1 }
}
let emptyChunks = prepared.filter { $0.1 == nil }.count
print("decoded: chunks with records=\(prepared.count - emptyChunks) empty ENDs=\(emptyChunks) duplicate chunk contents=\(duplicateChunks)")
print("  decoded rows (before dedup): " + decodedTotals.keys.sorted().map { "\($0)=\(decodedTotals[$0]!)" }.joined(separator: " "))
if let lo = sampleTs.min(), let hi = sampleTs.max() { print("  hr ts range: \(iso(lo)) → \(iso(hi))") }

// 3. Database pre-checks (read-only handle).
var beforeCounts: [(String, Int)] = []
do {
    let ro = ReadOnlyDB(path: dbPath)
    let migrations = ro.strings("SELECT identifier FROM grdb_migrations ORDER BY rowid")
    let expected = (1...WhoopStoreInfo.schemaVersion).map { "v\($0)" }
    guard migrations == expected else {
        die("migrations in copy \(migrations) != \(expected): refusing (the migrator would change the schema)")
    }
    beforeCounts = ro.tableCounts()
    let hrMax = ro.int("SELECT COALESCE(MAX(ts),0) FROM hrSample WHERE deviceId='\(opts.deviceId)'")
    print("db: \(dbPath)  (migrations v1…v\(WhoopStoreInfo.schemaVersion), hrSample max ts before: \(iso(hrMax)))")
    print("  strap_trim before: \(ro.strings("SELECT value FROM cursors WHERE name='strap_trim'").first ?? "none")")
}

if opts.dryRun {
    print("dry run: nothing written")
    exit(0)
}

// 4. Commit, one transaction per chunk (same call as the app's Backfiller).
let done = DispatchSemaphore(value: 0)
var commitError: Error?
Task {
    do {
        let store = try await WhoopStore(path: dbPath)
        for (planned, chunk) in prepared {
            try await store.commitHistoricalChunk(chunk, cursor: "strap_trim", value: Int(planned.trim))
        }
        try await store.checkpoint()
    } catch { commitError = error }
    done.signal()
}
done.wait()
if let commitError { die("commit failed: \(commitError)") }

// 5. After: counts, integrity.
let ro = ReadOnlyDB(path: dbPath)
let after = Dictionary(uniqueKeysWithValues: ro.tableCounts())
print("table counts (before → after, +added):")
for (name, n) in beforeCounts {
    let m = after[name] ?? -1
    print("  \(name.padding(toLength: 22, withPad: " ", startingAt: 0)) \(n) → \(m)  (+\(m - n))")
}
let healthBefore = beforeCounts.first { $0.0 == "health_sample" }?.1
if let healthBefore, after["health_sample"] != healthBefore { die("health_sample changed!") }
print("  strap_trim after: \(ro.strings("SELECT value FROM cursors WHERE name='strap_trim'").first ?? "none")")
print("integrity_check: \(ro.strings("PRAGMA integrity_check").joined(separator: "; "))")
