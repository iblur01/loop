import SwiftUI

/// Presentation of the engine's heart-rate zones: 0 = below zone 1, then zones 1…5 (Karvonen,
/// heart-rate reserve). No bound is defined here — membership and minutes come from
/// LoopStrapEngine (`HeartRateZoneBreakdown`, same bounds as the cardio load). Monochrome ink
/// ramp shared through `LoopColor.zone(_:)`, always shown with the zone label.
enum HeartRateZone: Int, CaseIterable, Identifiable {
    case below = 0
    case zone1, zone2, zone3, zone4, zone5

    var id: Int { rawValue }

    var label: String {
        self == .below ? "Sous la zone 1" : "Zone \(rawValue)"
    }

    var shortLabel: String {
        self == .below ? "Sous Z1" : "Z\(rawValue)"
    }

    /// Shared Z0…Z5 ramp (spec design §2.3). Always paired with the zone label.
    var color: Color { LoopColor.zone(rawValue) }
}
