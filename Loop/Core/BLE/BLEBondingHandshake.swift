import Foundation
import CoreBluetooth
import WhoopProtocol
import WhoopStore

/// Drives the WHOOP 4.0 bonding + post-bond handshake sequence.
///
/// `BLEConnectionManager` owns the peripheral/characteristics; this type only issues commands
/// through the `send` closure it is given and reports state changes back via its callbacks.
/// Kept separate from `BLEConnectionManager` so the (delicate, order-sensitive) bonding sequence
/// is easy to read and reason about in isolation.
@MainActor
final class BLEBondingHandshake {
    /// Sends a framed command. Mirrors `BLEConnectionManager.send`.
    private let send: (_ command: WhoopCommand, _ payload: [UInt8], _ writeType: CBCharacteristicWriteType) -> Void
    private let log: (String) -> Void

    /// True once the confirmed bonding write has been acknowledged (no error).
    private(set) var didBond = false
    /// True once GET_CLOCK has been requested for this connection (avoids re-sending).
    private(set) var clockRequested = false
    /// Runs the connect handshake EXACTLY ONCE per connection. `didWriteValueFor` re-fires on every
    /// `.withResponse` write (the bond write, every SEND_HISTORICAL, every HISTORY_END ack); without
    /// this guard those re-entries re-blasted hello/SET_CLOCK at the strap mid-offload and stopped it
    /// from streaming type-47 — THE iOS "won't serve" root cause. Reset on disconnect.
    private(set) var connectHandshakeDone = false

    /// Called once the post-bond handshake has fully run, so the connection manager can kick off
    /// the initial backfill + start the periodic timers.
    var onHandshakeComplete: (() -> Void)?
    /// Called when GET_CLOCK should be requested (payload is empty per strap quirk).
    var onClockRequestNeeded: (() -> Void)?

    init(send: @escaping (_ command: WhoopCommand, _ payload: [UInt8], _ writeType: CBCharacteristicWriteType) -> Void,
         log: @escaping (String) -> Void) {
        self.send = send
        self.log = log
    }

    /// Reset all per-connection flags. Called on disconnect.
    func reset() {
        didBond = false
        clockRequested = false
        connectHandshakeDone = false
    }

    /// THE BONDING TRICK: issue one confirmed write to trigger just-works bonding.
    /// GET_BATTERY_LEVEL is benign and what the Mac prototype uses.
    func beginBonding() {
        log("Bonding: confirmed write GET_BATTERY_LEVEL to 61080002")
        send(.getBatteryLevel, [0x00], .withResponse)
    }

    /// Confirmed-write completion handler. Marks bonding done on first call (no error), then —
    /// exactly once per connection — runs the post-bond handshake (hello, SET_CLOCK, GET_CLOCK,
    /// stop realtime-raw flood, GET_DATA_RANGE) and signals completion so the connection manager
    /// can schedule the initial backfill and start the periodic timers.
    ///
    /// `clockRef == nil` gates the GET_CLOCK request: the strap expects GET_CLOCK with an EMPTY
    /// payload (the old default `[0x00]` is a wrong length the strap ignores).
    func didWriteValue(error: Error?, hasClockRef: Bool) {
        if let error {
            log("Confirmed write failed: \(error.localizedDescription)")
            return
        }
        if !didBond {
            didBond = true
            log("BONDED (confirmed write acknowledged) — custom channels should now flow")
        }
        guard !connectHandshakeDone else { return }
        connectHandshakeDone = true

        // WHOOP-faithful connect lifecycle: hello → set RTC, then offload. Hello is NOT strictly
        // required to serve — verified on this strap via the Mac ground-truth test: plain
        // SEND_HISTORICAL_DATA serves type-47 with no hello and no high-freq-sync. We still
        // exchange hello to mirror WHOOP exactly.
        send(.getHelloHarvard, [0x00], .withoutResponse)
        send(.getAdvertisingNameHarvard, [0x00], .withoutResponse)
        send(.reportVersionInfo, [0x00], .withoutResponse)   // firmware versions for the Device page
        send(.setClock, BLEBondingHandshake.setClockPayload(), .withoutResponse)
        if !hasClockRef && !clockRequested {
            clockRequested = true
            onClockRequestNeeded?()
        }
        send(.sendR10R11Realtime, [0x00], .withoutResponse)  // stop the type-43 raw flood (heavy, unused)
        send(.getDataRange, [0x00], .withoutResponse)        // refresh stored range for the watchdog
        // NOTE: the type-40 REALTIME_DATA stream (live HR + R-R) is NOT enabled here — it drains the
        // strap battery. It's opt-in via BLEConnectionManager.setRealtimeHR(true); the connection
        // manager re-arms it on each connect only while the user has it switched on.

        onHandshakeComplete?()
    }

    /// SET_CLOCK(10) payload = the strap's 8-byte form: [seconds u32 LE][subseconds
    /// u32 LE], subseconds in 1/32768 s (0 is fine). NOT the old 9-byte [u32 + 5 pad] — a wrong-length
    /// SET_CLOCK is ack-received but NOT latched, leaving the RTC lost so the strap won't serve type-47.
    static func setClockPayload(now: UInt32 = UInt32(Date().timeIntervalSince1970)) -> [UInt8] {
        [UInt8(now & 0xFF), UInt8((now >> 8) & 0xFF),
         UInt8((now >> 16) & 0xFF), UInt8((now >> 24) & 0xFF),
         0, 0, 0, 0]
    }
}
