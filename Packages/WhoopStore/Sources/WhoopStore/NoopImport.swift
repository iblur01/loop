import Foundation
import GRDB
import CryptoKit

/// Summary of compatible, decoded samples and retained raw batches for one source device.
public struct NoopImportDevice: Sendable {
    public let id: String
    public let counts: [String: Int]
}

public struct NoopImportPreview: Sendable {
    public let devices: [NoopImportDevice]
    /// Tables that Loop does not interpret. Keep the original backup to retain them.
    public let unsupportedTables: [String]
    /// Fields from supported tables that Loop does not import.
    public let ignoredColumns: [String]
}

public struct NoopImportCount: Sendable {
    public let inserted: Int
    /// Includes repeated values and existing-key conflicts, including RR samples that
    /// Loop cannot distinguish because its key does not include Noop's sequence.
    public let skipped: Int
}

public struct NoopImportReport: Sendable {
    public let counts: [String: NoopImportCount]
    public let unsupportedTables: [String]
    public let ignoredColumns: [String]
    /// Decoded-sample range for this device, including keys already present in Loop.
    public let earliestTimestamp: Int?
    public let latestTimestamp: Int?
}

/// Counts describe the current table, and remain provisional until `committed`.
public struct NoopImportProgress: Sendable {
    public enum Phase: Sendable { case validating, importing, committed }
    public let phase: Phase
    public let table: String?
    public let processed: Int
    public let inserted: Int
    public let skipped: Int
}

public enum NoopImportError: LocalizedError {
    case invalidSource(String)
    case invalidDevice
    case sameDatabase
    case invalidRawBatch
    public var errorDescription: String? {
        switch self {
        case .invalidSource(let reason): return "Sauvegarde Noop invalide : \(reason)"
        case .invalidDevice: return "Sélectionnez un appareil source et un appareil Loop valides."
        case .sameDatabase: return "La base active ne peut pas être utilisée comme sauvegarde source."
        case .invalidRawBatch: return "Un lot de données brutes Noop est invalide ou trop volumineux ; aucun changement n'a été effectué."
        }
    }
}

private struct NoopTable {
    let name: String
    let columns: [String] // excludes deviceId and imported sync marker
    let required: Bool
}

private let noopTables: [NoopTable] = [
    .init(name: "hrSample", columns: ["ts", "bpm"], required: true),
    .init(name: "rrInterval", columns: ["ts", "rrMs"], required: true),
    .init(name: "event", columns: ["ts", "kind", "payloadJSON"], required: true),
    .init(name: "battery", columns: ["ts", "soc", "mv"], required: true),
    .init(name: "spo2Sample", columns: ["ts", "red", "ir"], required: false),
    .init(name: "skinTempSample", columns: ["ts", "raw"], required: false),
    .init(name: "respSample", columns: ["ts", "raw"], required: false),
    .init(name: "gravitySample", columns: ["ts", "x", "y", "z"], required: false),
    .init(name: "rawBatch", columns: ["batchId", "capturedAt", "deviceClockRef", "wallClockRef", "startTs", "endTs", "frameCount", "byteSize", "framesBlob"], required: true)
]

extension WhoopStore {
    private static func openNoopSource(_ url: URL) throws -> DatabaseQueue {
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else {
            throw NoopImportError.invalidSource("fichier introuvable")
        }
        // Immutable mode is needed for standalone snapshots whose header still says WAL.
        // It ignores a separate WAL, so never use it if committed pages may be in one.
        let walPath = url.path + "-wal"
        if FileManager.default.fileExists(atPath: walPath) {
            let attributes = try FileManager.default.attributesOfItem(atPath: walPath)
            guard let size = attributes[.size] as? NSNumber, size.int64Value == 0 else {
                throw NoopImportError.invalidSource("la base possède un journal WAL non vide ; exportez une sauvegarde complète depuis Noop")
            }
        }
        var configuration = Configuration()
        configuration.readonly = true
        return try DatabaseQueue(path: url.absoluteString + "?immutable=1", configuration: configuration)
    }

    private static func readNoop<T>(_ queue: DatabaseQueue, _ body: (Database) throws -> T) throws -> T {
        try queue.read(body)
    }

