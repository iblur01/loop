import SwiftUI
import Combine

struct MainTabView: View {
    @ObservedObject var repository: LoopDataRepository
    @EnvironmentObject private var connection: DeviceConnectionViewModel
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var coordinator: SyncCoordinator
    @EnvironmentObject private var syncToast: SyncToastCoordinator

    var body: some View {
        // iOS 26 : onglets `Tab(...)` en Liquid Glass natif, sans `UITabBarAppearance` ni flou UIKit,
        // et sans `.tint(.primary)` global qui éteignait l'accent de chaque page (spec design §4.2, §5.1).
        TabView(selection: $router.tab) {
            Tab(value: AppRouter.AppTab.today) {
                TodayView(repository: repository)
            } label: {
                Label(NSLocalizedString("Aujourd'hui", tableName: "Base", comment: ""), systemImage: "sun.max.fill")
            }

            Tab(value: AppRouter.AppTab.device) {
                DeviceView(repository: repository)
                    .appBackground()
            } label: {
                Label(NSLocalizedString("Appareil", tableName: "Base", comment: ""), systemImage: "applewatch")
            }

            Tab(value: AppRouter.AppTab.profile) {
                ProfileView(repository: repository)
                    .appBackground()
            } label: {
                Label(NSLocalizedString("Profil", tableName: "Base", comment: ""), systemImage: "person.crop.circle.fill")
            }
        }
        // La barre d'onglets se réduit en pastille quand on fait défiler vers le bas.
        .tabBarMinimizeBehavior(.onScrollDown)
        // Statut de sync dans l'accessoire natif de la barre (capsule verre système).
        .tabViewBottomAccessory(isEnabled: syncToast.isPresented) {
            SyncStatusAccessory(status: coordinator.status)
        }
        .onAppear { publishWidgetSnapshot() }
        .onChange(of: repository.cache) {
            publishWidgetSnapshot()
        }
        .onReceive(connection.state.$batteryPct.combineLatest(connection.state.$isCharging)
            .receive(on: DispatchQueue.main)) { _ in
            publishWidgetSnapshot()
        }
        .modifier(DeviceSheetModifier(connection: connection))
    }

    private func publishWidgetSnapshot() {
        LoopWidgetSnapshotStore.save(LoopWidgetSnapshotBuilder.make(
            cache: repository.cache,
            previous: LoopWidgetSnapshotStore.load(),
            battery: connection.state.batteryPct,
            isCharging: connection.state.isCharging == true,
            isPurging: repository.isPurging
        ))
    }
}

enum LoopWidgetSnapshotBuilder {
    static func make(cache: LoopCache, previous: LoopWidgetSnapshot, battery: Double?,
                     isCharging: Bool, isPurging: Bool) -> LoopWidgetSnapshot {
        let metric = cache.daily.max { $0.date < $1.date }
        let battery = normalizedBattery(battery)
        let awaitingCache = !isPurging && cache.updatedAt == nil && cache.daily.isEmpty
        return LoopWidgetSnapshot(
            sleep: awaitingCache ? previous.sleep : sleepMetric(from: metric),
            recovery: awaitingCache ? previous.recovery : recoveryMetric(from: metric),
            strain: awaitingCache ? previous.strain : strainMetric(from: metric),
            battery: battery == nil ? previous.battery : batteryMetric(battery, isCharging: isCharging),
            updatedAt: cache.updatedAt ?? previous.updatedAt
        )
    }

    private static func sleepMetric(from metric: DailySnapshot?) -> LoopWidgetSnapshot.Metric {
        let score = normalizedScore(metric?.sleepScore)
            ?? sleepDurationScore(totalSleepMin: metric?.totalSleepMin, targetMin: metric?.sleepTargetMin)
            ?? normalizedScore(metric?.efficiency)

        return LoopWidgetSnapshot.Metric(
            label: "Sleep",
            valueText: score.map { "\(Int($0.rounded()))%" } ?? "--",
            progress: (score ?? 0) / 100,
            tintHex: Metric.sleep.token.lightHex
        )
    }

    private static func recoveryMetric(from metric: DailySnapshot?) -> LoopWidgetSnapshot.Metric {
        let score = normalizedScore(metric?.recovery)

        return LoopWidgetSnapshot.Metric(
            label: "Recovery",
            valueText: score.map { "\(Int($0.rounded()))%" } ?? "--",
            progress: (score ?? 0) / 100,
            // Récupération = métrique d'état : la couleur suit le score (spec design §2.3, Q5).
            tintHex: Metric.recovery.token(for: score).lightHex
        )
    }

    private static func strainMetric(from metric: DailySnapshot?) -> LoopWidgetSnapshot.Metric {
        let strain = metric?.strain

        return LoopWidgetSnapshot.Metric(
            label: "Strain",
            valueText: strain.map { String(format: "%.1f", $0) } ?? "--",
            progress: min(max((strain ?? 0) / 21, 0), 1),
            tintHex: Metric.strain.token.lightHex
        )
    }

    private static func batteryMetric(_ battery: Int?, isCharging: Bool) -> LoopWidgetSnapshot.Metric {
        let tintHex = Metric.batteryState(percent: battery, isCharging: isCharging).token.lightHex

        return LoopWidgetSnapshot.Metric(
            label: "Battery",
            valueText: battery.map { "\($0)%" } ?? "--",
            progress: Double(battery ?? 0) / 100,
            tintHex: tintHex
        )
    }

    private static func normalizedBattery(_ value: Double?) -> Int? {
        guard let value, value.isFinite else { return nil }
        let percentage = value <= 1 ? value * 100 : value
        return Int(min(max(percentage, 0), 100).rounded())
    }

    private static func normalizedScore(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        if value <= 1 { return min(max(value * 100, 0), 100) }
        return min(max(value, 0), 100)
    }

    private static func sleepDurationScore(totalSleepMin: Double?, targetMin: Double?) -> Double? {
        guard
            let totalSleepMin,
            let targetMin,
            totalSleepMin.isFinite,
            targetMin.isFinite,
            targetMin > 0
        else { return nil }

        return min(max(totalSleepMin / targetMin * 100, 0), 100)
    }
}

#Preview {
    MainTabView(repository: LoopDataRepository())
        .environmentObject(DeviceConnectionViewModel())
        .environmentObject(SmartAlarmController())
        .environmentObject(AppRouter())
        .environmentObject(SyncCoordinator())
        .environmentObject(SyncToastCoordinator())
}
