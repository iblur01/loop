import XCTest
import WhoopProtocol
import WhoopStore
@testable import Loop

// MARK: - BackupSnapshotTests
//
// Valide la partie critique et déterministe du backup fichier : la procédure de **snapshot SAFE**
// (checkpoint WAL + copie fichier) produit une copie cohérente et ré-ouvrable du `whoop.sqlite`.
final class BackupSnapshotTests: XCTestCase {

    func testCheckpointThenFileCopyYieldsConsistentSnapshot() async throws {
        let fm = FileManager.default
        let srcPath = NSTemporaryDirectory() + "loop-snap-src-\(UUID().uuidString).sqlite"
        let store = try await WhoopStore(path: srcPath)

        let device = "snap-device"
        try await store.upsertDevice(id: device, mac: nil, name: "Test")
        let rows = (0..<2_000).map { HRSample(ts: 1_700_000_000 + $0, bpm: 60 + ($0 % 40)) }
        try await store.insert(Streams(hr: rows), deviceId: device, markSynced: false)

        let before = try await store.storageStats(deviceId: device).decodedRows
        XCTAssertEqual(before, rows.count)

        // 1. Checkpoint : flush WAL dans le .sqlite principal, vide -wal/-shm.
        try await store.checkpoint()

        // 2. Copie du seul .sqlite (comme le coordinator) vers un nouvel emplacement.
        let dstPath = NSTemporaryDirectory() + "loop-snap-dst-\(UUID().uuidString).sqlite"
        let reportedPath = await store.databasePath
        XCTAssertEqual(reportedPath, srcPath)
        try fm.copyItem(atPath: srcPath, toPath: dstPath)

        // 3. La copie s'ouvre seule et contient toutes les lignes (snapshot cohérent).
        let restored = try await WhoopStore(path: dstPath)
        let after = try await restored.storageStats(deviceId: device).decodedRows
        XCTAssertEqual(after, before, "le snapshot doit contenir toutes les lignes post-checkpoint")

        try? fm.removeItem(atPath: srcPath)
        try? fm.removeItem(atPath: dstPath)
    }

    func testInMemoryStoreHasNoDatabasePath() async throws {
        let store = try await WhoopStore.inMemory()
        let path = await store.databasePath
        XCTAssertNil(path, "un store in-memory n'a pas de fichier à snapshotter")
    }
}

@MainActor
final class BackupSafetyTests: XCTestCase {
    func testRestoreIsRefusedWithoutSuspendingOrReplacingData() async throws {
        var suspended = false
        let coordinator = BackupCoordinator(
            deviceId: "test", store: { nil },
            suspend: { suspended = true }, resume: {}, reloadCache: {}
        )
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try Data("original".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        await coordinator.importBackup(from: file)
        guard case .error = coordinator.status else { return XCTFail("Restore must be refused") }
        XCTAssertFalse(suspended)
        XCTAssertEqual(try Data(contentsOf: file), Data("original".utf8))
    }

    func testSQLiteBackupIncludesCommittedWALRows() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.sqlite")
        let dest = folder.appendingPathComponent("snapshot.sqlite")
        let store = try await WhoopStore(path: source.path)
        try await store.upsertDevice(id: "test", mac: nil, name: nil)
        let samples = (0..<25).map { HRSample(ts: 1_700_000_000 + $0, bpm: 70) }
        try await store.insert(Streams(hr: samples), deviceId: "test", markSynced: false)
        try BackupCoordinator.snapshotDatabase(from: source, to: dest)
        let snapshot = try await WhoopStore(path: dest.path)
        let count = try await snapshot.storageStats(deviceId: "test").decodedRows
        XCTAssertEqual(count, samples.count)
    }
}

private actor BackfillSafetyStore: BackfillStoreWriting {
    enum Failure: Error { case raw }
    var failRaw = false
    var rawFrames: [[UInt8]] = []
    var cursorValue: Int?
    var blockInsert = false
    var insertStarted = false
    var startedWaiter: CheckedContinuation<Void, Never>?
    var insertWaiter: CheckedContinuation<Void, Never>?
    func setBlockInsert() { blockInsert = true }
    func waitForInsert() async {
        if insertStarted { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }
    func unblockInsert() { insertWaiter?.resume(); insertWaiter = nil }
    func setFailRaw() { failRaw = true }
    func insert(_ streams: Streams, deviceId: String) async throws
        -> (hr: Int, rr: Int, events: Int, battery: Int, spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
        if blockInsert {
            insertStarted = true
            startedWaiter?.resume()
            startedWaiter = nil
            await withCheckedContinuation { insertWaiter = $0 }
        }
        return (0, 0, 0, 0, 0, 0, 0, 0)
    }
    func enqueueHistoricalRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]], maxBytes: Int) async throws {
        if failRaw { throw Failure.raw }
        rawFrames = frames
    }
    func setCursor(_ name: String, _ value: Int) async throws { cursorValue = value }
    func cursor(_ name: String) async throws -> Int? { cursorValue }
}

@MainActor
final class BackfillSafetyTests: XCTestCase {
    private func validFrame(_ payload: [UInt8], type: UInt8, cmd: UInt8 = 0) -> [UInt8] {
        var frame = frameFromPayload(payload, type: type, cmd: cmd)
        frame[3] = crc8([frame[1], frame[2]])
        return frame
    }

    private func endFrame(trim: UInt8) -> [UInt8] {
        let payload: [UInt8] = [0, 241, 83, 101, 0, 0, 0, 0, 0, 0, trim, 0, 0, 0]
        return validFrame(payload, type: 49, cmd: 2)
    }

