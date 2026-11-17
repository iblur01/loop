import SwiftUI

/// Routeur de deep-links centralisé. Traduit les URLs `loop://` en sélection d'onglet + destination
/// de navigation, partagé via `@EnvironmentObject`. Les vues lisent et écrivent les mêmes routes, si
/// bien qu'un tap interne et un deep-link empruntent exactement le même chemin.
@MainActor
final class AppRouter: ObservableObject {
    @Published var tab: AppTab = .today
    @Published var todayPath = NavigationPath()
    @Published var deviceRoute: DeviceRoute?
    @Published var profileRoute: ProfileRoute?

    enum AppTab: String, CaseIterable {
        case today, device, profile
    }

    /// Parse `loop://device/alarm` → `tab = .device`, `deviceRoute = .alarm`.
    func handle(_ url: URL) {
        guard url.scheme == "loop" else { return }
        let host = url.host ?? ""
        let first = url.pathComponents.first { $0 != "/" }

        switch host {
        case "today":
            tab = .today
            todayPath = NavigationPath()
            switch first {
            case "sleep":     todayPath.append(MetricType.sleep)
            case "recovery":  todayPath.append(MetricType.recovery)
            case "strain":    todayPath.append(MetricType.strain)
            case "stress":    todayPath.append(TodayRoute.stress)
            case "heartrate": todayPath.append(TodayRoute.heartRate)
            case "alarm":     todayPath.append(TodayRoute.alarm)
            default: break
            }
        case "device":
            tab = .device
            switch first {
            case "advanced": deviceRoute = .advanced
            case "alarm":    deviceRoute = .alarm
            default:         deviceRoute = nil
            }
        case "profile":
            tab = .profile
            switch first {
            case "backup":   profileRoute = .backup
            case "advanced": profileRoute = .advanced
            default:         profileRoute = nil
            }
        default:
            break
        }
    }
}
