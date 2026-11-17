import XCTest
import WhoopProtocol
import WhoopStore
@testable import Loop

// MARK: - SyncCoordinatorTests
//
// Offline-first cutover : le serveur VPS (leg B upload + legs C/D) a été retiré. Le SyncCoordinator
// ne fait plus que calculer le `SyncStatus` à partir des signaux du leg A (offload BLE). On couvre :
//   - SyncCoordinator.recomputeStatus priority ladder (driven via the public note* signals).
//   - WhoopStore.unsyncedTotal delta accounting (API conservée côté store).
@MainActor
final class SyncCoordinatorTests: XCTestCase {

    // MARK: - Status priority ladder

    func testInitialStatusIsOffline() {
        let c = SyncCoordinator()
        XCTAssertEqual(c.status, .offline)
    }

    func testConnectedButNotBondedIsOffline() {
        let c = SyncCoordinator()
        c.noteBLELinkChanged(connected: true, bonded: false)
        XCTAssertEqual(c.status, .offline)
    }

    func testBondedIdleIsConnectedIdle() {
        let c = SyncCoordinator()
        c.noteBLELinkChanged(connected: true, bonded: true)
        XCTAssertEqual(c.status, .connectedIdle)
    }

    func testOffloadActiveOutranksConnectedIdle() {
        let c = SyncCoordinator()
        c.noteBLELinkChanged(connected: true, bonded: true)
        c.noteOffload(active: true)
        XCTAssertEqual(c.status, .syncing(.fromStrap))
    }

    func testStrapStuckOutranksOffload() {
        let c = SyncCoordinator()
        c.noteBLELinkChanged(connected: true, bonded: true)
        c.noteOffload(active: true)
        c.noteStrapStuck(true)
        XCTAssertEqual(c.status, .strapStuck)
    }

    func testStrapStuckClearsBackToOffloadThenIdle() {
        let c = SyncCoordinator()
        c.noteBLELinkChanged(connected: true, bonded: true)
        c.noteOffload(active: true)
        c.noteStrapStuck(true)
        c.noteStrapStuck(false)
        XCTAssertEqual(c.status, .syncing(.fromStrap))
        c.noteOffload(active: false)
        XCTAssertEqual(c.status, .connectedIdle)
    }

    func testDisconnectReturnsToOffline() {
        let c = SyncCoordinator()
        c.noteBLELinkChanged(connected: true, bonded: true)
        XCTAssertEqual(c.status, .connectedIdle)
        c.noteBLELinkChanged(connected: false, bonded: false)
        XCTAssertEqual(c.status, .offline)
    }

    func testStrapStuckShownEvenWhenOffline() {
        let c = SyncCoordinator()
        c.noteStrapStuck(true)
        XCTAssertEqual(c.status, .strapStuck)
    }

    func testErrorOutranksEverything() {
        let c = SyncCoordinator()
        c.noteBLELinkChanged(connected: true, bonded: true)
        c.noteOffload(active: true)
        c.noteError("boom")
        XCTAssertEqual(c.status, .error("boom"))
        c.noteError(nil)
        XCTAssertEqual(c.status, .syncing(.fromStrap))
    }

    // MARK: - WhoopStore.unsyncedTotal (T0.2)

    func testUnsyncedTotalCountsAcrossInsertAndMark() async throws {
        let store = try await makeTempStore()
        let device = "test-device"
        try await store.upsertDevice(id: device, mac: nil, name: "Test")

        // Insert N unsynced HR rows.
        let n = 10
        let base = 1_700_000_000
        let rows = (0..<n).map { HRSample(ts: base + $0, bpm: 60 + $0) }
        try await store.insert(Streams(hr: rows), deviceId: device, markSynced: false)

        let total0 = try await store.unsyncedTotal(deviceId: device)
        XCTAssertEqual(total0, n, "all inserted rows should be unsynced")

        // Mark K synced.
        let k = 4
        try await store.markHRSynced(deviceId: device, rows: Array(rows.prefix(k)))

        let total1 = try await store.unsyncedTotal(deviceId: device)
        XCTAssertEqual(total1, n - k, "unsyncedTotal should drop by the marked count")
    }

    func testUnsyncedTotalIsZeroForUnknownDevice() async throws {
        let store = try await makeTempStore()
        let total = try await store.unsyncedTotal(deviceId: "nobody")
        XCTAssertEqual(total, 0)
    }

    // MARK: - Helpers

    private func makeTempStore() async throws -> WhoopStore {
        let path = NSTemporaryDirectory() + "loop-tests-\(UUID().uuidString).sqlite"
        return try await WhoopStore(path: path)
    }
}
