import SwiftUI
import WhoopStore

/// Imports data into the live store; it never replaces the user's Loop database.
struct NoopImportView: View {
    @ObservedObject var repository: LoopDataRepository
    @EnvironmentObject private var connection: DeviceConnectionViewModel
    @State private var showPicker = false
    @State private var showConfirmation = false
    @State private var showImportDetails = false
    @State private var importProgress: NoopImportProgress?
    @State private var working = false
    @State private var fileURL: URL?
    @State private var targetDeviceID: String?
    @State private var preview: NoopImportPreview?
    @State private var selectedDeviceID: String?
    @State private var report: NoopImportReport?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                Text(NSLocalizedString("Importe une sauvegarde Noop .noopbak ou une ancienne base .sqlite/.noopdb. Les données compatibles sont fusionnées avec celles de Loop ; les données existantes sont conservées.", tableName: "Base", comment: ""))
                    .font(.footnote).foregroundStyle(.secondary)
                Text(NSLocalizedString("Conserve ton fichier Noop d’origine : certains champs et mesures R-R ne peuvent pas encore être représentés dans Loop.", tableName: "Base", comment: ""))
                    .font(.footnote).foregroundStyle(.secondary)
                Text(NSLocalizedString("Pour une base SQLite en mode WAL, utilise un export .noopbak : le fichier seul peut ne pas contenir toutes les données.", tableName: "Base", comment: ""))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section(NSLocalizedString("Fichier Noop", tableName: "Base", comment: "")) {
                Button {
                    showPicker = true
                } label: {
                    Label(NSLocalizedString("Choisir une sauvegarde Noop", tableName: "Base", comment: ""), systemImage: "folder")
                }
                .disabled(working || connection.bleManager.currentStore == nil)
                if connection.bleManager.currentStore == nil {
                    Text(NSLocalizedString("La base locale n’est pas encore prête. Réessaie après l’ouverture de Loop.", tableName: "Base", comment: ""))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if working { ProgressView(NSLocalizedString("Traitement en cours…", tableName: "Base", comment: "")) }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.red)
                }
            }
            if let preview {
                Section(NSLocalizedString("Source dans la sauvegarde", tableName: "Base", comment: "")) {
                    Text(NSLocalizedString("Choisis l’identifiant de ton bracelet WHOOP dans Noop. N’importe pas une source Apple Health ou un autre appareil comme données du bracelet : leur provenance serait associée au bracelet Loop.", tableName: "Base", comment: ""))
                        .font(.footnote).foregroundStyle(.secondary)
                    ForEach(preview.devices, id: \.id) { device in
                        Button {
                            selectedDeviceID = device.id
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(device.id).font(.body)
                                    Text(device.counts.sorted { $0.key < $1.key }.map { "\($0.key) : \($0.value)" }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selectedDeviceID == device.id { Image(systemName: "checkmark.circle.fill") }
                            }
                        }
                        .disabled(working)
                    }
                    if preview.devices.isEmpty {
                        Text(NSLocalizedString("Aucune donnée compatible n’a été trouvée.", tableName: "Base", comment: "")).foregroundStyle(.secondary)
                    }
                    if !preview.unsupportedTables.isEmpty {
                        Text(String(format: NSLocalizedString("backup.noop.unsupported_categories", tableName: "Base", comment: ""), preview.unsupportedTables.sorted().joined(separator: ", ")))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if !preview.ignoredColumns.isEmpty {
                        Text(String(format: NSLocalizedString("backup.noop.unsupported_fields", tableName: "Base", comment: ""), preview.ignoredColumns.sorted().joined(separator: ", ")))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section(NSLocalizedString("Destination", tableName: "Base", comment: "")) {
                    Text(String(format: NSLocalizedString("backup.noop.destination_band", tableName: "Base", comment: ""), targetDeviceID ?? NSLocalizedString("indisponible", tableName: "Base", comment: "")))
                        .font(.footnote)
                    Button(NSLocalizedString("Importer les données sélectionnées", tableName: "Base", comment: "")) { showConfirmation = true }
                        .disabled(working || selectedDeviceID == nil || targetDeviceID == nil)
                }
            }

        }
        .navigationTitle(NSLocalizedString("Importer depuis Noop", tableName: "Base", comment: ""))
        .navigationBarBackButtonHidden(working)
        .navigationDestination(isPresented: $showImportDetails) { importDetails }
        .sheet(isPresented: $showPicker) {
            NoopBackupImporter(onPick: { url in
                showPicker = false
                Task { await prepare(url) }
            }, onCancel: { showPicker = false })
        }
        .confirmationDialog(NSLocalizedString("Fusionner ces données dans Loop ?", tableName: "Base", comment: ""), isPresented: $showConfirmation, titleVisibility: .visible) {
            Button(NSLocalizedString("Importer", tableName: "Base", comment: "")) {
                importProgress = nil
                report = nil
                errorMessage = nil
                working = true
                showImportDetails = true
                Task { await importSelected() }
            }
            Button(NSLocalizedString("Annuler", tableName: "Base", comment: ""), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("Vérifie que la source sélectionnée est bien ton bracelet WHOOP. Les données Loop existantes restent prioritaires et les collisions seront indiquées. Un recalcul des 60 derniers jours suivra ; il peut prendre du temps et consommer de l’énergie.", tableName: "Base", comment: ""))
        }
        .onDisappear {
            if !working && !showImportDetails { clearPreparedFile() }
        }
    }

    @MainActor private func prepare(_ picked: URL) async {
        guard let store = connection.bleManager.currentStore else { return }
        clearPreparedFile()
        working = true
        errorMessage = nil
        report = nil
        preview = nil
        selectedDeviceID = nil
        targetDeviceID = connection.bleManager.deviceId
        defer { working = false }
        do {
            let prepared = try await Task.detached(priority: .utility) {
                try NoopBackupFile.prepare(picked)
            }.value
            fileURL = prepared
            preview = try await store.inspectNoopDatabase(at: prepared)
        } catch {
            clearPreparedFile()
            errorMessage = error.localizedDescription
        }
    }

    @MainActor private func importSelected() async {
        guard let store = connection.bleManager.currentStore, let url = fileURL,
              let source = selectedDeviceID, let target = targetDeviceID else {
            working = false
            errorMessage = NSLocalizedString("La sauvegarde ou la base locale n’est plus disponible. Recommence la sélection.", tableName: "Base", comment: "")
            return
        }
        guard target == connection.bleManager.deviceId else {
            working = false
            errorMessage = NSLocalizedString("Le bracelet Loop a changé. Choisis à nouveau ta sauvegarde.", tableName: "Base", comment: "")
            return
        }
        working = true
        errorMessage = nil
        defer { working = false }
        do {
            let result = try await store.importNoopDatabase(at: url, sourceDeviceId: source, targetDeviceId: target) { update in
                Task { @MainActor in
                    if working && report == nil && errorMessage == nil { importProgress = update }
                }
            }
            report = result
            preview = nil
            clearPreparedFile()
            repository.requestRefresh(force: true)
        } catch {
            errorMessage = String(format: NSLocalizedString("backup.import.error", tableName: "Base", comment: ""), error.localizedDescription)
        }
    }

    private var importDetails: some View {
        List {
            Section {
                if let report {
                    Label(NSLocalizedString("Import terminé", tableName: "Base", comment: ""), systemImage: "checkmark.circle.fill")
                        .font(.headline).foregroundStyle(.green)
                    Text(NSLocalizedString("Les données compatibles ont été fusionnées avec celles de Loop.", tableName: "Base", comment: ""))
                        .font(.footnote).foregroundStyle(.secondary)
                    if let first = report.earliestTimestamp, let last = report.latestTimestamp {
                        Text(String(format: NSLocalizedString("backup.noop.source_period", tableName: "Base", comment: ""), Date(timeIntervalSince1970: TimeInterval(first)).formatted(date: .abbreviated, time: .omitted), Date(timeIntervalSince1970: TimeInterval(last)).formatted(date: .abbreviated, time: .omitted)))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else if let errorMessage {
                    Label(NSLocalizedString("Import interrompu", tableName: "Base", comment: ""), systemImage: "exclamationmark.triangle.fill")
                        .font(.headline).foregroundStyle(.red)
                    Text(errorMessage).font(.footnote)
                } else {
                    HStack(alignment: .center, spacing: 12) {
                        ProgressView()
                        VStack(alignment: .leading, spacing: 4) {
                            Text(progressTitle).font(.headline)
                            Text(NSLocalizedString("Garde Loop ouverte pendant l’import.", tableName: "Base", comment: ""))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if let progress = importProgress, let table = progress.table, progress.phase == .importing {
                        Text(String(format: NSLocalizedString("backup.import.progress", tableName: "Base", comment: ""), categoryName(table), String(progress.processed), String(progress.inserted), String(progress.skipped)))
                            .font(.footnote).foregroundStyle(.secondary)
                        Text(NSLocalizedString("Ces chiffres sont provisoires jusqu’à la validation de l’import.", tableName: "Base", comment: ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let report {
                Section(NSLocalizedString("Détail des données", tableName: "Base", comment: "")) {
                    ForEach(report.counts.keys.sorted(), id: \.self) { name in
                        if let count = report.counts[name] {
                            HStack(alignment: .firstTextBaseline) {
                                Text(categoryName(name))
                                Spacer()
                                Text(String(format: NSLocalizedString("backup.import.counts", tableName: "Base", comment: ""), String(count.inserted), String(count.skipped)))
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                            }.font(.subheadline)
                        }
                    }
                    Text(NSLocalizedString("Les données ignorées comprennent les doublons et les collisions de précision R-R. Les données Loop existantes ont été conservées.", tableName: "Base", comment: ""))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section(NSLocalizedString("Après l’import", tableName: "Base", comment: "")) {
                    Label(NSLocalizedString("Recalcul des 60 derniers jours demandé", tableName: "Base", comment: ""), systemImage: "clock.arrow.circlepath")
                    Text(NSLocalizedString("Les mesures plus anciennes restent enregistrées, mais leurs indicateurs ne sont pas recalculés automatiquement et peuvent ne pas être visibles. Le recalcul peut continuer après la fermeture de cet écran.", tableName: "Base", comment: ""))
                        .font(.footnote).foregroundStyle(.secondary)
                    Text(NSLocalizedString("Conserve ta sauvegarde Noop d’origine pour garder tous les champs et intervalles R-R.", tableName: "Base", comment: ""))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !report.unsupportedTables.isEmpty || !report.ignoredColumns.isEmpty {
                    Section(NSLocalizedString("Non importé", tableName: "Base", comment: "")) {
                        if !report.unsupportedTables.isEmpty {
                            Text(String(format: NSLocalizedString("backup.noop.categories", tableName: "Base", comment: ""), report.unsupportedTables.sorted().joined(separator: ", ")))
                        }
                        if !report.ignoredColumns.isEmpty {
                            Text(String(format: NSLocalizedString("backup.noop.fields", tableName: "Base", comment: ""), report.ignoredColumns.sorted().joined(separator: ", ")))
                        }
                    }.font(.footnote).foregroundStyle(.secondary)
                }
            }
            if !working {
                Section {
                    Button(report == nil ? NSLocalizedString("Retour", tableName: "Base", comment: "") : NSLocalizedString("Terminé", tableName: "Base", comment: "")) { showImportDetails = false }
                }
            }
        }
        .navigationTitle(NSLocalizedString("Détail de l’import", tableName: "Base", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(working)
    }

    private var progressTitle: String {
        guard let progress = importProgress else { return NSLocalizedString("Préparation de l’import…", tableName: "Base", comment: "") }
        switch progress.phase {
        case .validating: return NSLocalizedString("Vérification de la sauvegarde…", tableName: "Base", comment: "")
        case .importing: return NSLocalizedString("Import des données…", tableName: "Base", comment: "")
        case .committed: return NSLocalizedString("Finalisation de l’import…", tableName: "Base", comment: "")
        }
    }

    private func categoryName(_ table: String) -> String {
        switch table {
        case "hrSample": return NSLocalizedString("Fréquence cardiaque", tableName: "Base", comment: "")
        case "rrInterval": return NSLocalizedString("Intervalles R-R", tableName: "Base", comment: "")
        case "event": return NSLocalizedString("Événements", tableName: "Base", comment: "")
        case "battery": return NSLocalizedString("Batterie", tableName: "Base", comment: "")
        case "spo2Sample": return NSLocalizedString("Signal SpO₂", tableName: "Base", comment: "")
        case "skinTempSample": return NSLocalizedString("Température cutanée", tableName: "Base", comment: "")
        case "respSample": return NSLocalizedString("Signal respiratoire", tableName: "Base", comment: "")
        case "gravitySample": return NSLocalizedString("Mouvement", tableName: "Base", comment: "")
        case "rawBatch": return NSLocalizedString("Lots de données brutes", tableName: "Base", comment: "")
        default: return table
        }
    }

    @MainActor private func clearPreparedFile() {
        if let url = fileURL { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        fileURL = nil
    }
}
