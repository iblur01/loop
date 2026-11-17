import Foundation
import CryptoKit
import WhoopProtocol
import WhoopStore

// MARK: - BackfillStoreWriting protocol

/// The async subset the Backfiller needs. Plain async protocol (not @MainActor) so both the
/// real WhoopStore actor and a @MainActor SpyBackfillStore in tests can satisfy it.
protocol BackfillStoreWriting: AnyObject {
    @discardableResult
    func insert(_ streams: Streams, deviceId: String) async throws
        -> (hr: Int, rr: Int, events: Int, battery: Int,
            spo2: Int, skinTemp: Int, resp: Int, gravity: Int)
    func enqueueHistoricalRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]], maxBytes: Int) async throws
    func setCursor(_ name: String, _ value: Int) async throws
    func cursor(_ name: String) async throws -> Int?
    /// Persist decoded + raw + trim cursor for one chunk. `WhoopStore` does this in ONE transaction;
    /// the default below (used by test doubles) falls back to the three separate calls.
    func commitHistoricalChunk(_ chunk: WhoopStore.HistoricalChunk?, cursor: String, value: Int) async throws
}

extension BackfillStoreWriting {
    func commitHistoricalChunk(_ chunk: WhoopStore.HistoricalChunk?, cursor: String, value: Int) async throws {
        if let chunk {
            try await insert(chunk.streams, deviceId: chunk.meta.deviceId)
            try await enqueueHistoricalRawBatch(chunk.meta, frames: chunk.frames, maxBytes: chunk.maxBytes)
        }
        try await setCursor(cursor, value)
    }
}

extension WhoopStore: BackfillStoreWriting {}

// MARK: - Backfiller

/// Historical-offload state machine (idle / backfilling).
///
/// Per-chunk local safe-trim invariant:
///   decode (off-main) → ONE transaction {insert decoded + enqueue raw + setCursor(strap_trim)} →
///   ackTrim (link-layer confirmed ack to strap)
///
/// A chunk is forgotten only after decoded AND raw are both locally durable AND the ack
/// (.withResponse) is link-layer confirmed. Never waits on the server.
@MainActor
final class Backfiller {
    typealias Extractor = ([ParsedFrame], Int, Int) -> Streams
    /// Keep space for iOS, SQLite WAL and the rest of the app. The archive itself is
    /// never pruned: its growth is bounded by the device's available storage.
    static let storageReserveBytes: Int64 = 1_073_741_824
    static let minimumRetryHeadroomBytes: Int64 = 134_217_728