    private func bytes(_ hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return out
    }

    /// Mac reference parity (Tools/StrapCapture run): the strap's real HISTORY_START / HISTORY_END
    /// pair must yield exactly one ack carrying the END's 8-byte end_data, and the session stays
    /// open for the next chunk. The reference tool acked this END with `01 3b2c0100 02000000`.
    func testReferenceCaptureChunkIsAcknowledgedOnceWithItsEndData() async {
        let start = bytes("aa2c005231ac0156a9f66ac86206000000100000000200000029000000110000000600000000000000080600e977dad9")
        let end = bytes("aa1c00ab31ad0257a9f66a080f350000003b2c010002000000000000f797e483")
        let store = BackfillSafetyStore()
        var acks: [(UInt32, [UInt8])] = []
        let backfiller = Backfiller(store: store, deviceId: "test", ackTrim: { trim, endData in
            acks.append((trim, endData))
        }, extract: { _, _, _ in Streams() })
        let record = validFrame([1, 2, 3], type: 47)
        backfiller.begin()
        await backfiller.ingest(start)
        await backfiller.ingest(record)
        await backfiller.ingest(end)
        XCTAssertNil(backfiller.failureReason)
        XCTAssertEqual(acks.count, 1)
        XCTAssertEqual(acks.first?.0, 0x0001_2C3B)
        XCTAssertEqual(acks.first?.1, [0x3B, 0x2C, 0x01, 0x00, 0x02, 0x00, 0x00, 0x00])
        XCTAssertEqual(backfiller.sessionEndCount, 1)
        XCTAssertEqual(backfiller.sessionAckCount, 1)
        XCTAssertTrue(backfiller.isBackfilling)
        let saved = await store.rawFrames
        XCTAssertEqual(saved, [record])
        let cursor = try? await store.cursor("strap_trim")
        XCTAssertEqual(cursor, 0x0001_2C3B)
    }

    func testUnknownFrameIsSavedBeforeAcknowledgementEvenWhenCaptureDisabled() async {
        let store = BackfillSafetyStore()
        var acknowledgements = 0
        let backfiller = Backfiller(store: store, deviceId: "test", ackTrim: { _, _ in
            acknowledgements += 1
        }, enableRawCapture: false, extract: { _, _, _ in Streams() })
        let unknown = validFrame([1, 2, 3], type: 50)
        backfiller.begin()
        await backfiller.ingest(unknown)
        await backfiller.ingest(endFrame(trim: 1))
        let saved = await store.rawFrames
        XCTAssertEqual(saved, [unknown])
        XCTAssertEqual(acknowledgements, 1)
    }

    func testRawFailureStopsSessionAndPreventsLaterAcknowledgements() async {
        let store = BackfillSafetyStore()
        await store.setFailRaw()
        var acknowledgements = 0
        let backfiller = Backfiller(store: store, deviceId: "test", ackTrim: { _, _ in
            acknowledgements += 1
        }, extract: { _, _, _ in Streams() })
        backfiller.begin()
        await backfiller.ingest(validFrame([1, 2, 3], type: 50))
        await backfiller.ingest(endFrame(trim: 1))
        await backfiller.ingest(endFrame(trim: 2))
        XCTAssertEqual(acknowledgements, 0)
        XCTAssertFalse(backfiller.isBackfilling)
        XCTAssertNotNil(backfiller.failureReason)
        let cursor = try? await store.cursor("strap_trim")
        XCTAssertNil(cursor)
    }

    func testTimeoutDuringWriteCannotAcknowledgeAfterWriteReturns() async {
        let store = BackfillSafetyStore()
        await store.setBlockInsert()
        var acknowledgements = 0
        let backfiller = Backfiller(store: store, deviceId: "test", ackTrim: { _, _ in
            acknowledgements += 1
        }, extract: { _, _, _ in Streams() })
        backfiller.begin()
        await backfiller.ingest(validFrame([1, 2, 3], type: 50))
        let end = endFrame(trim: 1)
        let task = Task { await backfiller.ingest(end) }
        await store.waitForInsert()
        backfiller.timeoutFired()
        await store.unblockInsert()
        await task.value
        XCTAssertEqual(acknowledgements, 0)
        XCTAssertFalse(backfiller.isBackfilling)
    }

    func testCRC8FailureStopsSessionBeforeAcknowledgement() async {
        let store = BackfillSafetyStore()
        var acknowledgements = 0
        let backfiller = Backfiller(store: store, deviceId: "test", ackTrim: { _, _ in acknowledgements += 1 })
        var corrupt = validFrame([1, 2, 3], type: 50)
        corrupt[3] ^= 1
        backfiller.begin()
        await backfiller.ingest(corrupt)
        await backfiller.ingest(endFrame(trim: 1))
        XCTAssertEqual(acknowledgements, 0)
        XCTAssertNotNil(backfiller.failureReason)
    }

    func testCorruptFrameStopsSessionBeforeAcknowledgement() async {
        let store = BackfillSafetyStore()
        var acknowledgements = 0
        let backfiller = Backfiller(store: store, deviceId: "test", ackTrim: { _, _ in
            acknowledgements += 1
        })
        var corrupt = validFrame([1, 2, 3], type: 50)
        corrupt[corrupt.count - 1] ^= 0x01
        backfiller.begin()
        await backfiller.ingest(corrupt)
        await backfiller.ingest(endFrame(trim: 1))
        XCTAssertEqual(acknowledgements, 0)
        XCTAssertNotNil(backfiller.failureReason)
    }
}
