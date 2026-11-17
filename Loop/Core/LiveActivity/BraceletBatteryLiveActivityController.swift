import ActivityKit
import Foundation

@MainActor
final class BraceletBatteryLiveActivityController {
    private let lowBatteryThreshold = 5

    private var activity: Activity<BraceletBatteryActivityAttributes>?

    // Dernières entrées connues : la Live Activity combine batterie + sync en UNE activité,
    // donc on mémorise chaque source et on recalcule le `kind` à chaque mise à jour.
    private var lastBattery: Double?
    private var lastCharging: Bool?
    private var lastDeviceName: String?
    private var syncActive = false
    private var syncDetail: String?

    /// Entrée batterie (charge / batterie critique).
    func handleBatteryUpdate(
        batteryPercentage: Double?,
        isCharging: Bool?,
        deviceName: String?
    ) {
        lastBattery = batteryPercentage
        lastCharging = isCharging
        if let deviceName, !deviceName.isEmpty { lastDeviceName = deviceName }
        refresh()
    }

    /// Entrée sync : pipeline offload/upload/calcul actif, visible hors de l'app.
    func handleSyncUpdate(active: Bool, detail: String?) {
        syncActive = active
        syncDetail = detail
        refresh()
    }

    // MARK: - Recompute

    private func refresh() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let normalizedBattery = normalizedBatteryPercentage(lastBattery)
        guard let contentKind = preferredKind(batteryPercentage: normalizedBattery) else {
            endActivity()
            return
        }

        let contentState = BraceletBatteryActivityAttributes.ContentState(
            batteryPercentage: normalizedBattery,
            isCharging: lastCharging == true,
            kind: contentKind,
            syncDetail: contentKind == .syncing ? syncDetail : nil,
            updatedAt: Date()
        )

        if let activity {
            update(activity, with: contentState)
            return
        }

        if let existing = Activity<BraceletBatteryActivityAttributes>.activities.first {
            activity = existing
            update(existing, with: contentState)
            return
        }

        startActivity(
            deviceName: lastDeviceName?.isEmpty == false ? lastDeviceName! : "Bracelet",
            contentState: contentState
        )
    }

    /// Priorité d'affichage : batterie critique > sync en cours > charge > rien (fin).
    private func preferredKind(batteryPercentage: Int?) -> BraceletBatteryActivityAttributes.Kind? {
        if let batteryPercentage, batteryPercentage <= lowBatteryThreshold {
            return .lowBattery
        }
        if syncActive {
            return .syncing
        }
        if lastCharging == true {
            return .charging
        }
        return nil
    }

    private func startActivity(
        deviceName: String,
        contentState: BraceletBatteryActivityAttributes.ContentState
    ) {
        do {
            activity = try Activity.request(
                attributes: BraceletBatteryActivityAttributes(deviceName: deviceName),
                content: ActivityContent(state: contentState, staleDate: nil),
                pushType: nil
            )
        } catch {
            // ActivityKit can fail when Live Activities are disabled, restricted, or unavailable.
            activity = nil
        }
    }

    private func update(
        _ activity: Activity<BraceletBatteryActivityAttributes>,
        with contentState: BraceletBatteryActivityAttributes.ContentState
    ) {
        Task {
            await activity.update(ActivityContent(state: contentState, staleDate: nil))
        }
    }

    private func endActivity() {
        guard let activity else { return }
        self.activity = nil

        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func normalizedBatteryPercentage(_ value: Double?) -> Int? {
        guard let value, value.isFinite else { return nil }
        let percentage = value <= 1 ? value * 100 : value
        return Int(min(max(percentage, 0), 100).rounded())
    }
}