    private static func validateNoop(_ db: Database) throws -> (Set<String>, [String], [String]) {
        let integrity = try String.fetchAll(db, sql: "PRAGMA quick_check(1)")
        guard integrity == ["ok"] else { throw NoopImportError.invalidSource("intégrité SQLite") }
        let names = try Set(String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"))
        var ignored: [String] = []
        for table in noopTables {
            guard names.contains(table.name) else {
                if table.required { throw NoopImportError.invalidSource("table \(table.name) absente") }
                continue
            }
            let columns = try Set(db.columns(in: table.name).map(\.name))
            guard Set(table.columns + ["deviceId"]).isSubset(of: columns) else {
                throw NoopImportError.invalidSource("colonnes incompatibles : \(table.name)")
            }
            var represented = Set(table.columns + ["deviceId", "synced", "syncedAt"])
            if table.name == "battery" { represented.insert("charging") }
            ignored.append(contentsOf: columns.subtracting(represented).map { "\(table.name).\($0)" })
        }
        let known = Set(noopTables.map(\.name)).union(["device", "grdb_migrations"])
        return (names, names.subtracting(known).sorted(), ignored.sorted())
    }

    /// Inspect a standalone SQLite file extracted from a Noop backup. No writes are made
    /// to the source. A separate explicit import is required for each selected device.
    public func inspectNoopDatabase(at url: URL) async throws -> NoopImportPreview {
        let source = try Self.openNoopSource(url)
        return try Self.readNoop(source) { db in
            let (names, unsupported, ignored) = try Self.validateNoop(db)
            var byDevice: [String: [String: Int]] = [:]
            for table in noopTables where names.contains(table.name) {
                let rows = try Row.fetchAll(db, sql: "SELECT deviceId, COUNT(*) AS n FROM \(table.name) GROUP BY deviceId")
                for row in rows {
                    guard let id: String = row["deviceId"], !id.isEmpty else { throw NoopImportError.invalidDevice }
                    byDevice[id, default: [:]][table.name] = row["n"]
                }
            }
            return NoopImportPreview(devices: byDevice.keys.sorted().map { NoopImportDevice(id: $0, counts: byDevice[$0]!) }, unsupportedTables: unsupported, ignoredColumns: ignored)
        }
    }

    /// Merge one explicitly chosen device into Loop. The source is read-only and every
    /// destination write belongs to a single transaction: an error rolls the import back.
    /// Rows which collide with existing natural keys are counted and never overwrite data.
    public func importNoopDatabase(at url: URL, sourceDeviceId: String, targetDeviceId: String, onProgress: (@Sendable (NoopImportProgress) -> Void)? = nil) async throws -> NoopImportReport {
        try Task.checkCancellation()
        onProgress?(NoopImportProgress(phase: .validating, table: nil, processed: 0, inserted: 0, skipped: 0))
        guard !sourceDeviceId.isEmpty, !targetDeviceId.isEmpty else { throw NoopImportError.invalidDevice }
        if let path = databasePath,
           URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath() == url.standardizedFileURL.resolvingSymlinksInPath() {
            throw NoopImportError.sameDatabase
        }
        let source = try Self.openNoopSource(url)
        return try Self.readNoop(source) { src in
            let (names, unsupported, ignored) = try Self.validateNoop(src)
            var hasDevice = false
            for table in noopTables where names.contains(table.name) {
                if (try Int.fetchOne(src, sql: "SELECT EXISTS(SELECT 1 FROM \(table.name) WHERE deviceId = ?)", arguments: [sourceDeviceId]) ?? 0) != 0 {
                    hasDevice = true; break
                }
            }
            guard hasDevice else { throw NoopImportError.invalidDevice }
            var earliest: Int?, latest: Int?
            for table in noopTables where names.contains(table.name) && table.name != "rawBatch" {
                if let row = try Row.fetchOne(src, sql: "SELECT MIN(ts) AS lo, MAX(ts) AS hi FROM \(table.name) WHERE deviceId = ? AND ts > 0", arguments: [sourceDeviceId]) {
                    if let lo: Int = row["lo"] { earliest = min(earliest ?? lo, lo) }
                    if let hi: Int = row["hi"] { latest = max(latest ?? hi, hi) }
                }
            }
            let report = try syncWrite { dest in
                var counts: [String: NoopImportCount] = [:]
                for table in noopTables where names.contains(table.name) {
                    try Task.checkCancellation()
                    var inserted = 0, total = 0
                    onProgress?(NoopImportProgress(phase: .importing, table: table.name, processed: 0, inserted: 0, skipped: 0))
                    if table.name == "rawBatch" {
                        // Check SQLite length before materializing the blob or allocating decompression buffers.
                        let oversized = try Int.fetchOne(src, sql: "SELECT COUNT(*) FROM rawBatch WHERE deviceId = ? AND (typeof(framesBlob) != 'blob' OR typeof(frameCount) != 'integer' OR frameCount < 0 OR length(framesBlob) > ? OR length(framesBlob) < 5)", arguments: [sourceDeviceId, 64 * 1024 * 1024]) ?? 0
                        guard oversized == 0 else { throw NoopImportError.invalidRawBatch }
                        let rows = try Row.fetchCursor(src, sql: "SELECT \(table.columns.joined(separator: ", ")) FROM rawBatch WHERE deviceId = ?", arguments: [sourceDeviceId])
                        while let row = try rows.next() {
                            total += 1
                            guard let blob: Data = row["framesBlob"],
                                  let frameCount: Int = row["frameCount"], blob.count >= 5 else { throw NoopImportError.invalidRawBatch }
                            let length = Int(blob[0]) | (Int(blob[1]) << 8) | (Int(blob[2]) << 16) | (Int(blob[3]) << 24)
                            guard length >= 4, length <= 64 * 1024 * 1024 else { throw NoopImportError.invalidRawBatch }
                            let unpacked = try Self.zlibDecompressWithLength(blob)
                            guard Self.isValidNoopFrames(unpacked, expectedCount: frameCount) else { throw NoopImportError.invalidRawBatch }
                            // Keep imported raw batches out of pruning and make repeat imports idempotent.
                            var hash = SHA256()
                            hash.update(data: Data(targetDeviceId.utf8))
                            hash.update(data: Data([0]))
                            for value in Array(row.databaseValues).dropFirst().dropLast() {
                                hash.update(data: Data(String(describing: value).utf8))
                                hash.update(data: Data([0]))
                            }
                            hash.update(data: blob)
                            let id = "hist-noop-" + hash.finalize().map { String(format: "%02x", $0) }.joined()
                            let vals = Array(row.databaseValues)
                            var args: [DatabaseValue] = [id.databaseValue, targetDeviceId.databaseValue]
                            args.append(contentsOf: vals.dropFirst())
                            try dest.execute(sql: "INSERT INTO rawBatch (batchId, deviceId, capturedAt, deviceClockRef, wallClockRef, startTs, endTs, frameCount, byteSize, framesBlob, syncedAt) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL) ON CONFLICT(batchId) DO NOTHING", arguments: StatementArguments(args))
                            inserted += dest.changesCount
                            if total % 256 == 0 {
                                try Task.checkCancellation()
                                onProgress?(NoopImportProgress(phase: .importing, table: table.name, processed: total, inserted: inserted, skipped: total - inserted))
                            }
                        }
                    } else {
                        var columns = table.columns
                        if table.name == "battery", try src.columns(in: table.name).contains(where: { $0.name == "charging" }) {
                            columns.append("charging")
                        }
                        let sourceColumns = columns.joined(separator: ", ")
                        let cursor = try Row.fetchCursor(src, sql: "SELECT \(sourceColumns) FROM \(table.name) WHERE deviceId = ?", arguments: [sourceDeviceId])
                        let placeholders = Array(repeating: "?", count: columns.count + 1).joined(separator: ", ")
                        let sql = "INSERT INTO \(table.name) (deviceId, \(sourceColumns)) VALUES (\(placeholders)) ON CONFLICT DO NOTHING"
                        while let row = try cursor.next() {
                            total += 1
                            var values: [DatabaseValue] = [targetDeviceId.databaseValue]
                            values.append(contentsOf: row.databaseValues)
                            try dest.execute(sql: sql, arguments: StatementArguments(values))
                            inserted += dest.changesCount
                            if total % 256 == 0 {
                                try Task.checkCancellation()
                                onProgress?(NoopImportProgress(phase: .importing, table: table.name, processed: total, inserted: inserted, skipped: total - inserted))
                            }
                        }
                    }
                    counts[table.name] = NoopImportCount(inserted: inserted, skipped: total - inserted)
                    onProgress?(NoopImportProgress(phase: .importing, table: table.name, processed: total, inserted: inserted, skipped: total - inserted))
                }
                try Task.checkCancellation()
                return NoopImportReport(counts: counts, unsupportedTables: unsupported, ignoredColumns: ignored, earliestTimestamp: earliest, latestTimestamp: latest)
            }
            onProgress?(NoopImportProgress(phase: .committed, table: nil, processed: 0, inserted: 0, skipped: 0))
            return report
        }
    }

    private static func isValidNoopFrames(_ data: Data, expectedCount: Int) -> Bool {
        let bytes = [UInt8](data)
        var offset = 0
        func readLength() -> Int? {
            guard offset <= bytes.count - 4 else { return nil }
            let n = Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
            offset += 4
            return n
        }
        guard let count = readLength(), count == expectedCount, count <= (bytes.count - 4) / 4 else { return false }
        for _ in 0..<count {
            guard let n = readLength(), n <= bytes.count - offset else { return false }
            offset += n
        }
        return offset == bytes.count
    }
}
