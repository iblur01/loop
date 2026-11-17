import SwiftUI
import UIKit

/// Technical/advanced device page. Hosts the firmware info, DB stats, sync details, diagnostic
/// report, and logs that used to live on the old `DeviceView`. Reached from DeviceView →
/// "Informations avancées". Nothing destructive here (those live in Profile → Advanced).
struct DeviceAdvancedView: View {
    @ObservedObject var repository: LoopDataRepository
    @ObservedObject var connection: DeviceConnectionViewModel
    @EnvironmentObject private var coordinator: SyncCoordinator
    @State private var didCopyReport = false

    var body: some View {
        List {
            Section(NSLocalizedString("Informations appareil", tableName: "Base", comment: "")) {
                statRow(NSLocalizedString("Nom", tableName: "Base", comment: ""), value: connection.state.discoveredDeviceName ?? "—")
                statRow(NSLocalizedString("Modèle", tableName: "Base", comment: ""), value: "WHOOP 4.0")
                statRow(NSLocalizedString("Identifiant local", tableName: "Base", comment: ""), value: connection.bleManager.deviceId)
                statRow(NSLocalizedString("UUID Bluetooth", tableName: "Base", comment: ""), value: connection.state.peripheralUUID ?? "—")
                statRow("Firmware (Harvard)", value: connection.state.fwVersionHarvard ?? "—")
                statRow("Firmware (Boylston)", value: connection.state.fwVersionBoylston ?? "—")
                if let advertising = connection.state.advertisingName, !advertising.isEmpty {
                    statRow(NSLocalizedString("Nom annoncé", tableName: "Base", comment: ""), value: advertising)
                }
                if let hello = connection.state.helloInfo, !hello.isEmpty {
                    statRow("Hello", value: hello)
                }
            }

            Section(NSLocalizedString("Base de données locale", tableName: "Base", comment: "")) {
                statRow(NSLocalizedString("Lignes décodées", tableName: "Base", comment: ""), value: formattedInt(repository.dbStats?.decodedRows ?? 0))
                statRow(NSLocalizedString("Lignes décodées total", tableName: "Base", comment: ""), value: formattedInt(repository.dbStats?.decodedRowsTotal ?? 0))
                statRow(NSLocalizedString("Batches bruts", tableName: "Base", comment: ""), value: formattedInt(repository.dbStats?.rawBatches ?? 0))
                statRow(NSLocalizedString("Stockage", tableName: "Base", comment: ""), value: formattedBytes(repository.dbStats?.rawBytes ?? 0))
                statRow(NSLocalizedString("Dernier échantillon HR", tableName: "Base", comment: ""), value: formattedDate(latestHRDate))
                statRow(NSLocalizedString("Jours calculés", tableName: "Base", comment: ""), value: formattedInt(repository.cache.daily.count))
                statRow(NSLocalizedString("Sessions sommeil", tableName: "Base", comment: ""), value: formattedInt(repository.cache.sleepSessions.count))
                statRow(NSLocalizedString("Sessions sport", tableName: "Base", comment: ""), value: formattedInt(repository.cache.workoutSessions.count))
            }

            Section(NSLocalizedString("Synchronisation & calcul", tableName: "Base", comment: "")) {
                statRow(NSLocalizedString("Dernier calcul local", tableName: "Base", comment: ""), value: formattedDate(repository.cache.updatedAt))
                statRow(NSLocalizedString("Dernier échantillon bracelet", tableName: "Base", comment: ""), value: formattedDate(lastBraceletSampleDate))
                statRow(NSLocalizedString("Dernière connexion bracelet", tableName: "Base", comment: ""), value: formattedDate(lastDeviceSyncDate))

                HStack {
                    Label(NSLocalizedString("État", tableName: "Base", comment: ""), systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    Text(syncStatusLabel)
                        .foregroundStyle(.secondary)
                }

                if repository.isRefreshing {
                    Text(NSLocalizedString("Actualisation…", tableName: "Base", comment: ""))
                }

                if let error = repository.lastError {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }

            Section(NSLocalizedString("Diagnostic", tableName: "Base", comment: "")) {
                Button {
                    let report = DiagnosticReport.make(
                        cache: repository.cache,
                        deviceId: connection.bleManager.deviceId,
                        dbStats: repository.dbStats
                    )
                    UIPasteboard.general.string = report
                    didCopyReport = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { didCopyReport = false }
                } label: {
                    Label(didCopyReport ? NSLocalizedString("Copié ✓", tableName: "Base", comment: "") : NSLocalizedString("Copier les données calculées", tableName: "Base", comment: ""),
                          systemImage: didCopyReport ? "checkmark.circle.fill" : "doc.on.doc")
                }
                Text(NSLocalizedString("Jours, nuits, siestes, exercices et stress en texte — pour repérer/partager une incohérence.", tableName: "Base", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(NSLocalizedString("Logs connexion", tableName: "Base", comment: "")) {
                if connection.state.log.isEmpty {
                    Text(NSLocalizedString("Aucun log encore", tableName: "Base", comment: ""))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(connection.state.log.suffix(30).reversed(), id: \.self) { line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("Informations avancées", tableName: "Base", comment: ""))
    }

    // MARK: - Helpers

    private var syncStatusLabel: String {
        switch coordinator.status {
        case .syncing(.fromStrap): return NSLocalizedString("Téléchargement bracelet…", tableName: "Base", comment: "")
        case .strapStuck: return NSLocalizedString("Bracelet bloqué", tableName: "Base", comment: "")
        case .error(let msg): return msg
        case .offline: return NSLocalizedString("Hors ligne", tableName: "Base", comment: "")
        case .connectedIdle: return NSLocalizedString("À jour", tableName: "Base", comment: "")
        }
    }

    private var lastDeviceSyncDate: Date? {
        guard let ts = connection.state.lastSyncedAt else { return nil }
        return Date(timeIntervalSince1970: ts)
    }

    private var latestHRDate: Date? {
        guard let ts = repository.dbStats?.latestTs else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ts))
    }

    private var lastBraceletSampleDate: Date? {
        guard let latest = repository.cache.hrSamples.map(\.ts).max() else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(latest))
    }

    private func statRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    private func formattedDate(_ date: Date?) -> String {
        guard let date else { return NSLocalizedString("Aucune", tableName: "Base", comment: "") }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func formattedInt(_ value: Int) -> String {
        value.formatted()
    }

    private func formattedBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
