import Foundation
import CoreBluetooth
import WhoopProtocol

func log(_ message: String) {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    print("[\(f.string(from: Date()))] \(message)")
}

// MARK: - StrapSession

/// One capture session: scan → connect → bond → handshake (once) → SEND_HISTORICAL (once) →
/// capture every notification durably → ACK each HISTORY_END only after it is on disk.
///
/// Everything (CoreBluetooth delegate, timers, signal handlers) runs on the main queue, so
/// callbacks are strictly serial: by the time a HISTORY_END is processed, every earlier
/// notification has already been written + fsync'd.
final class StrapSession: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    struct Options {
        var outPath: String
        var ack: Bool
        var idleTimeout: TimeInterval
    }

    private let options: Options
    private let capture: CaptureFile
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var cmdChar: CBCharacteristic?
    private var reassemblers: [CBUUID: Reassembler] = [:]
    private var seq: UInt8 = 0

    private var bondRequested = false
    private var handshakeDone = false
    private var offloadStarted = false
    private var ended = false
    private var realtimeHRSeen = false

    private var chunkIndex = 0
    private var chunkFrames = 0
    private var totalNotifications = 0
    private var totalFrames = 0
    private var framesByType: [UInt8: Int] = [:]

    private var lastActivity = Date()
    private var idleTimer: DispatchSourceTimer?

    /// Delay between the end of the handshake and SEND_HISTORICAL, so the GET_DATA_RANGE response
    /// (and any type-40 realtime frame revealing an active HR stream) lands first.
    private static let settleDelay: TimeInterval = 1.5

    init(options: Options, capture: CaptureFile) {
        self.options = options
        self.capture = capture
        super.init()
    }

    func start() {
        let note = "strapcapture start ack=\(options.ack) idleTimeout=\(Int(options.idleTimeout))s"
        do { try capture.append([.init(kind: "session", char: "", hex: "", note: note)]) } catch {
            log("FATAL: cannot write capture file: \(error.localizedDescription)")
            exit(4)
        }
        log("Capture file: \(capture.path)")
        log("ACK HISTORY_END: \(options.ack ? "on" : "OFF (--no-ack)") · idle timeout: \(Int(options.idleTimeout)) s")
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - Termination

    func end(reason: String, code: Int32) {
        guard !ended else { return }
        ended = true
        idleTimer?.cancel()
        let types = framesByType.keys.sorted().map { "\($0):\(framesByType[$0]!)" }.joined(separator: " ")
        let summary = "chunks=\(chunkIndex) notifications=\(totalNotifications) frames=\(totalFrames) types=[\(types)]"
        try? capture.append([.init(kind: "session", char: "", hex: "", note: "end reason=\(reason) \(summary)")])
        capture.close()
        if let p = peripheral, central != nil { central.cancelPeripheralConnection(p) }
        log("session ended — reason=\(reason) · \(summary)")
        log("Capture file closed: \(capture.path)")
        exit(code)
    }

    private func armIdleTimer() {
        guard idleTimer == nil else { return }
        lastActivity = Date()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self, !self.ended else { return }
            if Date().timeIntervalSince(self.lastActivity) > self.options.idleTimeout {
                self.end(reason: "timeout", code: 1)
            }
        }
        idleTimer = t
        t.resume()
    }

    // MARK: - Send (durable tx line BEFORE every write)

    @discardableResult
    private func send(_ command: StrapCommand, payload: [UInt8],
                      writeType: CBCharacteristicWriteType, quiet: Bool = false) -> Bool {
        guard !ended, let p = peripheral, let ch = cmdChar else {
            log("send(\(command.label)) ignored — not connected")
            return false
        }
        seq = seq &+ 1
        let frame = command.frame(seq: seq, payload: payload)
        do {
            try capture.append([.init(kind: "tx", char: StrapGATT.shortName(ch.uuid), hex: hex(frame))])
        } catch {
            log("Capture write FAILED before \(command.label): \(error.localizedDescription) — nothing sent")
            end(reason: "capture_write_failed", code: 4)
            return false
        }
        p.writeValue(Data(frame), for: ch, type: writeType)
        if !quiet { log("→ \(command.label) payload=\(hex(payload))") }
        return true
    }

    // MARK: - Handshake / offload

    /// Exact order of Loop/Core/BLE/BLEBondingHandshake.swift; runs once per connection.
    private func runHandshake() {
        guard !handshakeDone else { return }
        handshakeDone = true
        log("Handshake: start")
        send(.getHelloHarvard, payload: [0x00], writeType: .withoutResponse)
        send(.getAdvertisingNameHarvard, payload: [0x00], writeType: .withoutResponse)
        send(.reportVersionInfo, payload: [0x00], writeType: .withoutResponse)
        send(.setClock, payload: StrapCommand.setClockPayload(), writeType: .withoutResponse)
        // No clock correlation in this tool → always "needed". Empty payload per strap quirk.
        send(.getClock, payload: [], writeType: .withoutResponse)
        send(.sendR10R11Realtime, payload: [0x00], writeType: .withoutResponse)
        send(.getDataRange, payload: [0x00], writeType: .withoutResponse)
        log("Handshake: done — offload in \(StrapSession.settleDelay) s")
        DispatchQueue.main.asyncAfter(deadline: .now() + StrapSession.settleDelay) { [weak self] in
            self?.startOffload()
        }
    }

    private func startOffload() {
        guard !ended, handshakeDone, !offloadStarted else { return }
        if realtimeHRSeen {
            log("Realtime HR stream active (type-40 seen) — turning it off")
            send(.toggleRealtimeHR, payload: [0x00], writeType: .withoutResponse)
        }
        offloadStarted = true
        chunkFrames = 0
        guard send(.sendHistoricalData, payload: [0x00], writeType: .withResponse) else { return }
        lastActivity = Date()
        log("Offload: started — historical offload requested")
    }

    // MARK: - Frame handling (after durable capture)

    private func handle(frame: [UInt8]) {
        guard frame.count > 4 else { return }
        let type = frame[4]
        totalFrames += 1
        framesByType[type, default: 0] += 1
        if type == 40 { realtimeHRSeen = true }
        guard offloadStarted else { return }

        switch type {
        case 47, 50:
            chunkFrames += 1
        case 49:
            switch classifyHistoricalMeta(parseFrame(frame)) {
            case .start:
                log("Offload: HISTORY_START")
            case .end(let unix, let trim):
                chunkIndex += 1
                let date = Date(timeIntervalSince1970: TimeInterval(unix))
                log("Chunk received n°\(chunkIndex) — frames=\(chunkFrames) trim=\(trim) unix=\(unix) (\(date))")
                chunkFrames = 0
                ackChunk(endFrame: frame, trim: trim)
            case .complete:
                log("Offload: HISTORY_COMPLETE")
                end(reason: "complete", code: 0)
            case .other:
                // A META frame the parser couldn't classify: flag it if the raw meta byte says END,
                // since that would mean a chunk we will NOT ack (strap will stall → timeout).
                if frame.count > 6, frame[6] == 2 {
                    log("WARNING: type-49 frame with meta byte 2 not classified as HISTORY_END — NOT acked")
                }
            }
        default:
            break
        }
    }

    /// The HISTORY_END line (and every line before it) is already fsync'd when we get here.
    private func ackChunk(endFrame: [UInt8], trim: UInt32) {
        guard endFrame.count >= 25 else {
            log("WARNING: HISTORY_END too short (\(endFrame.count) B) — NOT acked")
            return
        }
        guard options.ack else {
            log("ACK skipped (--no-ack) chunk n°\(chunkIndex)")
            return
        }
        let endData = Array(endFrame[17..<25])
        if send(.historicalDataResult, payload: [0x01] + endData, writeType: .withResponse, quiet: true) {
            log("ACK sent chunk n°\(chunkIndex) trim=\(trim) end_data=\(hex(endData))")
        }
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            let known = central.retrieveConnectedPeripherals(withServices: [StrapGATT.customService])
            if let p = known.first {
                log("Already-connected strap found: \(p.name ?? "?") \(p.identifier)")
                connect(p)
            } else {
                log("Scanning for service \(StrapGATT.customService)… (disconnect the iPhone first)")
                central.scanForPeripherals(withServices: [StrapGATT.customService],
                                           options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            }
        case .unauthorized:
            log("Bluetooth access denied (System Settings › Privacy & Security › Bluetooth)")
            end(reason: "bluetooth_unauthorized", code: 3)
        case .unsupported:
            end(reason: "bluetooth_unsupported", code: 3)
        case .poweredOff:
            log("Bluetooth is off — waiting")
        default:
            log("Bluetooth state=\(central.state.rawValue)")
        }
    }

    private func connect(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        central.connect(p, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard self.peripheral == nil else { return }
        central.stopScan()
        log("Found \(peripheral.name ?? "?") \(peripheral.identifier) RSSI=\(RSSI) — connecting")
        connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("Connected \(peripheral.name ?? "?")")
        armIdleTimer()
        peripheral.discoverServices([StrapGATT.customService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("Connect failed: \(error?.localizedDescription ?? "unknown")")
        end(reason: "connect_failed", code: 2)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        log("Disconnected: \(error?.localizedDescription ?? "no error")")
        end(reason: "disconnected", code: 2)
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { log("Service discovery failed: \(error.localizedDescription)"); return }
        for s in peripheral.services ?? [] where s.uuid == StrapGATT.customService {
            peripheral.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { log("Characteristic discovery failed: \(error.localizedDescription)"); return }
        for c in service.characteristics ?? [] {
            if c.uuid == StrapGATT.cmdWriteChar {
                cmdChar = c
            } else if StrapGATT.notifyChars.contains(c.uuid) {
                peripheral.setNotifyValue(true, for: c)
            }
        }
        guard cmdChar != nil, !bondRequested else { return }
        bondRequested = true
        // THE BONDING TRICK: one confirmed write triggers just-works bonding.
        log("Bonding: confirmed write GET_BATTERY_LEVEL to 61080002")
        send(.getBatteryLevel, payload: [0x00], writeType: .withResponse)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            log("Subscribe \(StrapGATT.shortName(characteristic.uuid)) failed: \(error.localizedDescription)")
        } else {
            log("Subscribed \(StrapGATT.shortName(characteristic.uuid))")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log("Confirmed write failed: \(error.localizedDescription)")
            if !handshakeDone { end(reason: "bond_failed", code: 2) }
            return
        }
        // Re-fires on every .withResponse write (SEND_HISTORICAL, each ACK): the guard inside
        // runHandshake() keeps hello/SET_CLOCK from ever being re-sent mid-offload.
        if !handshakeDone {
            log("BONDED (confirmed write acknowledged)")
            runHandshake()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard !ended, let data = characteristic.value else { return }
        let bytes = [UInt8](data)
        let now = Date()
        lastActivity = now
        totalNotifications += 1
        let charName = StrapGATT.shortName(characteristic.uuid)

        var lines: [CaptureFile.Line] = [.init(kind: "rx_raw", char: charName, hex: hex(bytes))]
        var frames: [[UInt8]] = []
        if StrapGATT.notifyChars.contains(characteristic.uuid) {
            let r: Reassembler
            if let existing = reassemblers[characteristic.uuid] {
                r = existing
            } else {
                r = Reassembler(validatesHeaderCRC: true)
                reassemblers[characteristic.uuid] = r
            }
            frames = r.feed(bytes)
            lines += frames.map { .init(kind: "rx_frame", char: charName, hex: hex($0)) }
        }

        // Durable FIRST. If this fails, nothing else (no ACK, no command) happens.
        do { try capture.append(lines, at: now) } catch {
            log("Capture write FAILED: \(error.localizedDescription)")
            end(reason: "capture_write_failed", code: 4)
            return
        }
        for f in frames { handle(frame: f) }
    }
}
