import Foundation
import CoreBluetooth
import WhoopProtocol

// MARK: - GATT UUIDs (copied from Loop/Core/BLE/BLEConnectionManager.swift)

enum StrapGATT {
    static let customService   = CBUUID(string: "61080001-8d6d-82b8-614a-1c8cb0f8dcc6")
    static let cmdWriteChar    = CBUUID(string: "61080002-8d6d-82b8-614a-1c8cb0f8dcc6") // CMD → strap
    static let cmdNotifyChar   = CBUUID(string: "61080003-8d6d-82b8-614a-1c8cb0f8dcc6") // responses
    static let eventNotifyChar = CBUUID(string: "61080004-8d6d-82b8-614a-1c8cb0f8dcc6") // events
    static let dataNotifyChar  = CBUUID(string: "61080005-8d6d-82b8-614a-1c8cb0f8dcc6") // data (frag)

    static let notifyChars: Set<CBUUID> = [cmdNotifyChar, eventNotifyChar, dataNotifyChar]

    /// "0005" for 61080005-…, the plain uuidString for anything else (e.g. "2A37").
    static func shortName(_ uuid: CBUUID) -> String {
        let s = uuid.uuidString.lowercased()
        if s.hasPrefix("6108"), s.count >= 8 {
            return String(s[s.index(s.startIndex, offsetBy: 4)..<s.index(s.startIndex, offsetBy: 8)])
        }
        return uuid.uuidString
    }
}

// MARK: - Commands (only the subset this tool sends; copied from Loop/Core/BLE/BLECommands.swift)

enum StrapCommand: UInt8 {
    case toggleRealtimeHR          = 3
    case reportVersionInfo         = 7
    case setClock                  = 10
    case getClock                  = 11
    case sendHistoricalData        = 22
    case historicalDataResult      = 23
    case getBatteryLevel           = 26
    case getDataRange              = 34
    case getHelloHarvard           = 35
    case sendR10R11Realtime        = 63
    case getAdvertisingNameHarvard = 76

    var label: String {
        switch self {
        case .toggleRealtimeHR:          return "Toggle Realtime HR"
        case .reportVersionInfo:         return "Report Version Info"
        case .setClock:                  return "Set Clock"
        case .getClock:                  return "Get Clock"
        case .sendHistoricalData:        return "Send Historical Data"
        case .historicalDataResult:      return "Historical Data Result"
        case .getBatteryLevel:           return "Get Battery Level"
        case .getDataRange:              return "Get Data Range"
        case .getHelloHarvard:           return "Get Hello (Harvard)"
        case .sendR10R11Realtime:        return "R10/R11 Realtime (raw stream)"
        case .getAdvertisingNameHarvard: return "Get Advertising Name (Harvard)"
        }
    }

    static let commandType: UInt8 = 35

    /// `[0xAA][len u16 LE][crc8(len)][type=35][seq][cmd][payload...][crc32 LE]`, len = inner + 4.
    func frame(seq: UInt8, payload: [UInt8]) -> [UInt8] {
        let inner: [UInt8] = [Self.commandType, seq, rawValue] + payload
        let length = UInt16(inner.count + 4)
        let lenBytes: [UInt8] = [UInt8(length & 0xFF), UInt8(length >> 8)]
        let trailer = crc32(inner)
        return [0xAA] + lenBytes + [crc8(lenBytes)] + inner + [
            UInt8(trailer & 0xFF), UInt8((trailer >> 8) & 0xFF),
            UInt8((trailer >> 16) & 0xFF), UInt8((trailer >> 24) & 0xFF),
        ]
    }

    /// SET_CLOCK(10) 8-byte form: [seconds u32 LE][subseconds u32 LE] (subseconds = 0).
    static func setClockPayload(now: UInt32 = UInt32(Date().timeIntervalSince1970)) -> [UInt8] {
        [UInt8(now & 0xFF), UInt8((now >> 8) & 0xFF),
         UInt8((now >> 16) & 0xFF), UInt8((now >> 24) & 0xFF),
         0, 0, 0, 0]
    }
}

func hex(_ bytes: [UInt8]) -> String {
    let digits: [Character] = Array("0123456789abcdef")
    var s = ""
    s.reserveCapacity(bytes.count * 2)
    for b in bytes {
        s.append(digits[Int(b >> 4)])
        s.append(digits[Int(b & 0x0F)])
    }
    return s
}
