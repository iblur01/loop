import Foundation
import Combine

/// Observable snapshot of the live connection + biometric state, driven by `BLEFrameRouter`
/// (from decoded frames) and `BLEConnectionManager` (from CoreBluetooth callbacks).
/// `@MainActor` so SwiftUI views observe it safely; mutators are called on the main queue.
@MainActor
public final class BLEDeviceState: ObservableObject {
    @Published public var connected: Bool = false
    @Published public var bonded: Bool = false

    /// Advertised name of the most recently discovered peripheral (from `CBAdvertisementDataLocalNameKey`
    /// or `peripheral.name`), captured in `didDiscover` before CoreBluetooth connects to it.
    /// Reset to `nil` on disconnect so the UI returns to "no sensor" state.
    @Published public var discoveredDeviceName: String? = nil
    @Published public var heartRate: Int? = nil
    @Published public var rr: [Int] = []
    @Published public var batteryPct: Double? = nil
    @Published public var batteryMV: Int? = nil
    @Published public var isCharging: Bool? = nil
    @Published public var isOnWrist: Bool? = nil
    @Published public var batteryPackConnected: Bool? = nil
    @Published public var lastFrameType: String? = nil
    @Published public var lastEvent: String? = nil

    /// CoreBluetooth identifier (UUID) of the bonded peripheral, set on discover/connect.
    @Published public var peripheralUUID: String? = nil
    /// "Harvard" (main MCU) firmware version, from REPORT_VERSION_INFO. Format a.b.c.d.
    @Published public var fwVersionHarvard: String? = nil
    /// "Boylston" (companion MCU) firmware version, from REPORT_VERSION_INFO. Format a.b.c.d.
    @Published public var fwVersionBoylston: String? = nil
    /// Free-text reply to GET_ADVERTISING_NAME_HARVARD, if printable.
    @Published public var advertisingName: String? = nil
    /// Free-text reply to GET_HELLO_HARVARD, if printable.
    @Published public var helloInfo: String? = nil
    /// Rolling log of human-readable lines for the on-device verification checklist.
    @Published public var log: [String] = []

    /// True when the stuck-strap watchdog finds the strap has newer records than us but our frontier
    /// won't advance (likely needs a manual reboot). Banner-only.
    @Published public var strapNeedsReboot = false

    /// True while a historical-offload (backfill) session is in progress.
    @Published public var backfilling = false

    /// User opt-in for the live HR stream (type-40 REALTIME_DATA). OFF by default to spare the strap
    /// battery — when on, the connection manager enables the stream on every connect and live HR/R-R
    /// flow into the store. Mirrors the persisted UserDefaults flag.
    @Published public var realtimeHROn: Bool = false

    /// Wall time (unix seconds) of the last successfully-completed offload (a sync, even if nothing new
    /// came — i.e. caught up). Drives the sync tile + the staleness nudge.
    @Published public var lastSyncedAt: TimeInterval?

    /// Optional hook invoked on every battery update (wired by a view model to the alert monitor).
    /// Kept as a closure so this stays a plain observable snapshot with no alert dependency.
    public var onBatteryUpdate: ((Double) -> Void)?

    public init() {}

    /// Single funnel for battery readings — updates the published value AND notifies the hook,
    /// so both write sites (BLEFrameRouter, BLEConnectionManager) drive the alert monitor identically.
    public func setBattery(_ pct: Double) {
        batteryPct = pct
        onBatteryUpdate?(pct)
    }

    public func append(log line: String) {
        log.append(line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}
