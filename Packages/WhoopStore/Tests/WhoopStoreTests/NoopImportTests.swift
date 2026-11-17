import XCTest
import GRDB
@testable import WhoopStore

final class NoopImportTests: XCTestCase {
    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [NoopImportProgress] = []
        func append(_ event: NoopImportProgress) { lock.lock(); defer { lock.unlock() }; events.append(event) }
        func snapshot() -> [NoopImportProgress] { lock.lock(); defer { lock.unlock() }; return events }
    }
    private func fixture(corruptRaw: Bool = false, wal: Bool = false) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        var configuration = Configuration()
        if wal { configuration.journalMode = .wal }
        let db = try DatabaseQueue(path: url.path, configuration: configuration)
        try db.write { db in
            try db.execute(sql: """
                CREATE TABLE hrSample(deviceId TEXT NOT NULL, ts INTEGER NOT NULL, bpm INTEGER NOT NULL);
                CREATE TABLE rrInterval(deviceId TEXT NOT NULL, ts INTEGER NOT NULL, rrMs INTEGER NOT NULL, seq INTEGER);
                CREATE TABLE event(deviceId TEXT NOT NULL, ts INTEGER NOT NULL, kind TEXT NOT NULL, payloadJSON TEXT NOT NULL);
                CREATE TABLE battery(deviceId TEXT NOT NULL, ts INTEGER NOT NULL, soc REAL, mv INTEGER);
                CREATE TABLE rawBatch(batchId TEXT PRIMARY KEY, deviceId TEXT NOT NULL, capturedAt INTEGER NOT NULL, deviceClockRef INTEGER NOT NULL, wallClockRef INTEGER NOT NULL, startTs INTEGER NOT NULL, endTs INTEGER NOT NULL, frameCount INTEGER NOT NULL, byteSize INTEGER NOT NULL, framesBlob BLOB NOT NULL, syncedAt INTEGER);
                CREATE TABLE noopOnly(value TEXT);
                INSERT INTO hrSample VALUES('band-a', 1000, 65),('band-b', 1001, 72);
                INSERT INTO rrInterval VALUES('band-a', 1000, 800, 1),('band-a', 1000, 800, 2);
                """)
            let blob = corruptRaw ? Data([1, 0, 0, 255, 42]) : try WhoopStore.zlibCompressWithLength(WhoopStore.packFrames([[1, 2, 3], [4]]))
            try db.execute(sql: "INSERT INTO rawBatch VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", arguments: ["original", "band-a", 1000, 1, 1000, 999, 1001, 2, 4, blob, 1002])
        }
        return url
    }

    func testStandaloneWALSnapshotCanBeInspectedAndImported() async throws {
        let url = try fixture(wal: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let header = try Data(contentsOf: url).prefix(20)
        XCTAssertEqual(header[18], 2) // WAL read format, even with no sidecars
        let walURL = URL(fileURLWithPath: url.path + "-wal")
        if FileManager.default.fileExists(atPath: walURL.path) {
            let size = try FileManager.default.attributesOfItem(atPath: walURL.path)[.size] as? NSNumber
            XCTAssertEqual(size?.intValue, 0)
            try FileManager.default.removeItem(at: walURL)
        }
        let store = try await WhoopStore.inMemory()
        let preview = try await store.inspectNoopDatabase(at: url)
        XCTAssertTrue(preview.devices.contains { $0.id == "band-a" })
        let result = try await store.importNoopDatabase(at: url, sourceDeviceId: "band-a", targetDeviceId: "loop-band")
        XCTAssertEqual(result.counts["hrSample"]?.inserted, 1)
    }

    func testNonemptyWALIsRejectedWithoutChangingDestination() async throws {
        let url = try fixture(wal: true)
        let wal = URL(fileURLWithPath: url.path + "-wal")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: wal) }
        try Data([1]).write(to: wal)
        let store = try await WhoopStore.inMemory()
        do {
            _ = try await store.inspectNoopDatabase(at: url)
            XCTFail("Expected nonempty WAL to be rejected")
        } catch let error as NoopImportError {
            guard case .invalidSource = error else { return XCTFail("Unexpected error: \(error)") }
        }
        do {
            _ = try await store.importNoopDatabase(at: url, sourceDeviceId: "band-a", targetDeviceId: "loop-band")
            XCTFail("Expected nonempty WAL to be rejected")
        } catch let error as NoopImportError {
            guard case .invalidSource = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let rows = try await store.storageStats_rowCountsForTest()
        XCTAssertEqual(rows.hr, 0)
    }

    func testPreviewAndAtomicMergeWithRawPreservesDuplicatesAndOtherDevice() async throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let store = try await WhoopStore.inMemory()
        let preview = try await store.inspectNoopDatabase(at: url)
        XCTAssertEqual(preview.devices.map(\.id), ["band-a", "band-b"])
        XCTAssertTrue(preview.unsupportedTables.contains("noopOnly"))
        let result = try await store.importNoopDatabase(at: url, sourceDeviceId: "band-a", targetDeviceId: "loop-band")
        XCTAssertEqual(result.counts["hrSample"]?.inserted, 1)
        XCTAssertEqual(result.counts["rrInterval"]?.inserted, 1)
        XCTAssertEqual(result.counts["rrInterval"]?.skipped, 1)
        XCTAssertEqual(result.counts["rawBatch"]?.inserted, 1)
        let ids = try await store.allBatchIdsForTest()
        XCTAssertEqual(ids.count, 1)
        XCTAssertTrue(ids[0].hasPrefix("hist-noop-"))
        let frames = try await store.rawFrames(batchId: ids[0])
        XCTAssertEqual(frames, [[1, 2, 3], [4]])
        let again = try await store.importNoopDatabase(at: url, sourceDeviceId: "band-a", targetDeviceId: "loop-band")
        XCTAssertEqual(again.counts["hrSample"]?.skipped, 1)
        XCTAssertEqual(again.counts["rawBatch"]?.skipped, 1)
        let rows = try await store.storageStats_rowCountsForTest()
        XCTAssertEqual(rows.hr, 1)
    }

    func testInvalidRawRollsBackAllStreams() async throws {
        let url = try fixture(corruptRaw: true); defer { try? FileManager.default.removeItem(at: url) }
        let store = try await WhoopStore.inMemory()
        let progress = ProgressRecorder()
        do {
            _ = try await store.importNoopDatabase(at: url, sourceDeviceId: "band-a", targetDeviceId: "loop-band", onProgress: { progress.append($0) })
            XCTFail("Expected invalid raw batch to reject import")
        } catch { }
        XCTAssertFalse(progress.snapshot().contains { if case .committed = $0.phase { return true }; return false })
        let rows = try await store.storageStats_rowCountsForTest()
        XCTAssertEqual(rows.hr, 0)
        XCTAssertEqual(rows.rr, 0)
    }

    func testProgressReportsProvisionalTableCountsThenCommit() async throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let store = try await WhoopStore.inMemory()
        let progress = ProgressRecorder()
        _ = try await store.importNoopDatabase(at: url, sourceDeviceId: "band-a", targetDeviceId: "loop-band", onProgress: { progress.append($0) })
        let events = progress.snapshot()
        XCTAssertTrue(events.contains { $0.table == "rrInterval" && $0.processed == 2 && $0.inserted == 1 && $0.skipped == 1 })
        guard let last = events.last, case .committed = last.phase else { return XCTFail("Expected a committed event after transaction succeeds") }
    }
}
