import Foundation
import Compression
import GRDB
import WhoopProtocol

public struct ClockRef: Equatable, Codable {
    public let device: Int
    public let wall: Int
    public init(device: Int, wall: Int) { self.device = device; self.wall = wall }
}

public struct RawBatchMeta: Equatable {
    public let batchId: String
    public let deviceId: String
    public let clockRef: ClockRef
    public let capturedAt: Int
    public let startTs: Int
    public let endTs: Int
    public let frameCount: Int
    public let byteSize: Int
    public init(batchId: String, deviceId: String, clockRef: ClockRef, capturedAt: Int,
                startTs: Int, endTs: Int, frameCount: Int, byteSize: Int) {
        self.batchId = batchId; self.deviceId = deviceId; self.clockRef = clockRef
        self.capturedAt = capturedAt; self.startTs = startTs; self.endTs = endTs
        self.frameCount = frameCount; self.byteSize = byteSize
    }
}

extension WhoopStore {
    // MARK: - frame (de)serialization
    // Layout: [count u32 LE]{ [len u32 LE][bytes] } x count. zlib-compressed as a whole.

    static func packFrames(_ frames: [[UInt8]]) -> Data {
        var buf = Data()
        func appendU32(_ v: Int) {
            let u = UInt32(v)
            buf.append(UInt8(u & 0xFF)); buf.append(UInt8((u >> 8) & 0xFF))
            buf.append(UInt8((u >> 16) & 0xFF)); buf.append(UInt8((u >> 24) & 0xFF))
        }
        appendU32(frames.count)
        for f in frames {
            appendU32(f.count)
            buf.append(contentsOf: f)
        }
        return buf
    }

