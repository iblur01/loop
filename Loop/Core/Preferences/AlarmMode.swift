import Foundation

/// Comment l'alarme se comporte sur le bracelet.
/// - `off`   : rien n'est armé.
/// - `regular` : alarme firmware RTC seule (garantie, vibre même app tuée).
/// - `smart` : firmware RTC + overlay smart-wake (flux HR dense sur une fenêtre avant l'heure cible).
enum AlarmMode: String, CaseIterable, Codable {
    case off
    case regular
    case smart

    var label: String {
        switch self {
        case .off:     return String(localized: "alarm.mode.off", table: "Core")
        case .regular: return String(localized: "alarm.mode.regular", table: "Core")
        case .smart:   return String(localized: "alarm.mode.smart", table: "Core")
        }
    }
}
