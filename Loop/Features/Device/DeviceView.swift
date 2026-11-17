import SwiftUI

/// Device control page — calm, monochrome, hierarchical. Not a settings list and not a dashboard of
/// coloured tiles.
///
/// One quiet hero (band portrait + name + a single status dot), one foregrounded metric (battery),
/// one grouped block of secondary facts, one prominent action with quiet text actions beside it, and
/// a single door to the technical layer. The page exposes exactly one accent colour — the status dot.
///
/// All presentation flows through a `DeviceSnapshot` value built here, so each child component stays
/// previewable in every state.
struct DeviceView: View {
    @ObservedObject var repository: LoopDataRepository
    @EnvironmentObject private var connection: DeviceConnectionViewModel
    @EnvironmentObject private var coordinator: SyncCoordinator
    @ObservedObject private var prefs = UserPreferences.shared
    @EnvironmentObject private var router: AppRouter

    @State private var appeared = false

    var body: some View {
        NavigationStack {
            ScrollView {
                Group {
                    if snapshot.hasDevice {
                        connectedLayout
                    } else {
                        DeviceEmptyState(
                            isScanning: snapshot.connection == .scanning,
                            lastSyncText: snapshot.lastSyncedAt == nil ? nil : snapshot.lastSyncText,
                            onSearch: { connection.confirmPairing() }
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
            .background(LoopColor.bgBase.ignoresSafeArea())
            .navigationTitle(NSLocalizedString("Appareil", tableName: "Base", comment: ""))
            .task { await connection.bootstrap() }
            .refreshable { await repository.refresh() }
            .onAppear { withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) { appeared = true } }
            .navigationDestination(item: $router.deviceRoute) { route in
                switch route {
                case .advanced: DeviceAdvancedView(repository: repository, connection: connection)
                case .alarm: AlarmView()
                }
            }
        }
    }

    // MARK: - Connected layout

    private var connectedLayout: some View {
        VStack(spacing: 24) {
            staged(0) { DeviceHero(snapshot: snapshot) }

            staged(1) { DeviceBatteryCard(snapshot: snapshot) }

            staged(2) { alarmRow }

            if snapshot.strapNeedsReboot {
                staged(2) { strapStuckNote }
            }

            staged(3) { DeviceInfoGroup(snapshot: snapshot) }

            staged(4) {
                DeviceActions(
                    snapshot: snapshot,
                    onPrimary: primaryAction,
                    onToggleHR: { connection.setRealtimeHR(!connection.state.realtimeHROn) },
                    onDisconnect: { connection.bleManager.disconnect() }
                )
            }

            staged(5) {
                DeviceDetailsRow(firmware: snapshot.firmwareHarvard) { router.deviceRoute = .advanced }
            }

        }
    }

    /// Soft rise-and-settle entrance, cascaded by index.
    private func staged<Content: View>(_ index: Int, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 14)
            .animation(.spring(response: 0.5, dampingFraction: 0.85).delay(0.05 * Double(index)), value: appeared)
    }

    private var alarmRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "alarm.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(prefs.alarmEnabled ? Pop.green : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(NSLocalizedString("Réveil", tableName: "Base", comment: ""))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)
                Text(alarmStatus)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .deviceSurface()
        .pressable { router.deviceRoute = .alarm }
    }

    private var alarmStatus: String {
        guard prefs.alarmEnabled else { return NSLocalizedString("Désactivé", tableName: "Base", comment: "") }
        let time = String(format: "%02d:%02d", prefs.alarmHour, prefs.alarmMinute)
        return "\(time) · \(prefs.alarmWeekdaysSummary)"
    }

    private var strapStuckNote: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            Text(NSLocalizedString("Bracelet bloqué — redémarre-le manuellement (maintien du bouton).", tableName: "Base", comment: ""))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(16)
        .deviceSurface(cornerRadius: 18)
    }

    // MARK: - Snapshot mapping

    private var snapshot: DeviceSnapshot {
        DeviceSnapshot(
            deviceName: connection.state.discoveredDeviceName,
            connection: connectionStatus,
            sync: syncState,
            batteryPercent: normalizedBattery,
            isCharging: connection.state.isCharging == true,
            isOnWrist: connection.state.isOnWrist,
            realtimeHROn: connection.state.realtimeHROn,
            strapNeedsReboot: connection.state.strapNeedsReboot,
            lastSyncedAt: connection.state.lastSyncedAt.map { Date(timeIntervalSince1970: $0) },
            lastSampleAt: lastSampleDate,
            lastComputedAt: repository.cache.updatedAt,
            firmwareHarvard: connection.state.fwVersionHarvard,
            peripheralUUID: connection.state.peripheralUUID
        )
    }

    private var connectionStatus: DeviceSnapshot.Connection {
        if connection.state.connected, connection.state.bonded { return .connected }
        if connection.state.connected { return .connecting }
        if connection.phase == .scanning || connection.phase == .bonding { return .scanning }
        return .disconnected
    }

    private var syncState: DeviceSnapshot.Sync {
        switch coordinator.status {
        case .syncing(.fromStrap): return .syncing
        case .strapStuck:          return .stuck
        case .error(let msg):      return .error(msg)
        case .offline:             return .offline
        case .connectedIdle:       return .upToDate
        }
    }

    private var normalizedBattery: Int? {
        guard let pct = connection.state.batteryPct, pct.isFinite else { return nil }
        let percentage = pct <= 1 ? pct * 100 : pct
        return Int(min(max(percentage, 0), 100).rounded())
    }

    private var lastSampleDate: Date? {
        guard let ts = repository.dbStats?.latestTs else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ts))
    }

    // MARK: - Actions

    private func primaryAction() {
        if snapshot.connection.isLinked {
            connection.bleManager.requestSync(.manual)
        } else {
            connection.confirmPairing()
        }
    }
}

enum DeviceRoute: Hashable {
    case advanced
    case alarm
}

#Preview {
    DeviceView(repository: LoopDataRepository())
        .environmentObject(DeviceConnectionViewModel())
        .environmentObject(SmartAlarmController())
        .environmentObject(SyncCoordinator())
        .environmentObject(AppRouter())
}
