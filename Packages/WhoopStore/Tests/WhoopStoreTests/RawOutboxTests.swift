import XCTest
import WhoopProtocol
@testable import WhoopStore

final class RawOutboxTests: XCTestCase {
    private let frames: [[UInt8]] = [
        [0xAA, 0x18, 0x00, 0xFF, 0x28, 0x02, 0x0F, 0x01, 0x02, 0x03],
        [0xAA, 0x0C, 0x00, 0xFC, 0x24, 0x24, 0x03, 0x0A],
        [],                                   // empty frame must survive the round-trip
    ]
    private func meta(_ id: String, capturedAt: Int = 5000, synced: Bool = false) -> RawBatchMeta {
        RawBatchMeta(batchId: id, deviceId: "dev1",
                     clockRef: ClockRef(device: 31538447, wall: 1736365593),
                     capturedAt: capturedAt, startTs: 1736365593, endTs: 1736365600,
                     frameCount: frames.count, byteSize: frames.reduce(0) { $0 + $1.count })
    }

    func testEnqueueThenRawFramesRoundTrips() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        try await store.enqueueRawBatch(meta("b1"), frames: frames)
        let got = try await store.rawFrames(batchId: "b1")
        XCTAssertEqual(got, frames)
    }

    func testRawFramesUnknownBatchIsEmpty() async throws {
        let store = try await WhoopStore.inMemory()
        let got = try await store.rawFrames(batchId: "nope")
        XCTAssertEqual(got, [])
    }

    func testPendingExcludesSyncedAndRespectsLimitAndOrder() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        try await store.enqueueRawBatch(meta("old", capturedAt: 100), frames: frames)
        try await store.enqueueRawBatch(meta("mid", capturedAt: 200), frames: frames)
        try await store.enqueueRawBatch(meta("new", capturedAt: 300), frames: frames)
        try await store.markRawBatchSynced(batchId: "mid", at: 999)

        let pending = try await store.pendingRawBatches(limit: 10)
        XCTAssertEqual(pending.map { $0.batchId }, ["old", "new"])   // mid synced; oldest first

        let limited = try await store.pendingRawBatches(limit: 1)
        XCTAssertEqual(limited.map { $0.batchId }, ["old"])
    }

    func testMetaRoundTripsThroughPending() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        let m = meta("b1")
        try await store.enqueueRawBatch(m, frames: frames)
        let pending = try await store.pendingRawBatches(limit: 10)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0], m)
    }

    func testRoundTripLargeBatch() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        // 200 frames x 24 bytes → packed >> (byteSize + 256) hint; exercises the truncation path.
        let manyFrames = (0..<200).map { i in [UInt8](repeating: UInt8(i & 0xFF), count: 24) }
        let byteSize = manyFrames.reduce(0) { $0 + $1.count }
        let m = RawBatchMeta(batchId: "big", deviceId: "dev1",
                             clockRef: ClockRef(device: 0, wall: 0),
                             capturedAt: 1, startTs: 0, endTs: 0,
                             frameCount: manyFrames.count, byteSize: byteSize)
        try await store.enqueueRawBatch(m, frames: manyFrames)
        let gotLarge = try await store.rawFrames(batchId: "big")
        XCTAssertEqual(gotLarge, manyFrames)
    }

    func testRoundTripHighlyCompressibleBatch() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        // All-zero frames compress to a tiny blob but decompress LARGE — the worst case for
        // any fixed-size decode buffer heuristic.
        let zeros = (0..<300).map { _ in [UInt8](repeating: 0, count: 64) }
        let byteSize = zeros.reduce(0) { $0 + $1.count }
        let m = RawBatchMeta(batchId: "z", deviceId: "dev1",
                             clockRef: ClockRef(device: 0, wall: 0),
                             capturedAt: 1, startTs: 0, endTs: 0,
                             frameCount: zeros.count, byteSize: byteSize)
        try await store.enqueueRawBatch(m, frames: zeros)
        let gotZeros = try await store.rawFrames(batchId: "z")
        XCTAssertEqual(gotZeros, zeros)
    }
    func testHistoricalArchiveLimitPreservesExistingAndAllowsReplay() async throws {
        let store = try await WhoopStore.inMemory()
        let first = meta("hist-dev1-first")
        try await store.enqueueHistoricalRawBatch(first, frames: frames, maxBytes: 10_000)
        // A replay succeeds even when the archive limit has since been reached.
        try await store.enqueueHistoricalRawBatch(first, frames: frames, maxBytes: 0)
        do {
            try await store.enqueueHistoricalRawBatch(meta("hist-dev1-second"), frames: frames, maxBytes: 0)
            XCTFail("Expected storage limit to stop the offload")
        } catch WhoopStore.HistoricalRawError.storageLimitReached { }
        let retained = try await store.rawFrames(batchId: first.batchId)
        XCTAssertEqual(retained, frames)
        let ids = try await store.allBatchIdsForTest()
        XCTAssertEqual(ids, [first.batchId])
    }

    func testCommitHistoricalChunkPersistsStreamsRawAndCursorAtomically() async throws {
        let store = try await WhoopStore.inMemory()
        let batch = meta("hist-dev1-chunk")
        let chunk = WhoopStore.HistoricalChunk(
            streams: Streams(hr: [HRSample(ts: 1_700_000_000, bpm: 60)]),
            meta: batch, frames: frames, maxBytes: Int.max)
        try await store.commitHistoricalChunk(chunk, cursor: "strap_trim", value: 42)
        try await store.commitHistoricalChunk(chunk, cursor: "strap_trim", value: 42) // replay is idempotent
        let rawFrames = try await store.rawFrames(batchId: batch.batchId)
        XCTAssertEqual(rawFrames, frames)
        let stats = try await store.storageStats_rowCountsForTest()
        XCTAssertEqual(stats.hr, 1)
        let cursor = try await store.cursor("strap_trim")
        XCTAssertEqual(cursor, 42)
        // An END with no records only advances the cursor.
        try await store.commitHistoricalChunk(nil, cursor: "strap_trim", value: 43)
        let advanced = try await store.cursor("strap_trim")
        XCTAssertEqual(advanced, 43)
    }

    func testCommitHistoricalChunkRollsBackEverythingWhenArchiveFull() async throws {
        let store = try await WhoopStore.inMemory()
        let chunk = WhoopStore.HistoricalChunk(
            streams: Streams(hr: [HRSample(ts: 1_700_000_000, bpm: 60)]),
            meta: meta("hist-dev1-full"), frames: frames, maxBytes: 0)
        do {
            try await store.commitHistoricalChunk(chunk, cursor: "strap_trim", value: 7)
            XCTFail("Expected storage limit")
        } catch WhoopStore.HistoricalRawError.storageLimitReached { }
        let stats = try await store.storageStats_rowCountsForTest()
        XCTAssertEqual(stats.hr, 0)
        let cursor = try await store.cursor("strap_trim")
        XCTAssertNil(cursor)
    }

    func testPruneDoesNotDeleteHistoricalArchiveEvenIfMarkedSynced() async throws {
        let store = try await WhoopStore.inMemory()
        let batch = meta("hist-dev1-kept")
        try await store.enqueueHistoricalRawBatch(batch, frames: frames, maxBytes: 10_000)
        try await store.markRawBatchSynced(batchId: batch.batchId, at: 1)
        _ = try await store.pruneRaw(now: 10_000, keepWindowSeconds: 1, maxUnsyncedBytes: 0)
        let retained = try await store.rawFrames(batchId: batch.batchId)
        XCTAssertEqual(retained, frames)
    }

}
