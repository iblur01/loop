import Foundation
import Combine

// MARK: - DeviceConnectionViewModel

/// Drives the device-pairing UI (NoSensorSheet / SensorDetectedSheet) with a single
/// derived `phase` enum, computed from `BLEDeviceState` published values.
/// Owns the `BLEConnectionManager` + `BLEDeviceState` pair so Phase C views can be
/// injected with one object instead of wiring BLE plumbing directly.
@MainActor
public final class DeviceConnectionViewModel: ObservableObject {

    /// Coarse-grained connection phase driving which device sheet (if any) is shown.
    public enum ConnectionPhase: Equatable {
        /// Never connected / disconnected, no device in view yet.
        case noSensor
        /// Scan started (after `startScan()`/`confirmPairing()`), no device found yet.
        case scanning
        /// A peripheral was discovered (and CoreBluetooth is already connecting to it),
        /// but the WHOOP bond/handshake has not completed.
        case detected(name: String, model: String, batteryLevel: Double)
        /// CoreBluetooth connected, but the WHOOP bond/handshake is still in progress.
        case bonding
        /// Bonded and ready; background sync may still be running.
        case connected
    }

    @Published public private(set) var phase: ConnectionPhase = .noSensor

    /// Set when the user taps "Ignorer"/"Plus tard" on the no-sensor sheet. While true, the
    /// auto-presented pairing sheet stays closed even though `phase` is `.noSensor`. Reset as soon
    /// as a device is detected/connected, so a later disconnect surfaces the sheet once again.
    @Published public var noSensorSnoozed = false

    public let state: BLEDeviceState
    public let bleManager: BLEConnectionManager
    private let batteryActivityController = BraceletBatteryLiveActivityController()

    /// True once `startScan()`/`confirmPairing()` has been called and no device has
    /// been found/connected yet; cleared once a device is detected or the user dismisses.
    private var isScanning = false

    private var cancellables: Set<AnyCancellable> = []

    /// True once `bootstrap()` has completed; guards against redundant re-bootstrapping
    /// when the owning view's `.task` re-runs (e.g. tab re-selection).
    private var bootstrapped = false

    public init(state: BLEDeviceState? = nil, deviceId: String? = nil) {
        let state = state ?? BLEDeviceState()
        self.state = state
        self.bleManager = BLEConnectionManager(state: state, deviceId: deviceId ?? LocalDeviceID.current)
        observeState()
    }

    // MARK: - Intents

    /// Starts a BLE scan for a WHOOP strap; transitions to `.scanning` until a device
    /// is discovered or bonding/connection completes.
    public func startScan() {
        isScanning = true
        bleManager.connect()
        recomputePhase()
    }

    /// Confirms pairing-mode from the NoSensorSheet step 2 ("Oui, lancer la recherche").
    /// Identical to `startScan()`; kept as a separate name to match the UI intent.
    public func confirmPairing() {
        startScan()
    }

    /// Called from `SensorDetectedSheet.onConnect`.
    ///
    /// `BLEConnectionManager.didDiscover` already calls `central.connect(peripheral)`
    /// immediately upon discovery (see `BLEConnectionManager.swift`), so by the time
    /// `.detected` is shown CoreBluetooth is already attempting the connection/bond.
    /// This method is therefore a no-op on the BLE layer; it exists so the UI has an
    /// explicit "confirm" affordance and so future changes (e.g. gating the connect
    /// behind user confirmation) have a single call site to adapt.
    public func connectToDetectedDevice() {
        recomputePhase()
    }

    /// Dismisses the device sheets and returns to `.noSensor`, tearing down any
    /// in-progress connection/scan.
    public func dismiss() {
        isScanning = false
        bleManager.disconnect()
        recomputePhase()
    }

