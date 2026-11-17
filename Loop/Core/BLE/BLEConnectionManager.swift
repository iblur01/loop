import Foundation
import CoreBluetooth
import WhoopProtocol
import WhoopStore
import UIKit

/// CoreBluetooth engine for the WHOOP 4.0: scan-by-service → connect → discover →
/// BOND (delegated to `BLEBondingHandshake`) → subscribe → reassemble char-05 frames →
/// `BLEFrameRouter`. Historical-offload orchestration is delegated to `BLEOffloadCoordinator`.
/// Cannot run in the simulator; verified manually on-device.
@MainActor
public final class BLEConnectionManager: NSObject, ObservableObject {

    // MARK: GATT UUIDs (authoritative, from FINDINGS.md)
    static let customService   = CBUUID(string: "61080001-8d6d-82b8-614a-1c8cb0f8dcc6")
    static let cmdWriteChar    = CBUUID(string: "61080002-8d6d-82b8-614a-1c8cb0f8dcc6") // CMD → strap
    static let cmdNotifyChar   = CBUUID(string: "61080003-8d6d-82b8-614a-1c8cb0f8dcc6") // responses
    static let eventNotifyChar = CBUUID(string: "61080004-8d6d-82b8-614a-1c8cb0f8dcc6") // events
    static let dataNotifyChar  = CBUUID(string: "61080005-8d6d-82b8-614a-1c8cb0f8dcc6") // data (frag)
    static let heartRateService = CBUUID(string: "180D")
    static let heartRateChar    = CBUUID(string: "2A37") // HR + R-R (works unbonded)
    static let batteryService   = CBUUID(string: "180F")
    static let batteryChar      = CBUUID(string: "2A19")

    /// State-restoration identifier for this app's central manager.
    static let restoreID = "com.loop.ble.central"

    /// UserDefaults key storing the UUID of the last successfully-connected peripheral, so a
    /// cold launch can `retrievePeripherals(withIdentifiers:)` and connect directly — bonded
    /// WHOOP straps use directed advertising and won't appear in a service-UUID scan.
    static let knownPeripheralKey = "com.loop.ble.knownPeripheralID"
    private static let archiveBlockedKey = "com.loop.ble.historicalArchiveBlocked"
    private static let archiveRequiredFreeKey = "com.loop.ble.historicalArchiveRequiredFree"

    // MARK: Published state
    public let state: BLEDeviceState
    /// Owns the sync pipeline (drain→pull→refresh) and computes the user-facing SyncStatus. The BLE
    /// layer only NOURRIT ce coordinator (lien BLE, activité d'offload, déclencheurs). Exposé pour
    /// être injecté en environmentObject par T2.3.
    let syncCoordinator = SyncCoordinator()
    private let router: BLEFrameRouter
    private var collector: Collector?
    private var backfiller: Backfiller?
    private var store: WhoopStore?
    private var bootstrapTask: Task<Void, Never>?

    // MARK: - LocalMetricsEngine (offline-first compute)
    /// Created in `bootstrapStore()` after WhoopStore is ready. Injected into
    /// `LoopDataRepository` via `LoopApp.swift` to enable local-first refresh().
    /// Published so `LoopApp.swift` can observe and inject it reactively — the engine
    /// is nil at cold start and only set after BLE powers on and bootstrapStore() completes.
    @Published var localMetricsEngine: LocalMetricsEngine?
    /// Wired at app launch, including system relaunches without a mounted view.
    var onEngineChanged: ((LocalMetricsEngine?) -> Void)?

    /// Called whenever new data has been ingested into WhoopStore (backfill complete, or engine
    /// recreated after deviceId reassignment). Wired by LoopApp to `repository.requestRefresh()`.
    var onDataIngested: (() -> Void)?

    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    // MARK: Bonding + offload
    private let handshake: BLEBondingHandshake
    private let offload: BLEOffloadCoordinator

    /// Periodic re-trigger of the type-47 historical offload. This is the PRIMARY continuous metric
    /// source (mirrors how WHOOP syncs): the strap's 14-day biometric store is re-offloaded every
    /// `backfillIntervalSeconds` while connected+bonded, rather than once per connect. Started on
    /// bond, cancelled on disconnect.
    private var backfillTimer: DispatchSourceTimer?
    // The timer fires this often, but BackfillPolicy.periodicFloorSeconds is the real floor (a recent
    // event-triggered sync defers the next periodic tick). 900s = 15 min, matching WHOOP.
    static let backfillIntervalSeconds = 900

    /// Periodic GET_BATTERY_LEVEL poll while the app is foregrounded — the strap otherwise only
    /// pushes a BATTERY_LEVEL event ~every 8 min, which makes the Device page's battery reading feel
    /// stale right after opening the app. Started on bond, cancelled on disconnect; skipped (not
    /// cancelled, so it resumes instantly) while the app is backgrounded.
    private var batteryPollTimer: DispatchSourceTimer?
    static let batteryPollIntervalSeconds = 30

    /// Re-entrancy guard for captureRawAccel: true while a bounded on-demand window is running.
    /// A second tap is a no-op until the active capture's asyncAfter block fires and clears this.
    private var rawCaptureInFlight = false

    // MARK: CoreBluetooth
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    /// Peripheral captured during `willRestoreState`; cleared in `didConnect`.
    /// Non-nil signals that `centralManagerDidUpdateState` should reconnect this
    /// specific peripheral rather than starting a fresh scan.
    private var restoredPeripheral: CBPeripheral?
    private var cmdCharacteristic: CBCharacteristic?
    /// One reassembler per notify characteristic: data/cmd/event notifications interleave, and a
    /// shared buffer splices a cmd or event fragment into the middle of a multi-fragment data frame,
    /// corrupting it (or locking onto a bogus length) for the rest of the offload.
    private var reassemblers: [CBUUID: BLEFrameReassembler] = [:]
    private var seq: UInt8 = 0
    /// True once the post-handshake settle delay has elapsed on the current connection. Every
    /// offload trigger is held until then: `connectHandshakeDone` flips before the handshake burst
    /// is even written, so a strap EVENT / foreground / charger trigger could otherwise put
    /// SEND_HISTORICAL right behind SET_CLOCK. The validated Mac sequence always waits.
    private var handshakeSettled = false
    /// Bumped on every link drop so a settle timer from a previous connection cannot open the gate.
    private var connectionEpoch = 0
    private var intentionalDisconnect = false
    private var scanTimeout: DispatchWorkItem?

