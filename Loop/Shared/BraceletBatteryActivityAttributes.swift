import ActivityKit
import Foundation

struct BraceletBatteryActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let batteryPercentage: Int?
        let isCharging: Bool
        let kind: Kind
        /// Texte de détail affiché quand `kind == .syncing` (ex: "Calcul local du sommeil").
        var syncDetail: String? = nil
        let updatedAt: Date
    }

    enum Kind: String, Codable, Hashable {
        case charging
        case lowBattery
        /// Pipeline de synchronisation/calcul actif — visible hors de l'app.
        case syncing
    }

    let deviceName: String
}