    /// Opens the local store on first use; safe to call repeatedly. Call from `.task`
    /// when the owning view appears. Offline-first: no server config — the store opens under the
    /// stable `LocalDeviceID`.
    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        await bleManager.bootstrapStore()
    }

    /// Toggle the on-demand live HR stream (type-40). OFF by default to spare strap battery; the
    /// choice is persisted and re-armed on each connect by `BLEConnectionManager`.
    public func setRealtimeHR(_ on: Bool) {
        bleManager.setRealtimeHR(on)
    }

    // MARK: - Scene lifecycle

    /// Called when the app moves to the background. Applies the raw-outbox retention
    /// policy (24h synced window / 50MB unsynced cap) so storage doesn't grow unbounded.
    public func onEnterBackground() {
        bleManager.setAppActive(false)   // pause live HR stream (battery) — opt-in preserved
        bleManager.pruneRaw()
    }

    /// Called when the app returns to the foreground. Kicks a backfill sync if the
    /// connect/periodic floor has elapsed (gated inside `BLEOffloadCoordinator`).
    public func enterForeground() {
        bleManager.setAppActive(true)    // resume live HR stream if the user left it on
        bleManager.requestSync(.foreground)
    }

    // MARK: - Debug

    func simulateCriticalBatteryLiveActivity() {
        state.discoveredDeviceName = state.discoveredDeviceName ?? "WHOOP"
        state.isCharging = false
        state.setBattery(4)
    }

    func simulateChargingLiveActivity() {
        state.discoveredDeviceName = state.discoveredDeviceName ?? "WHOOP"
        state.setBattery(state.batteryPct ?? 42)
        state.isCharging = true
    }

    func stopBatteryLiveActivitySimulation() {
        state.setBattery(80)
        state.isCharging = false
    }

    // MARK: - State observation

    private func observeState() {
        // BLEDeviceState is a nested ObservableObject; changes that do not affect `phase`
        // must still invalidate views observing this view model.
        Publishers.MergeMany(
            state.$lastSyncedAt.map { _ in () }.eraseToAnyPublisher(),
            state.$isCharging.map { _ in () }.eraseToAnyPublisher(),
            state.$isOnWrist.map { _ in () }.eraseToAnyPublisher(),
            state.$strapNeedsReboot.map { _ in () }.eraseToAnyPublisher(),
            state.$realtimeHROn.map { _ in () }.eraseToAnyPublisher(),
            state.$fwVersionHarvard.map { _ in () }.eraseToAnyPublisher()
        )
        .dropFirst()
        .sink { [weak self] _ in self?.objectWillChange.send() }
        .store(in: &cancellables)

        Publishers.CombineLatest4(
            state.$connected,
            state.$bonded,
            state.$discoveredDeviceName,
            state.$batteryPct
        )
        .sink { [weak self] _, _, _, _ in
            self?.recomputePhase()
        }
        .store(in: &cancellables)

        Publishers.CombineLatest3(
            state.$batteryPct,
            state.$isCharging,
            state.$discoveredDeviceName
        )
        .sink { [weak self] batteryPct, isCharging, deviceName in
            self?.batteryActivityController.handleBatteryUpdate(
                batteryPercentage: batteryPct,
                isCharging: isCharging,
                deviceName: deviceName
            )
        }
        .store(in: &cancellables)

        // Pipeline de sync/calcul → Live Activity : visible hors de l'app pendant l'activité.
        bleManager.syncCoordinator.$status
            .sink { [weak self] status in
                let (active, detail) = Self.liveActivitySync(for: status)
                self?.batteryActivityController.handleSyncUpdate(active: active, detail: detail)
            }
            .store(in: &cancellables)
    }

    /// Traduit le `SyncStatus` du coordinator en (actif, détail) pour la Live Activity.
    private static func liveActivitySync(for status: SyncStatus) -> (Bool, String?) {
        switch status {
        case .syncing(.fromStrap): return (true, String(localized: "activity.sync.download", table: "Core"))
        default: return (false, nil)
        }
    }

    /// User asked to dismiss the no-sensor pairing sheet ("Ignorer"/"Plus tard"): snooze it so it
    /// doesn't immediately re-present while `phase` is still `.noSensor`.
    public func snoozeNoSensorSheet() {
        noSensorSnoozed = true
    }

    /// True once the phase has stayed `.noSensor` long enough (debounce) to actually surface the
    /// no-sensor sheet. Avoids the flash where the sheet pops at launch then immediately hides
    /// because a bracelet connects a second later. The sheet binds to this, not raw `.noSensor`.
    @Published public private(set) var noSensorReady = false

    /// How long the phase must remain `.noSensor` before the pairing sheet is allowed to appear.
    private static let noSensorDebounce: Duration = .seconds(4)
    private var noSensorDebounceTask: Task<Void, Never>?

    private func recomputePhase() {
        let newPhase: ConnectionPhase
        if state.connected, state.bonded {
            isScanning = false
            newPhase = .connected
        } else if state.connected, !state.bonded {
            newPhase = .bonding
        } else if let name = state.discoveredDeviceName {
            isScanning = false
            // No device-reported battery yet at this stage (battery telemetry arrives
            // post-bond); default to a neutral mid-level so the sheet doesn't show 0%.
            let batteryLevel = state.batteryPct ?? 0.5
            newPhase = .detected(name: name, model: "WHOOP 4.0", batteryLevel: batteryLevel)
        } else {
            newPhase = isScanning ? .scanning : .noSensor
        }

        // Any non-noSensor phase clears the snooze so a future disconnect surfaces the sheet again.
        if newPhase != .noSensor { noSensorSnoozed = false }
        phase = newPhase
        updateNoSensorDebounce()
    }

    /// Gate the no-sensor sheet behind a short debounce: only flip `noSensorReady` true after the
    /// phase has been `.noSensor` continuously for `noSensorDebounce`. Leaving `.noSensor` cancels
    /// the pending timer and hides the sheet immediately.
    private func updateNoSensorDebounce() {
        guard phase == .noSensor else {
            noSensorDebounceTask?.cancel()
            noSensorDebounceTask = nil
            noSensorReady = false
            return
        }
        // Already pending or already shown — nothing to (re)start.
        guard !noSensorReady, noSensorDebounceTask == nil else { return }
        noSensorDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.noSensorDebounce)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.phase == .noSensor else { return }
                self.noSensorReady = true
                self.noSensorDebounceTask = nil
            }
        }
    }
}