    /// Stable device id; matches the server's existing device for sync parity. Overridable.
    private(set) var deviceId: String
    /// Captured (device↔wall) correlation from GET_CLOCK; nil until the response lands.
    private(set) var clockRef: ClockRef?

    /// User opt-in for the live HR stream (type-40), persisted across launches. Default OFF to spare
    /// the strap battery. When on, the stream is (re)enabled on every connect and live HR/R-R flow
    /// into the store; when off, the app relies on periodic backfill only.
    var realtimeHREnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "realtimeHREnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "realtimeHREnabled") }
    }
    /// True while the app is foregrounded. Gates the live HR stream so it never runs in the
    /// background (see `setAppActive`). A system relaunch may begin in the background.
    private var appActive = UIApplication.shared.applicationState == .active

    public init(state: BLEDeviceState, deviceId: String = "my-whoop") {
        self.state = state
        self.deviceId = deviceId
        self.router = BLEFrameRouter(state: state)
        self.collector = nil
        self.backfiller = nil

        var sendBox: ((WhoopCommand, [UInt8], CBCharacteristicWriteType) -> Void)!
        var logBox: ((String) -> Void)!
        self.handshake = BLEBondingHandshake(
            send: { cmd, payload, type in sendBox(cmd, payload, type) },
            log: { line in logBox(line) })
        self.offload = BLEOffloadCoordinator(
            state: state,
            send: { cmd, payload, type in sendBox(cmd, payload, type) },
            log: { line in logBox(line) })

        super.init()

        sendBox = { [weak self] cmd, payload, type in self?.send(cmd, payload: payload, writeType: type) }
        logBox = { [weak self] line in self?.log(line) }

        state.lastSyncedAt = UserDefaults.standard.object(forKey: "lastSyncedAt") as? Double
        state.realtimeHROn = UserDefaults.standard.bool(forKey: "realtimeHREnabled")
        // Restore identifier + background-capable central (foundation for state restoration).
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: BLEConnectionManager.restoreID]
        )
        // Strap-as-clock: an incoming EVENT packet kicks a rate-limited catch-up sync.
        router.onSyncTrigger = { [weak self] in self?.requestSync(.strap) }
        offload.realtimeHRActive = { [weak self] in
            guard let self else { return false }
            return self.realtimeHREnabled && self.appActive
        }
        offload.onContinuationRequested = { [weak self] in self?.requestSync(.continuation) }
        offload.powerContext = { [weak self] in self?.powerContext ?? .foreground }
        startPowerMonitoring()
        handshake.onClockRequestNeeded = { [weak self] in
            self?.send(.getClock, payload: [], writeType: .withoutResponse)
        }
        handshake.onHandshakeComplete = { [weak self] in
            guard let self else { return }
            // Plain offload (no high-freq-sync), rate-limited (first connect always runs;
            // reconnect-flaps are throttled by BackfillPolicy). Deferred ~1.5s so SET_CLOCK/
            // GET_DATA_RANGE round-trip first and SEND_HISTORICAL runs on a settled link, like the
            // paced Mac prototype. requestSync is itself gated on connectHandshakeDone so a racing
            // foreground/restore trigger can't fire it early.
            let epoch = self.connectionEpoch
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.connectionEpoch == epoch, self.handshake.connectHandshakeDone else { return }
                self.handshakeSettled = true
                self.requestSync(.connect)
            }
            // Re-arm the live HR stream only if the user opted in AND the app is foregrounded — the
            // strap forgets the toggle across reconnects, so it must be re-sent each connect. A connect
            // that happens in the background (state restoration) must NOT start streaming.
            if self.realtimeHREnabled && self.appActive { self.send(.toggleRealtimeHR, payload: [0x01]) }
            self.startBackfillTimer()   // re-offload the type-47 store every backfillIntervalSeconds
            self.startBatteryPollTimer() // refresh the Device page battery reading while foregrounded
            if self.appActive { self.send(.getBatteryLevel, payload: [0x00], writeType: .withoutResponse) }
            self.scheduleClockRetries() // re-issue GET_CLOCK if the burst-fired request was dropped
            self.persistDeviceInfo()    // record name/MAC for the Device info page
        }
        // Couche A (offload) → SyncCoordinator : activité d'offload (gate le status/noteOffload) et
        // fin d'offload (déclenche le pipeline drain→pull→refresh côté coordinator).
        if let message = UserDefaults.standard.string(forKey: Self.archiveBlockedKey) {
            syncCoordinator.noteError(message)
        }
        offload.onOffloadActiveChanged = { [weak self] active in
            // Foreground link runs at a shorter connection interval: keep the screen on while draining.
            UIApplication.shared.isIdleTimerDisabled = active
            if active { self?.syncCoordinator.noteError(nil) }
            self?.syncCoordinator.noteOffload(active: active)
        }
        offload.onOffloadFailure = { [weak self] message, requiredFreeBytes in
            if let requiredFreeBytes {
                UserDefaults.standard.set(message, forKey: Self.archiveBlockedKey)
                UserDefaults.standard.set(requiredFreeBytes, forKey: Self.archiveRequiredFreeKey)
            }
            self?.syncCoordinator.noteError(message)
        }
        // Auto-upload after backfill disabled — manual-only upload via Settings button.
        offload.onOffloadFinished = { [weak self] in
            self?.syncCoordinator.noteOffload(active: false)
            // Trigger local compute so Today view reflects new data without manual pull-to-refresh.
            // Extend background execution if app is backgrounded to allow compute to complete.
            guard let self else { return }
            if !self.appActive {
                self.beginBackgroundTaskForCompute()
            }
            self.onDataIngested?()
            NotificationCenter.default.post(name: Notification.Name("loop.bandHistoryChanged"), object: nil)
        }
    }

    /// Designated initializer for testing and preview use: accepts a pre-built Collector.
    init(state: BLEDeviceState, deviceId: String = "my-whoop", collector: Collector?) {
        self.state = state
        self.deviceId = deviceId
        self.router = BLEFrameRouter(state: state)
        self.collector = collector
        self.backfiller = nil

        var sendBox: ((WhoopCommand, [UInt8], CBCharacteristicWriteType) -> Void)!
        var logBox: ((String) -> Void)!
        self.handshake = BLEBondingHandshake(
            send: { cmd, payload, type in sendBox(cmd, payload, type) },
            log: { line in logBox(line) })
        self.offload = BLEOffloadCoordinator(
            state: state,
            send: { cmd, payload, type in sendBox(cmd, payload, type) },
            log: { line in logBox(line) })

        super.init()

        sendBox = { [weak self] cmd, payload, type in self?.send(cmd, payload: payload, writeType: type) }
        logBox = { [weak self] line in self?.log(line) }

        state.lastSyncedAt = UserDefaults.standard.object(forKey: "lastSyncedAt") as? Double
        state.realtimeHROn = UserDefaults.standard.bool(forKey: "realtimeHREnabled")
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: BLEConnectionManager.restoreID]
        )
        router.onSyncTrigger = { [weak self] in self?.requestSync(.strap) }
        offload.realtimeHRActive = { [weak self] in
            guard let self else { return false }
            return self.realtimeHREnabled && self.appActive
        }
        offload.onContinuationRequested = { [weak self] in self?.requestSync(.continuation) }
        offload.powerContext = { [weak self] in self?.powerContext ?? .foreground }
        startPowerMonitoring()
    }

    /// Build the WhoopStore + Collector + Backfiller asynchronously. Safe to call multiple
    /// times — bails out early if the collector is already initialised.
    func bootstrapStore() async {
        guard collector == nil else { return }
        if let bootstrapTask {
            await bootstrapTask.value
            return
        }
        let task = Task { @MainActor in await self.openStore() }
        bootstrapTask = task
        await task.value
        bootstrapTask = nil
    }

    private func openStore() async {
        guard let path = try? StorePaths.defaultDatabasePath() else { return }
        guard let store = try? await WhoopStore(path: path) else { return }
        // Resolve the canonical local deviceId BEFORE building collector/backfiller/engine. The init
        // placeholder ("my-whoop") would orphan every inserted row under an id the engine never
        // queries. `LocalDeviceID.current` is the stable, persisted local id (offline-first; replaces
        // the former server-bundled config id).
        if deviceId == "my-whoop" {
            let localID = LocalDeviceID.current
            if localID != deviceId {
                log("Bootstrap deviceId resolved to local id: \(deviceId) → \(localID)")
                deviceId = localID
            }
        }
        try? await store.upsertDevice(id: deviceId, mac: nil, name: "WHOOP 4.0")
        // Rescue any rows a prior run inserted under the "my-whoop" placeholder (decoded streams are
        // durable — never pruned) so the cutover keeps every historical row addressable.
        if deviceId != "my-whoop" {
            let moved = (try? await store.reassignDevice(from: "my-whoop", to: deviceId)) ?? 0
            if moved > 0 { log("Reassigned \(moved) legacy rows my-whoop → \(deviceId)") }
        }
        // Research toggle — OFF by default. When disabled the app is decoded-only and never
        // persists raw frames. Flip "enableRawCapture" in UserDefaults to capture raw again.
        let enableRawCapture = UserDefaults.standard.bool(forKey: "enableRawCapture")
        self.store = store
        localMetricsEngine = LocalMetricsEngine(store: store, deviceId: deviceId)
        collector = Collector(store: store, deviceId: deviceId,
                              enableRawCapture: enableRawCapture)
        backfiller = Backfiller(store: store, deviceId: deviceId,
                                ackTrim: { [weak self] trim, endData in
                                    self?.ackHistoricalChunk(trim: trim, endData: endData)
                                },
                                enableRawCapture: enableRawCapture)
        // Restore-path race: a GET_CLOCK correlation can land BEFORE bootstrapStore() builds the
        // collector (the handshake fires on reconnect, store bootstrap is async). The correlation
        // sets `self.clockRef` but `collector?.clockRef` was a no-op on the then-nil collector. Carry
        // it over so a freshly-built collector isn't stuck buffering live frames it can never flush.
        collector?.clockRef = clockRef
        backfiller?.clockRef = clockRef
        onEngineChanged?(localMetricsEngine)
        // If the handshake won the startup race, its first sync was deferred until storage
        // existed. Retry after the same settling delay used by the handshake path.
        if handshake.connectHandshakeDone {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.requestSync(.connect)
            }
        }
    }

    // MARK: Public API

    /// Toggle the live HR stream on demand. Persists the choice (re-armed on every future connect)
    /// and applies it immediately when connected + foreground. OFF is the battery-friendly default.
    public func setRealtimeHR(_ on: Bool) {
        realtimeHREnabled = on
        state.realtimeHROn = on
        log("Realtime HR \(on ? "enabled" : "disabled") by user")
        // Mid-offload the stream is already paused: apply the choice when the session ends.
        if offload.backfilling {
            offload.holdRealtimeHR(resumeOnExit: on && appActive)
            return
        }
        send(.toggleRealtimeHR, payload: [(on && appActive) ? 0x01 : 0x00])
    }

    /// Scene-phase gate. The live HR stream runs ONLY while the app is active AND the user opted in —
    /// backgrounding always pauses it (battery) without clearing the opt-in, and it resumes on the
    /// next foreground. No-op when the user never enabled it.
    public func setAppActive(_ active: Bool) {
        guard appActive != active else { return }
        appActive = active
        if !active {
            batteryPollTimer?.cancel()
            batteryPollTimer = nil
        } else if state.connected, state.bonded {
            startBatteryPollTimer()
            // Foreground: refresh the battery reading immediately rather than waiting up to
            // batteryPollIntervalSeconds for the resumed timer — but never while the strap is
            // streaming an offload (only chunk acks go out then, like the Mac reference).
            if !offload.backfilling { send(.getBatteryLevel, payload: [0x00], writeType: .withoutResponse) }
        }
        guard realtimeHREnabled else { return }
        if offload.backfilling {
            offload.holdRealtimeHR(resumeOnExit: active)
            return
        }
        send(.toggleRealtimeHR, payload: [active ? 0x01 : 0x00])
        log("Realtime HR \(active ? "resumed (foreground)" : "paused (background)")")
    }

    // MARK: Power-aware sync

    /// True while the iPhone is on a charger (charging or full).
    var phoneIsCharging: Bool {
        let st = UIDevice.current.batteryState
        return st == .charging || st == .full
    }

    var powerContext: PowerContext {
        PowerContext.current(appActive: appActive, charging: phoneIsCharging,
                             lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    private var powerObservers: [NSObjectProtocol] = []

    /// Plugging the phone in triggers an immediate catch-up offload; unplugging / Low Power Mode just
    /// changes the floors read through `powerContext` (no work to do).
    private func startPowerMonitoring() {
        guard powerObservers.isEmpty else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        let center = NotificationCenter.default
        powerObservers.append(center.addObserver(forName: UIDevice.batteryStateDidChangeNotification,
                                                 object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phoneIsCharging else { return }
                self.log("Power: charger connected — catch-up sync")
                self.requestSync(.charging)
                BackgroundTaskManager.shared.scheduleBackgroundProcessing()
            }
        })
    }

    /// Long catch-up used by the external-power BGProcessingTask: wait for the strap link, then drain
    /// the whole backlog pass after pass until HISTORY_COMPLETE, cancellation (iOS expiry) or the cap.
    func performChargingSync() async -> Bool {
        await bootstrapStore()
        if !(state.connected && state.bonded) {
            connect()
            for _ in 0..<90 {
                if Task.isCancelled || (state.connected && state.bonded && handshake.connectHandshakeDone && handshakeSettled) { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        guard state.connected, state.bonded, !Task.isCancelled else { return false }
        for _ in 0..<30 {
            guard !Task.isCancelled else { return false }
            if !offload.backfilling { requestSync(.charging) }
            // Rate-limited or nothing to do: the data is already fresh.
            guard offload.backfilling else { return true }
            if await offload.waitForCompletion() { return true }
            // Idle-timeout pass: give the auto-continuation a moment to start the next one.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return false
    }

    public func connect() {
        intentionalDisconnect = false
        guard central.state == .poweredOn else {
            log("Bluetooth not powered on (state=\(central.state.rawValue)); cannot scan yet")
            return
        }
        log("Scanning for service \(BLEConnectionManager.customService)…")
        scanTimeout?.cancel()
        central.scanForPeripherals(
            withServices: [BLEConnectionManager.customService],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.central.isScanning else { return }
            self.central.stopScan()
            self.log("Scan stopped after 30 seconds")
        }
        scanTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
    }

    public func disconnect() {
        intentionalDisconnect = true
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
        scanTimeout?.cancel()
        central.stopScan()
        state.discoveredDeviceName = nil
    }

    /// Apply the raw-outbox retention policy (24h synced window / 50MB unsynced cap).
    /// Called when the app enters the background; no-op without a concrete store.
    public func pruneRaw() {
        Task { @MainActor in await collector?.prune() }
    }

    /// Light storage summary for the UI (decoded rows, raw batches, raw bytes). nil without a store.
    public func storageStats() async -> (decodedRows: Int, rawBatches: Int, rawBytes: Int)? {
        await collector?.storageStats()
    }

    /// Capture raw accelerometer (type-43 IMU) frames on demand for a bounded window, then stop.
    /// Persists raw even when the global research toggle is off (that's the point: on-demand, not
    /// 24/7). The Collector's window auto-expires at its deadline so a dropped stop can't leak raw.
    public func captureRawAccel(seconds: TimeInterval = 30) {
        guard !rawCaptureInFlight else {
            log("Raw-accel capture: already in flight — ignoring")
            return
        }
        rawCaptureInFlight = true
        let secs = RawCaptureWindow.clamp(seconds)
        collector?.beginRawCapture(seconds: secs)
        send(.startRawData, payload: [0x01])
        send(.toggleIMUMode, payload: [0x01])
        log("Raw-accel capture: started for \(secs)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + secs) { [weak self] in
            guard let self else { return }
            // Only stop the raw stream if the 24/7 research toggle is OFF.  When it's ON, the
            // continuous stream must keep running — we just flush/upload the bounded window we
            // captured without halting the wider session.
            if !UserDefaults.standard.bool(forKey: "enableRawCapture") {
                self.send(.stopRawData, payload: [0x01])
            }
            self.rawCaptureInFlight = false
            Task { @MainActor in
                await self.collector?.endRawCapture()
                // Offline-first: raw capture flush goes to the local store only.
            }
            self.log("Raw-accel capture: stopped + flushed")
        }
    }

    /// Send a command to the WHOOP strap.
    /// - Parameters:
    ///   - command: The command to send.
    ///   - payload: Command payload bytes (default `[0x00]`).
    ///   - writeType: BLE write type; defaults to `.withoutResponse` so all existing call
    ///     sites are unaffected. Pass `.withResponse` for acked commands (e.g. historicalDataResult).
    public func send(_ command: WhoopCommand, payload: [UInt8] = [0x00],
                     writeType: CBCharacteristicWriteType = .withoutResponse) {
        guard let p = peripheral, let ch = cmdCharacteristic else {
            log("send(\(command.label)) ignored — not connected")
            return
        }
        seq = seq &+ 1
        let frame = command.frame(seq: seq, payload: payload)
        p.writeValue(Data(frame), for: ch, type: writeType)
        // One ack per chunk during an offload would publish a log line (and re-render) each time.
        if command != .historicalDataResult { log("→ \(command.label) payload=\(hex(payload))") }
    }

    /// Ack one HISTORY_END chunk so the strap may trim it. Confirmed write — the strap forgets
    /// the chunk once this lands (link-layer half of safe-trim; decoded + raw already persisted).
    ///
    /// High-freq-sync ack form: HISTORICAL_DATA_RESULT(23) payload = `[0x01] + end_data`, where
    /// end_data is the verbatim 8 bytes of the HISTORY_END metadata.data[10:18] (trim u32 at
    /// [10:14] + next u32 at [14:18]). The `trim` argument (= end_data first u32) is already
    /// persisted as the strap_trim cursor by the Backfiller; it is passed here only for logging.
    func ackHistoricalChunk(trim: UInt32, endData: [UInt8]) {
        // Default .withResponse (link-layer confirmed). "backfillAckWithoutResponse" is an opt-in
        // hardware experiment: faster, but the trim is no longer confirmed by the link layer.
        let type: CBCharacteristicWriteType = UserDefaults.standard.bool(forKey: "backfillAckWithoutResponse")
            ? .withoutResponse : .withResponse
        send(.historicalDataResult, payload: [0x01] + endData, writeType: type)
    }

    /// When true, no new historical offload is kicked. Set during a full local recompute so the
    /// bracelet doesn't stream fresh data mid-compute, which would change the row fingerprint and
    /// re-trigger another recompute (the "recalcul en boucle"). Live HR/battery telemetry is
    /// unaffected — only the bulk historical backfill is held.
    private var offloadPaused = false

    /// Pause/resume historical offload. Resuming kicks one catch-up sync for whatever accumulated
    /// on the strap while paused.
    func setOffloadPaused(_ paused: Bool) {
        guard offloadPaused != paused else { return }
        offloadPaused = paused
        if !paused, state.connected, state.bonded {
            requestSync(.manual)
        }
    }

    /// The single gated entry point for every historical-offload kick. Delegates to the
    /// `BLEOffloadCoordinator`, supplying the current Backfiller + handshake state.
    func requestSync(_ trigger: BackfillTrigger) {
        // Hold all offload kicks during a full recompute. `.manual` from `setOffloadPaused(false)`
        // runs after the flag clears, so the resume catch-up isn't swallowed here.
        guard !offloadPaused else {
            // Strap/periodic kicks are frequent; only trace the ones a reader would wait for.
            if trigger == .manual || trigger == .continuation || trigger == .connect {
                log("Backfill: \(trigger) held — full recompute in progress")
            }
            return
        }
        let defaults = UserDefaults.standard
        if defaults.string(forKey: Self.archiveBlockedKey) != nil {
            let savedThreshold = (defaults.object(forKey: Self.archiveRequiredFreeKey) as? NSNumber)?.int64Value ?? 0
            let threshold = max(savedThreshold, Backfiller.requiredFreeBytes(frameBytes: 0))
            let available = Backfiller.availableStorageBytes()
            guard let free = available, free >= threshold else {
                // Otherwise every kick (manual included) vanishes with no trace in the BLE log.
                let freeMB = available.map { "\($0 / 1_048_576)" } ?? "?"
                log("Backfill: \(trigger) skipped — Espace insuffisant (libre \(freeMB) Mo, requis \(threshold / 1_048_576) Mo)")
                return
            }
            defaults.removeObject(forKey: Self.archiveBlockedKey)
            defaults.removeObject(forKey: Self.archiveRequiredFreeKey)
            syncCoordinator.noteError(nil)
        }
        offload.requestSync(trigger, backfiller: backfiller,
                            connectHandshakeDone: handshake.connectHandshakeDone && handshakeSettled)
    }

    /// Wait for the actual offload result; iOS may expire this task at any time.
    /// Bluetooth restoration and the next scheduled wake provide retry opportunities.
    func performBackgroundSync() async -> Bool {
        await bootstrapStore()
        guard !Task.isCancelled else { return false }
        if !offload.backfilling { requestSync(.periodic) }
        guard offload.backfilling else { return false }
        return await offload.waitForCompletion() && !Task.isCancelled
    }

    /// The open `WhoopStore`, or nil before bootstrap. Exposed so the iCloud backup layer can
    /// checkpoint + snapshot the live database file.
    var currentStore: WhoopStore? { store }

    // MARK: - iCloud restore support

    /// Suspend collection/BLE so the local SQLite + cache files can be safely replaced by an iCloud
    /// restore. Disconnects, flushes and tears down the collector/backfiller/engine, and releases the
    /// store handle so its `DatabaseQueue` closes (no other strong refs remain). Pair with
    /// `resumeAfterRestore()` once the files are swapped.
    func suspendForRestore() async {
        setOffloadPaused(true)
        disconnect()
        await collector?.flush()
        collector = nil
        backfiller = nil
        localMetricsEngine = nil
        onEngineChanged?(nil)
        store = nil
        syncCoordinator.noteBLELinkChanged(connected: false, bonded: false)
        log("Suspended for iCloud restore — store closed")
    }

    /// Rebuild the store + collection stack after an iCloud restore replaced the local files, then
    /// reconnect. The restored `cache.json` lets the UI repaint without an immediate recompute.
    func resumeAfterRestore() async {
        await bootstrapStore()
        setOffloadPaused(false)
        onDataIngested?()
        connect()
        log("Resumed after iCloud restore")
    }

    /// Records the bonded peripheral's name/UUID in the `device` table for the Device info page.
    /// Best-effort: no-op until the store has been bootstrapped.
    private func persistDeviceInfo() {
        guard let store else { return }
        let id = deviceId
        let mac = state.peripheralUUID
        let name = state.discoveredDeviceName
        Task { @MainActor in try? await store.upsertDevice(id: id, mac: mac, name: name) }
    }

    // MARK: Helpers

    /// Establish a `clockRef` even though this strap firmware never answers GET_CLOCK (verified:
    /// cmd=11 responses never arrive). Without a `clockRef` the live Collector HARD-BLOCKS — it
    /// keeps buffering type-40 frames but `flush()` early-returns, so no live HR is ever persisted
    /// or uploaded (every drain reports "nothing to send").
    ///
    /// Step 1 (+4s): one quick GET_CLOCK retry, in case the single burst-fired request was merely
    /// dropped on a busy link — if a real reply lands it wins (sets `clockRef` first).
    ///
    /// Step 2 (+10s): SET_CLOCK-derived identity fallback. The post-bond handshake just issued
    /// SET_CLOCK, writing the strap RTC to wall-now; REALTIME_DATA/EVENT timestamps ARE that same
    /// RTC (unix seconds). So once the RTC is set we already KNOW the correlation: device == wall.
    /// `toWall` is a linear offset, and RTC tracks wall after SET_CLOCK, so a (now, now) pair maps
    /// every type-40 frame (buffered or future) to the right wall time regardless of seed instant.
    /// If sample timestamps ever come back wrong (e.g. ~1970), the strap RTC isn't the type-40 epoch
    /// and this fallback must be revisited.
    private func scheduleClockRetries() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.clockRef == nil, self.peripheral != nil else { return }
            // The initial offload starts 1.5 s after the handshake, so this retry would land in the
            // middle of the historical stream. The +10 s identity fallback covers a silent GET_CLOCK.
            guard !self.offload.backfilling else { return }
            self.log("Clock not yet correlated after 4s — re-sending GET_CLOCK")
            self.send(.getClock, payload: [], writeType: .withoutResponse)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.clockRef == nil, self.peripheral != nil else { return }
            let now = Int(Date().timeIntervalSince1970)
            let ref = ClockRef(device: now, wall: now)
            self.clockRef = ref
            self.collector?.clockRef = ref
            self.backfiller?.clockRef = ref
            self.log("Clock fallback: GET_CLOCK silent — seeding identity ref from SET_CLOCK (device=wall=\(now)); live collection unblocked")
        }
    }

    /// Not actor-isolated: read from `log()`, which may be called off-main (Uploader's executor).
    /// `DateFormatter` mutation isn't thread-safe in general, but this instance is only ever
    /// used for `.string(from:)` (read-only) after construction, so concurrent reads are safe.
    nonisolated private static let logTimeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    /// Appends a log line to `state` (a `@Published` property, main-thread only). The Uploader's
    /// log callback fires from its own actor's executor (off-main), so hop to main here rather
    /// than at every call site.
    nonisolated private func log(_ s: String) {
        let line = "[\(BLEConnectionManager.logTimeFormatter.string(from: Date()))] \(s)"
        Task { @MainActor in state.append(log: line) }
    }
    private func timestamp() -> String {
        BLEConnectionManager.logTimeFormatter.string(from: Date())
    }
    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Start (or restart) the periodic backfill timer. Each tick re-runs the type-47 historical
    /// offload while connected+bonded and not already backfilling — the primary metric sync.
    private func startBackfillTimer() {
        backfillTimer?.cancel()
        let interval = BLEConnectionManager.backfillIntervalSeconds
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .seconds(interval), repeating: .seconds(interval))
        t.setEventHandler { [weak self] in self?.requestSync(.periodic) }
        t.resume()
        backfillTimer = t
    }

    /// Start (or restart) the periodic battery poll. Each tick sends GET_BATTERY_LEVEL while the
    /// app is foregrounded; skipped (cheaply, every tick) while backgrounded to avoid waking the
    /// radio for a value the UI isn't showing.
    private func startBatteryPollTimer() {
        batteryPollTimer?.cancel()
        let interval = BLEConnectionManager.batteryPollIntervalSeconds
        guard appActive else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .seconds(interval), repeating: .seconds(interval), leeway: .seconds(5))
        t.setEventHandler { [weak self] in
            // Skipped (not cancelled) during an offload: the next tick after the session resumes it.
            guard let self, self.appActive, !self.offload.backfilling else { return }
            self.send(.getBatteryLevel, payload: [0x00], writeType: .withoutResponse)
        }
        t.resume()
        batteryPollTimer = t
    }

    /// Parse a standard BLE Heart Rate Measurement (0x2A37) via the pure StandardHeartRate parser.
    private func parseStandardHR(_ data: [UInt8]) {
        guard let m = StandardHeartRate.parse(data) else { return }
        // R-R: the standard profile is the RELIABLE source (the custom REALTIME_DATA stream
        // usually reports rr_count=0), so always surface intervals when present.
        if !m.rr.isEmpty { state.rr = m.rr }
        // HR: prefer the custom stream once bonded; use 0x2A37 HR as a pre-bond fallback.
        if state.heartRate == nil || !state.bonded { state.heartRate = m.hr }
    }

    private func beginBackgroundTaskForCompute() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "LoopOffloadCompute") { [weak self] in
            self?.endBackgroundTaskForCompute()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
            self?.endBackgroundTaskForCompute()
        }
    }

    private func endBackgroundTaskForCompute() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
}