    static func availableStorageBytes() -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
              let free = attributes[.systemFreeSize] as? NSNumber else { return nil }
        return free.int64Value
    }

    static func requiredFreeBytes(frameBytes: Int) -> Int64 {
        let size = Int64(clamping: max(0, frameBytes))
        let (scaled, overflow) = size.multipliedReportingOverflow(by: 3)
        let headroom = max(minimumRetryHeadroomBytes, overflow ? Int64.max : scaled)
        let (required, sumOverflow) = storageReserveBytes.addingReportingOverflow(headroom)
        return sumOverflow ? Int64.max : required
    }

    private let store: BackfillStoreWriting
    /// Device id rows are inserted under. Mutable — see Collector.deviceId for why (must stay aligned
    /// with the upload config's deviceId or backfilled rows never drain).
    var deviceId: String
    /// Confirms one HISTORY_END chunk to the strap. Carries both the trim cursor (= first u32
    /// of end_data, used for the `strap_trim` cursor) and the 8-byte `end_data` (= the raw
    /// HISTORY_END metadata.data[10:18]) that the high-freq-sync ack form requires verbatim.
    private let ackTrim: (_ trim: UInt32, _ endData: [UInt8]) -> Void
    private let extract: Extractor

    /// The clock reference set by the connection manager when GET_CLOCK confirms (required for decoding).
    var clockRef: ClockRef?

    /// True while a historical offload session is active.
    private(set) var isBackfilling = false
    private(set) var failureReason: String?
    private(set) var archiveLimitReached = false
    private(set) var archiveRequiredFreeBytes: Int64 = 0
    private var sessionGeneration = 0
    /// Per-session diagnostics, reset by `begin()`: HISTORY_END chunks seen vs. chunks acked. The
    /// offload log reports both at session end so "strap silent" (0 ends), "commit never returned"
    /// (ends > acks) and "strap stopped after our ack" (ends == acks) can be told apart on-device.
    private(set) var sessionEndCount = 0
    private(set) var sessionAckCount = 0

    /// Buffered data frames for the current open chunk (between START and END).
    private var chunk: [[UInt8]] = []
    /// Whether a START has been received and we're accumulating a chunk.
    private var chunkOpen = false

    init(store: BackfillStoreWriting,
         deviceId: String,
         ackTrim: @escaping (_ trim: UInt32, _ endData: [UInt8]) -> Void,
         enableRawCapture: Bool = false,
         extract: @escaping Extractor = { extractHistoricalStreams($0, deviceClockRef: $1, wallClockRef: $2) }) {
        self.store = store
        self.deviceId = deviceId
        self.ackTrim = ackTrim
        // Historical raw capture is mandatory: decoded streams do not cover every record.
        _ = enableRawCapture // retained for source compatibility
        self.extract = extract
    }

    /// Called by the offload coordinator when the strap signals a historical offload is beginning.
    /// chunkOpen starts TRUE: the high-freq-sync biometric replay streams records immediately and
    /// sends one HISTORY_START then repeated HISTORY_ENDs, so we must accumulate from the outset.
    func begin() {
        sessionGeneration &+= 1
        failureReason = nil
        archiveLimitReached = false
        archiveRequiredFreeBytes = 0
        sessionEndCount = 0
        sessionAckCount = 0
        isBackfilling = true
        chunk.removeAll(keepingCapacity: true)
        chunkOpen = true
    }

    /// Feed one raw BLE frame into the state machine. May trigger async store operations.
    func ingest(_ frame: [UInt8]) async {
        guard isBackfilling, failureReason == nil else { return }
        guard verifyFrame(frame).ok else {
            fail("Invalid historical frame")
            return
        }
        // Only METADATA (type 49) frames need a full parse to be classified; data frames are parsed
        // once, off the main actor, when their chunk is committed.
        let meta: HistoricalMeta = (frame.count > 4 && frame[4] == 49)
            ? classifyHistoricalMeta(parseFrame(frame)) : .other
        switch meta {
        case .start:
            isBackfilling = true
            chunk.removeAll(keepingCapacity: true)
            chunkOpen = true
        case .end(let unix, let trim):
            sessionEndCount += 1
            await finishChunk(unix: unix, trim: trim, endFrame: frame)
        case .complete:
            isBackfilling = false
            chunk.removeAll(keepingCapacity: true)
            chunkOpen = false
        case .other:
            if chunkOpen { chunk.append(frame) }
        }
    }

    /// The 8-byte `end_data` the high-freq-sync ack requires: metadata.data[10:18].
    /// metadata.data begins at frame[7] (after [type,seq,cmd]), so end_data = frame[17:25].
    /// trim cursor = the first u32 of end_data (data[10:14]). Returns nil if the frame is too
    /// short to contain the field (shouldn't happen for a real HISTORY_END, which is >=14 data
    /// bytes, but guards against a malformed frame).
    static func endData(from frame: [UInt8]) -> [UInt8]? {
        guard frame.count >= 25 else { return nil }
        return Array(frame[17..<25])
    }

    /// Commit one HISTORY_END chunk: (persist decoded → enqueueRaw when present) → setCursor → ackTrim.
    /// Early-returns on any throw to preserve the safe-trim invariant.
    ///
    /// CRITICAL: high-freq-sync sends ONE HISTORY_START then REPEATED HISTORY_ENDs (a chunk-close
    /// every ~50 records). So we must ack EVERY end and keep accumulating afterwards — NOT close
    /// the chunk after the first. We snapshot+clear the accumulated frames but leave `chunkOpen`
    /// TRUE so the records following this END become the next chunk. An END with no accumulated
    /// records is still acked (it advances the strap's trim) — that's how the offload progresses.
    /// `endFrame` carries the 8-byte `end_data` the ack requires.
    private func finishChunk(unix: UInt32, trim: UInt32, endFrame: [UInt8]) async {
        guard let endData = Backfiller.endData(from: endFrame) else {
            fail("Malformed HISTORY_END")
            return
        }

        let generation = sessionGeneration
        let frames = chunk
        chunk.removeAll(keepingCapacity: true)   // next records accumulate into the next chunk

        var commit: WhoopStore.HistoricalChunk?
        if !frames.isEmpty {
            let frameBytes = frames.reduce(0) { partial, frame in
                let (sum, overflow) = partial.addingReportingOverflow(frame.count)
                return overflow ? Int.max : sum
            }
            let required = Self.requiredFreeBytes(frameBytes: frameBytes)
            if let failure = checkStorage(required: required) {
                fail(failure)
                return
            }
            // type-47 HISTORICAL_DATA carries its OWN real-unix timestamp — extractHistoricalStreams
            // ignores the clock offset for it — so the historical offload does NOT need GET_CLOCK.
            // If the (device,wall) correlation isn't established yet (e.g. GET_CLOCK silent), fall back
            // to an identity ref (device==wall==now): the offset math becomes a no-op, type-47 still
            // decodes to correct wall time, and we can persist + ack. The correlation is only
            // truly required to map REALTIME (type-40/43) device-epoch timestamps, never in a hist chunk.
            let ref = clockRef ?? { let now = Int(Date().timeIntervalSince1970); return ClockRef(device: now, wall: now) }()
            // Decode + hash happen off the main actor (cooperative pool); the main actor only awaits.
            commit = await Self.prepareChunk(frames: frames, ref: ref, deviceId: deviceId,
                                             trim: trim, extract: extract)
            guard isBackfilling, sessionGeneration == generation else { return }
        }

        // One transaction: decoded streams + raw batch + strap_trim cursor.
        do { try await store.commitHistoricalChunk(commit, cursor: "strap_trim", value: Int(trim)) } catch {
            guard isBackfilling, sessionGeneration == generation else { return }
            if let rawError = error as? WhoopStore.HistoricalRawError, case .storageLimitReached = rawError {
                archiveLimitReached = true
                archiveRequiredFreeBytes = Self.requiredFreeBytes(frameBytes: frames.reduce(0) { $0 + $1.count })
                fail(Self.storageFullMessage)
                return
            }
            fail("Échec de sauvegarde des données historiques : \(error.localizedDescription)")
            return
        }

        guard isBackfilling, sessionGeneration == generation else { return }
        sessionAckCount += 1
        ackTrim(trim, endData)
    }

    private static let storageFullMessage = "Espace insuffisant sur l’iPhone : libère de l’espace pour reprendre la synchronisation sans perdre les données du bracelet."

    /// Free-space probe is a filesystem syscall; throttle it to once per 10 s instead of once per chunk.
    /// Returns a failure message when there is not enough room, nil otherwise.
    private func checkStorage(required: Int64) -> String? {
        let now = Date()
        if let last = lastStorageCheckAt, now.timeIntervalSince(last) < 10, let free = lastFreeBytes, free >= required {
            return nil
        }
        guard let free = Self.availableStorageBytes(), free >= required else {
            archiveLimitReached = true
            archiveRequiredFreeBytes = required
            return Self.storageFullMessage
        }
        lastStorageCheckAt = now
        lastFreeBytes = free
        return nil
    }

    private var lastStorageCheckAt: Date?
    private var lastFreeBytes: Int64?

    /// CPU-bound chunk preparation (frame parse, stream extraction, SHA-256 batch id). Not actor
    /// isolated, so it runs on the global executor rather than the main actor.
    private nonisolated static func prepareChunk(frames: [[UInt8]], ref: ClockRef, deviceId: String,
                                                 trim: UInt32, extract: Extractor) async -> WhoopStore.HistoricalChunk {
        let parsed = frames.map { parseFrame($0) }
        let decoded = extract(parsed, ref.device, ref.wall)
        var digest = SHA256()
        var byteSize = 0
        for frame in frames {
            var size = UInt64(frame.count).littleEndian
            withUnsafeBytes(of: &size) { digest.update(data: Data($0)) }
            digest.update(data: Data(frame))
            byteSize += frame.count
        }
        let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        let meta = RawBatchMeta(
            batchId: "hist-\(deviceId)-\(trim)-\(hash)",
            deviceId: deviceId,
            clockRef: ref,
            capturedAt: Int(Date().timeIntervalSince1970),
            startTs: ref.wall,
            endTs: ref.wall,
            frameCount: frames.count,
            byteSize: byteSize)
        return WhoopStore.HistoricalChunk(streams: decoded, meta: meta, frames: frames, maxBytes: Int.max)
    }

    private func fail(_ reason: String) {
        sessionGeneration &+= 1
        failureReason = reason
        isBackfilling = false
        chunkOpen = false
        chunk.removeAll(keepingCapacity: true)
    }

    /// Called when a backfill watchdog timer fires (strap went silent mid-offload).
    /// Clears state without acking — the chunk was never durably committed.
    func timeoutFired() {
        sessionGeneration &+= 1
        isBackfilling = false
        chunk.removeAll(keepingCapacity: true)
        chunkOpen = false
    }
}