    static func unpackFrames(_ data: Data) -> [[UInt8]] {
        let bytes = [UInt8](data)
        var off = 0
        func readU32() -> Int? {
            guard off + 4 <= bytes.count else { return nil }
            let v = Int(bytes[off]) | (Int(bytes[off + 1]) << 8)
                | (Int(bytes[off + 2]) << 16) | (Int(bytes[off + 3]) << 24)
            off += 4
            return v
        }
        guard let count = readU32() else { return [] }
        var out: [[UInt8]] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            guard let len = readU32(), off + len <= bytes.count else { break }
            out.append(Array(bytes[off..<off + len]))
            off += len
        }
        return out
    }

    // MARK: - zlib helpers using Apple Compression framework

    /// Decompress a blob that was produced by `zlibCompressWithLength`.
    /// The first 4 bytes are the uncompressed length (UInt32 LE); the rest is the zlib payload.
    static func zlibDecompressWithLength(_ input: Data) throws -> Data {
        // Read the 4-byte uncompressed-length prefix (UInt32 LE).
        guard input.count >= 4 else { throw CocoaError(.fileReadUnknown) }
        let n = Int(input[input.startIndex])
            | (Int(input[input.startIndex + 1]) << 8)
            | (Int(input[input.startIndex + 2]) << 16)
            | (Int(input[input.startIndex + 3]) << 24)
        let compressed = input.dropFirst(4)
        // n == 0 means packFrames returned empty data; return empty.
        guard n > 0 else { return Data() }
        var dst = [UInt8](repeating: 0, count: n)
        let written: Int = compressed.withUnsafeBytes { src in
            guard let srcPtr = src.baseAddress else { return 0 }
            return compression_decode_buffer(&dst, n, srcPtr, compressed.count, nil, COMPRESSION_ZLIB)
        }
        // If written != n the blob is genuinely corrupt (not a sizing issue).
        guard written == n else { throw CocoaError(.fileReadCorruptFile) }
        return Data(dst)
    }

    /// Compress `input` and prepend its uncompressed length as a UInt32 LE prefix.
    static func zlibCompressWithLength(_ input: Data) throws -> Data {
        let sourceSize = input.count
        let dstCapacity = max(64, sourceSize * 2 + 64)
        var dst = [UInt8](repeating: 0, count: dstCapacity)
        let written: Int = input.withUnsafeBytes { src in
            guard let srcPtr = src.baseAddress else { return 0 }
            return compression_encode_buffer(&dst, dstCapacity, srcPtr, sourceSize, nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { throw CocoaError(.fileWriteUnknown) }
        // Prepend uncompressed length as UInt32 LE.
        let u = UInt32(sourceSize)
        var blob = Data(capacity: 4 + written)
        blob.append(UInt8(u & 0xFF)); blob.append(UInt8((u >> 8) & 0xFF))
        blob.append(UInt8((u >> 16) & 0xFF)); blob.append(UInt8((u >> 24) & 0xFF))
        blob.append(contentsOf: dst[0..<written])
        return blob
    }

    // MARK: - Public API

    /// Compress raw frames into the outbox and store batch meta.
    public func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws {
        let packed = WhoopStore.packFrames(frames)
        let blob = try WhoopStore.zlibCompressWithLength(packed)
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO rawBatch
                    (batchId, deviceId, capturedAt, deviceClockRef, wallClockRef,
                     startTs, endTs, frameCount, byteSize, framesBlob, syncedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
                ON CONFLICT(batchId) DO NOTHING
                """, arguments: [
                    meta.batchId, meta.deviceId, meta.capturedAt,
                    meta.clockRef.device, meta.clockRef.wall,
                    meta.startTs, meta.endTs, meta.frameCount, meta.byteSize, blob])
        }
    }

    public enum HistoricalRawError: Error {
        case storageLimitReached
    }

    /// Store historical raw data and enforce the archive limit in the same transaction.
    /// A replay of an already stored batch is accepted even when the archive is full.
    public func enqueueHistoricalRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]], maxBytes: Int) async throws {
        let blob = try WhoopStore.zlibCompressWithLength(WhoopStore.packFrames(frames))
        try syncWrite { db in
            try WhoopStore.insertHistoricalRaw(db, meta, blob: blob, maxBytes: maxBytes)
        }
    }

    /// Transaction-local body shared by `enqueueHistoricalRawBatch` and `commitHistoricalChunk`.
    /// The archive-size scan only runs when a finite limit is requested: with `Int.max` it can never
    /// trigger, and the `SUM(LENGTH(...)) ... LIKE 'hist-%'` full-table scan grows with every chunk.
    static func insertHistoricalRaw(_ db: Database, _ meta: RawBatchMeta, blob: Data, maxBytes: Int) throws {
        let existing = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rawBatch WHERE batchId = ?", arguments: [meta.batchId]) ?? 0
        if existing > 0 { return }
        if maxBytes != Int.max {
            let total = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(LENGTH(framesBlob)), 0) FROM rawBatch WHERE batchId LIKE 'hist-%'") ?? 0
            guard blob.count <= maxBytes, total <= maxBytes - blob.count else {
                throw HistoricalRawError.storageLimitReached
            }
        }
        try db.cachedStatement(sql: """
            INSERT INTO rawBatch
                (batchId, deviceId, capturedAt, deviceClockRef, wallClockRef,
                 startTs, endTs, frameCount, byteSize, framesBlob, syncedAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
            """).execute(arguments: [meta.batchId, meta.deviceId, meta.capturedAt,
                meta.clockRef.device, meta.clockRef.wall, meta.startTs, meta.endTs,
                meta.frameCount, meta.byteSize, blob])
    }

    /// Everything one HISTORY_END chunk persists: decoded streams + raw frames.
    public struct HistoricalChunk {
        public let streams: Streams
        public let meta: RawBatchMeta
        public let frames: [[UInt8]]
        public let maxBytes: Int
        public init(streams: Streams, meta: RawBatchMeta, frames: [[UInt8]], maxBytes: Int) {
            self.streams = streams; self.meta = meta; self.frames = frames; self.maxBytes = maxBytes
        }
    }

    /// Atomically persist one chunk: decoded streams + raw batch + trim cursor in ONE transaction
    /// (one WAL commit instead of three). Either all three are durable or none are, which is exactly
    /// the safe-trim invariant required before acking the strap. `chunk` is nil for an END that
    /// carried no records (only the cursor advances). Compression runs before the write lock is taken.
    public func commitHistoricalChunk(_ chunk: HistoricalChunk?, cursor: String, value: Int) async throws {
        let blob = try chunk.map { try WhoopStore.zlibCompressWithLength(WhoopStore.packFrames($0.frames)) }
        try syncWrite { db in
            if let chunk, let blob {
                try WhoopStore.insertStreams(db, chunk.streams, deviceId: chunk.meta.deviceId, synced: 0)
                try WhoopStore.insertHistoricalRaw(db, chunk.meta, blob: blob, maxBytes: chunk.maxBytes)
            }
            try db.cachedStatement(sql: """
                INSERT INTO cursors (name, value) VALUES (?, ?)
                ON CONFLICT(name) DO UPDATE SET value = excluded.value
                """).execute(arguments: [cursor, value])
        }
    }

    /// Decompress and return the exact frame bytes for a batch (empty if unknown).
    public func rawFrames(batchId: String) async throws -> [[UInt8]] {
        let row: Row? = try syncRead { db in
            try Row.fetchOne(db,
                sql: "SELECT framesBlob FROM rawBatch WHERE batchId = ?",
                arguments: [batchId])
        }
        guard let row = row else { return [] }
        let blob: Data = row["framesBlob"]
        let raw = try WhoopStore.zlibDecompressWithLength(blob)
        return WhoopStore.unpackFrames(raw)
    }

    private static func metaFromRow(_ row: Row) -> RawBatchMeta {
        RawBatchMeta(
            batchId: row["batchId"], deviceId: row["deviceId"],
            clockRef: ClockRef(device: row["deviceClockRef"], wall: row["wallClockRef"]),
            capturedAt: row["capturedAt"], startTs: row["startTs"], endTs: row["endTs"],
            frameCount: row["frameCount"], byteSize: row["byteSize"])
    }

    /// Un-synced batches (syncedAt IS NULL), oldest first, capped at `limit`.
    public func pendingRawBatches(limit: Int) async throws -> [RawBatchMeta] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT batchId, deviceId, capturedAt, deviceClockRef, wallClockRef,
                       startTs, endTs, frameCount, byteSize
                FROM rawBatch
                WHERE syncedAt IS NULL
                ORDER BY capturedAt ASC
                LIMIT ?
                """, arguments: [limit]).map(WhoopStore.metaFromRow)
        }
    }

    /// Mark a batch synced (timestamp in unix seconds).
    public func markRawBatchSynced(batchId: String, at: Int) async throws {
        try syncWrite { db in
            try db.execute(sql: "UPDATE rawBatch SET syncedAt = ? WHERE batchId = ?",
                           arguments: [at, batchId])
        }
    }
}

extension WhoopStore {
    /// Prune raw outbox rows. Returns the number of rawBatch rows deleted.
    ///
    /// **Policy 1 (only active policy):** Delete SYNCED batches whose `syncedAt` timestamp
    /// is older than `now - keepWindowSeconds`. Synced raw is safe to drop because the
    /// decoded streams are persisted separately.
    ///
    /// Historical batches and unsynced raw are NEVER dropped by this method. Under the offline-first hybrid design
    /// the locally-stored raw is the sole copy of the strap's "unknown" bytes after a chunk
    /// is trimmed; dropping it would cause permanent data loss.
    ///
    /// - Parameters:
    ///   - now: Current unix-second timestamp used to compute the prune cutoff.
    ///   - keepWindowSeconds: Synced batches older than `now - keepWindowSeconds` are removed.
    ///   - maxUnsyncedBytes: Intentionally unused — unsynced raw is the sole copy of unknown
    ///     bytes post-trim and must never be dropped. Parameter kept for call-site compatibility.
    @discardableResult
    public func pruneRaw(now: Int, keepWindowSeconds: Int, maxUnsyncedBytes: Int) async throws -> Int {
        // maxUnsyncedBytes intentionally unused: unsynced raw is the sole copy of unknown bytes
        // post-trim and must never be dropped.
        try syncWrite { db in
            var pruned = 0
            // Policy 1: aged synced batches.
            let cutoff = now - keepWindowSeconds
            try db.execute(sql: """
                DELETE FROM rawBatch WHERE syncedAt IS NOT NULL AND syncedAt < ? AND batchId NOT LIKE 'hist-%'
                """, arguments: [cutoff])
            pruned += db.changesCount
            return pruned
        }
    }

    // MARK: - Test helper
    public func allBatchIdsForTest() async throws -> [String] {
        try syncRead { db in
            try String.fetchAll(db, sql: "SELECT batchId FROM rawBatch ORDER BY capturedAt ASC")
        }
    }
}