// MARK: - CBCentralManagerDelegate
extension BLEConnectionManager: @preconcurrency CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("Central state: \(central.state.rawValue) (5 = poweredOn)")
        guard central.state == .poweredOn else { return }
        // Bootstrap the async store once on first poweredOn (idempotent if already set).
        Task { @MainActor in await bootstrapStore() }
        if let p = restoredPeripheral {
            log("poweredOn with restored peripheral — reconnecting \(p.identifier)")
            if p.state != .connected {
                central.connect(p, options: nil)
            } else {
                p.discoverServices([
                    BLEConnectionManager.customService, BLEConnectionManager.heartRateService, BLEConnectionManager.batteryService,
                ])
            }
        } else if let knownID = UserDefaults.standard.string(forKey: BLEConnectionManager.knownPeripheralKey),
                  let uuid = UUID(uuidString: knownID),
                  let known = central.retrievePeripherals(withIdentifiers: [uuid]).first {
            // A previously-bonded strap exists: connect directly (it uses directed advertising
            // and won't show up in a service-UUID scan), so plain `connect()` would never find it.
            log("Found previously bonded peripheral \(known.identifier) — connecting directly")
            self.peripheral = known
            known.delegate = self
            central.connect(known, options: nil)
        } else {
            connect()
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "unknown"
        log("Discovered \(name) (rssi \(RSSI)) — connecting")
        state.discoveredDeviceName = name
        state.peripheralUUID = peripheral.identifier.uuidString
        scanTimeout?.cancel()
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        restoredPeripheral = nil
        state.connected = true
        // Couche A → coordinator : le lien BLE est monté (pas encore bonded à ce stade).
        syncCoordinator.noteBLELinkChanged(connected: true, bonded: state.bonded)
        state.peripheralUUID = peripheral.identifier.uuidString
        // peripheral.name resolves once connected; on state restoration there is no
        // didDiscover, so capture the OS-reported Bluetooth name here too.
        if let name = peripheral.name, !name.isEmpty {
            state.discoveredDeviceName = name
        }
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: BLEConnectionManager.knownPeripheralKey)
        log("Connected — discovering services")
        peripheral.discoverServices([
            BLEConnectionManager.customService, BLEConnectionManager.heartRateService, BLEConnectionManager.batteryService,
        ])
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral,
                               error: Error?) {
        Task { @MainActor in await collector?.flush() }
        state.connected = false
        // Couche A → coordinator : le lien BLE est tombé (déconnexion ⇒ unbonded du point de vue sync).
        syncCoordinator.noteBLELinkChanged(connected: false, bonded: false)
        handshake.reset()
        handshakeSettled = false
        connectionEpoch &+= 1
        // A half-received frame from the dropped link must not prefix the first frame of the next one.
        reassemblers.removeAll()
        // Invalidate any suspended persistence operation before a reconnect can start a
        // new session; an old chunk must never ACK on the newly connected peripheral.
        backfiller?.timeoutFired()
        offload.reset()
        backfillTimer?.cancel()
        backfillTimer = nil
        batteryPollTimer?.cancel()
        batteryPollTimer = nil
        if !intentionalDisconnect {
            log("Disconnected\(error.map { " — \($0.localizedDescription)" } ?? ""); reconnecting in 3s")
            // Direct reconnect (not scan): a bonded WHOOP uses directed advertising and won't
            // appear in a service-UUID scan. Reuse the known peripheral reference so iOS connects
            // as soon as the strap is in range regardless of its advertising payload.
            let knownPeripheral = peripheral
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, !self.intentionalDisconnect else { return }
                self.log("Reconnecting to known peripheral \(knownPeripheral.identifier)…")
                self.central.connect(knownPeripheral, options: nil)
            }
        } else {
            log("Disconnected (intentional)")
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didFailToConnect peripheral: CBPeripheral,
                               error: Error?) {
        log("Failed to connect\(error.map { " — \($0.localizedDescription)" } ?? "") — retrying known peripheral in 30s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self, weak peripheral] in
            guard let self, let peripheral, !self.intentionalDisconnect,
                  self.central.state == .poweredOn, peripheral.state == .disconnected else { return }
            self.central.connect(peripheral, options: nil)
        }
    }

    /// State restoration entry point (background collection).
    /// Stores the restored peripheral and — if already connected — immediately
    /// re-discovers services so `cmdCharacteristic` is re-acquired and
    /// notifications are re-routed without user interaction.
    public func centralManager(_ central: CBCentralManager,
                               willRestoreState dict: [String: Any]) {
        guard let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
              let p = peripherals.first else {
            log("Restore: no peripherals in state dict")
            return
        }
        self.peripheral = p
        self.restoredPeripheral = p
        p.delegate = self
        // Collection only runs post-bond, so a restored link was already bonded;
        // seed those flags now. `didWriteValueFor` won't re-fire on its own.
        state.bonded = true
        // clockRef is nil in the fresh process after restore, so we must re-request it.
        // Reset the flag so the post-restore didWriteValueFor issues exactly one getClock.
        handshake.reset()
        handshakeSettled = false
        connectionEpoch &+= 1
        // Ensure the store is ready before restored BLE data arrives (idempotent; no-op if already built).
        Task { @MainActor in await bootstrapStore() }
        if p.state == .connected {
            state.connected = true
            log("Restored CONNECTED peripheral \(p.identifier) — re-discovering services")
            p.discoverServices([
                BLEConnectionManager.customService, BLEConnectionManager.heartRateService, BLEConnectionManager.batteryService,
            ])
        } else {
            state.connected = false
            log("Restored DISCONNECTED peripheral \(p.identifier) — reconnect on poweredOn")
            if central.state == .poweredOn { central.connect(p, options: nil) }
        }
        // Couche A → coordinator : un lien restauré était déjà bonded ; reporte l'état (connected
        // selon la branche ci-dessus) une fois les deux flags seedés.
        syncCoordinator.noteBLELinkChanged(connected: state.connected, bonded: true)
    }
}

