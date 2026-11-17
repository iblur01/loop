import Foundation
import WhoopProtocol

/// Pure decode→state router. Takes a COMPLETE (already reassembled) frame, decodes it with
/// WhoopProtocol.parseFrame, and updates `BLEDeviceState`. No CoreBluetooth — fully unit-testable.
@MainActor
public final class BLEFrameRouter {
    private let state: BLEDeviceState
    /// Called when the strap pushes an EVENT packet (WHOOP's strap-as-clock catch-up signal). The
    /// connection manager wires this to a rate-limited `requestSync(.strap)`. nil in pure/unit contexts.
    var onSyncTrigger: (() -> Void)?

    public init(state: BLEDeviceState) {
        self.state = state
    }

    /// Handle one complete frame (bytes including 0xAA SOF and the crc32 trailer).
    public func handle(frame: [UInt8]) {
        let parsed = parseFrame(frame)
        guard parsed.ok else { return }
        // Reject frames that failed their checksum — never let bad bytes drive state.
        if parsed.crcOK == false { return }

        state.lastFrameType = parsed.typeName

        switch parsed.typeName {
        case "REALTIME_DATA":
            if let hr = parsed.parsed["heart_rate"]?.intValue {
                state.heartRate = hr
            }
            // The realtime stream usually reports rr_count=0; only update R-R when this frame
            // actually carries intervals, so we don't wipe R-R sourced from the 0x2A37 profile.
            if let rr = parsed.parsed["rr_intervals"]?.intArrayValue, !rr.isEmpty {
                state.rr = rr
            }

        case "COMMAND_RESPONSE":
            if let pct = parsed.parsed["battery_pct"]?.doubleValue {
                state.setBattery(pct)
            }
            if let fw = parsed.parsed["fw_harvard"]?.stringValue {
                state.fwVersionHarvard = fw
            }
            if let fw = parsed.parsed["fw_boylston"]?.stringValue {
                state.fwVersionBoylston = fw
            }
            if let name = parsed.parsed["advertising_name_harvard"]?.stringValue, !name.isEmpty {
                state.advertisingName = name
            }
            if let hello = parsed.parsed["hello_harvard"]?.stringValue, !hello.isEmpty {
                state.helloInfo = hello
            }

        case "EVENT":
            if let ev = parsed.parsed["event"]?.stringValue {
                state.lastEvent = ev
                // Strap-pushed event = "I may have new data" → kick a (rate-limited) sync.
                onSyncTrigger?()
                switch ev {
                case "BLE_BONDED":
                    state.bonded = true
                case "CHARGING_ON":
                    state.isCharging = true
                case "CHARGING_OFF":
                    state.isCharging = false
                case "WRIST_ON":
                    state.isOnWrist = true
                case "WRIST_OFF":
                    state.isOnWrist = false
                case "BATTERY_PACK_CONNECTED":
                    state.batteryPackConnected = true
                case "BATTERY_PACK_REMOVED":
                    state.batteryPackConnected = false
                default:
                    break
                }
            }
            // BATTERY_LEVEL event (~every 8 min) carries real vendor battery data parsed by PostHooks.
            if let pct = parsed.parsed["battery_pct"]?.doubleValue {
                state.setBattery(pct)
            }
            if let mv = parsed.parsed["battery_mV"]?.intValue {
                state.batteryMV = mv
            }
            if let ch = parsed.parsed["battery_charging"]?.intValue {
                state.isCharging = ch == 1
            }

        default:
            break
        }
    }
}
