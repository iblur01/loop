import Foundation
import WhoopProtocol

/// Loop reuses `WhoopProtocol.Reassembler` directly for BLE fragment reassembly — it already is a
/// pure, unit-tested type (`Packages/WhoopProtocol/Sources/WhoopProtocol/Framing.swift`,
/// covered by `ReassemblerTests`) with no CoreBluetooth dependency.
///
/// `BLEFrameReassembler` is a thin type alias so call sites in `Core/BLE/` read naturally
/// (`BLEFrameReassembler()`) without duplicating the implementation.
public typealias BLEFrameReassembler = Reassembler