// MARK: - CBPeripheralDelegate
extension BLEConnectionManager: @preconcurrency CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for s in services {
            switch s.uuid {
            case BLEConnectionManager.customService:
                peripheral.discoverCharacteristics(
                    [BLEConnectionManager.cmdWriteChar, BLEConnectionManager.cmdNotifyChar,
                     BLEConnectionManager.eventNotifyChar, BLEConnectionManager.dataNotifyChar], for: s)
            case BLEConnectionManager.heartRateService:
                peripheral.discoverCharacteristics([BLEConnectionManager.heartRateChar], for: s)
            case BLEConnectionManager.batteryService:
                peripheral.discoverCharacteristics([BLEConnectionManager.batteryChar], for: s)
            default: break
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        guard let chars = service.characteristics else { return }
        for c in chars {
            switch c.uuid {
            case BLEConnectionManager.cmdWriteChar:
                cmdCharacteristic = c
                handshake.beginBonding()
            case BLEConnectionManager.cmdNotifyChar,
                 BLEConnectionManager.eventNotifyChar,
                 BLEConnectionManager.dataNotifyChar,
                 BLEConnectionManager.heartRateChar,
                 BLEConnectionManager.batteryChar:
                peripheral.setNotifyValue(true, for: c)
                log("Subscribed \(c.uuid)")
            default: break
            }
        }
    }

    /// Confirmed-write completion: delegated to `BLEBondingHandshake`, which marks bonding done
    /// and (exactly once per connection) runs the post-bond handshake.
    public func peripheral(_ peripheral: CBPeripheral,
                           didWriteValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        handshake.didWriteValue(error: error, hasClockRef: clockRef != nil)
        if handshake.didBond {
            state.bonded = true
            // Couche A → coordinator : bonding confirmé, le lien est désormais pleinement utilisable.
            syncCoordinator.noteBLELinkChanged(connected: state.connected, bonded: true)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard let data = characteristic.value else { return }
        let bytes = [UInt8](data)

        switch characteristic.uuid {
        case BLEConnectionManager.heartRateChar:
            parseStandardHR(bytes)
        case BLEConnectionManager.batteryChar:
            // Gen4: 0x2A19 (standard battery service) returns bogus 100% regardless of real charge.
            // Real battery arrives via BATTERY_LEVEL events (~every 8 min) and GET_BATTERY_LEVEL
            // vendor command response — both handled in BLEFrameRouter. Ignore this char entirely.
            break
        case BLEConnectionManager.dataNotifyChar,
             BLEConnectionManager.cmdNotifyChar,
             BLEConnectionManager.eventNotifyChar:
            // Reassemble (no-op for already-complete frames) then route each complete frame.
            let reassembler: BLEFrameReassembler
            if let existing = reassemblers[characteristic.uuid] {
                reassembler = existing
            } else {
                reassembler = BLEFrameReassembler(validatesHeaderCRC: true)
                reassemblers[characteristic.uuid] = reassembler
            }
            for frame in reassembler.feed(bytes) {
                // Type 43 is high-rate raw IMU data, not a UI state update. The collector
                // still receives it for explicit raw capture below.
                // Types 43 (raw IMU), 47 (historical data), 49 (metadata) and 50 (console) never drive UI
                // state; skipping them avoids a parse + @Published write per frame during offload.
                if !(frame.count > 4 && [43, 47, 49, 50].contains(frame[4])) {
                    router.handle(frame: frame)
                }
                offload.observeDataRangeFrame(frame)               // feeds the liveness watchdog
                // Clock correlation runs in both live and backfill modes. Once established it
                // unblocks both the Collector (live path) and the Backfiller (chunk decoding).
                if clockRef == nil && !(frame.count > 4 && frame[4] == 43) {
                    let parsed = parseFrame(frame)
                    // DIAGNOSTIC: cmdNotifyChar carries only command responses (no data flood), so
                    // logging it here is bounded. Tells us whether a GET_CLOCK response (cmd=11) ever
                    // arrives — if it never appears, the strap isn't answering; if it appears with
                    // clockKey=false, the decode is the problem. Remove once clock correlation is fixed.
                    if characteristic.uuid == BLEConnectionManager.cmdNotifyChar {
                        let cmd = frame.count > 6 ? Int(frame[6]) : -1
                        log("cmdNotify rx: type=\(frame.first.map { Int($0) } ?? -1) cmd=\(cmd) ok=\(parsed.ok) clockKey=\(parsed.parsed["clock"] != nil)")
                    }
                    if let ref = ClockCorrelation.clockRef(from: parsed, wall: Int(Date().timeIntervalSince1970)) {
                        clockRef = ref
                        collector?.clockRef = ref                  // unblocks buffered persistence
                        backfiller?.clockRef = ref                 // unblocks historical chunk decode
                        log("Clock correlated: device=\(ref.device) wall=\(ref.wall)")
                        // Conditional SET_CLOCK (mirrors WHOOP): only when the strap RTC has drifted /
                        // is frozen — not blindly every connect. Offload doesn't depend on this (it uses
                        // clockRef for decoding); SET_CLOCK only keeps FUTURE logging timestamps sane.
                        if ClockPolicy.shouldSetClock(deviceClock: ref.device, wallNow: ref.wall) {
                            log("Clock drift detected — issuing SET_CLOCK")
                            send(.setClock, payload: BLEBondingHandshake.setClockPayload())
                        }
                    }
                }
                if offload.backfilling {
                    // Historical offload path: route ONLY genuine offload frames (47/48/49/50)
                    // through the serial drain (preserves START/data/END chunk order) and re-arm the
                    // idle watchdog on them. The live type-40/43 flood (esp. the ~2/s, ~1.9 KB type-43
                    // raw) is IGNORED by extractHistoricalStreams, so feeding it to the drain only
                    // delays each chunk's insert→trim-ack — the strap then stalls waiting for the ack
                    // and the 60 s watchdog fires. Drop the flood during offload.
                    offload.routeBackfillFrame(frame, backfiller: backfiller)
                } else {
                    // Preserve raw capture and live metrics without parsing and publishing
                    // diagnostic log entries for every high-frequency data frame.
                    collector?.ingest(frame)
                }
            }
        default:
            break
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        if let error = error {
            log("Notify enable failed for \(characteristic.uuid): \(error.localizedDescription)")
        }
    }
}
