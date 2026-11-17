import SwiftUI
import UniformTypeIdentifiers
import WhoopStore

/// Dedicated backup view (export/import `.loopbackup`). Reached from Profile → Données → Sauvegarde.
/// Extracted from the old `SettingsView.backupSection` so the Profile page stays scannable.
struct BackupView: View {
    @ObservedObject var repository: LoopDataRepository
    @ObservedObject var backup: BackupCoordinator
    @State private var exportURL: URL?
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var showVerifier = false
    @State private var showRestoreConfirm = false
    @EnvironmentObject private var connection: DeviceConnectionViewModel
    @State private var showHevyImporter = false
    @State private var hevyWorking = false
    @State private var hevyMessage: String?
    @State private var hevyFailed = false

    private var hairline: some View { ProfileHairline(inset: SettingsMetrics.hairlineInset) }

    var body: some View {
        ProfileSubpage {
            ProfileFootnote(text: NSLocalizedString("Exporte ta base locale (whoop.sqlite + cache) dans un fichier .loopbackup que tu peux ranger dans Fichiers ou iCloud Drive.", tableName: "Base", comment: ""))

            ProfileSection(title: NSLocalizedString("Exporter", tableName: "Base", comment: "")) {
                ProfileGroup {
                    switch backup.status {
                    case .preparing:
                        ProfileProgressRow(text: NSLocalizedString("Préparation de la sauvegarde…", tableName: "Base", comment: ""))
                    default:
                        Button {
                            Task {
                                if let url = await backup.prepareExport() {
                                    exportURL = url
                                    showExporter = true
                                }
                            }
                        } label: {
                            ProfileActionRow(icon: "square.and.arrow.up", title: NSLocalizedString("Exporter une sauvegarde", tableName: "Base", comment: ""))
                        }
                        .buttonStyle(.plain)
                        .disabled(repository.localMetricsEngine == nil)
                    }

                    switch backup.status {
                    case .error(let msg):
                        hairline
                        ProfileStatusRow(text: msg, symbol: "exclamationmark.triangle.fill", isError: true)
                    default:
                        if let at = backup.lastBackupAt {
                            hairline
                            ProfileStatusRow(text: String(format: NSLocalizedString("backup.last_prepared", tableName: "Base", comment: ""), at.formatted(date: .abbreviated, time: .shortened)),
                                             symbol: "checkmark.circle.fill")
                        }
                    }
                }
            }

            ProfileSection(title: NSLocalizedString("Importer depuis une autre application", tableName: "Base", comment: "")) {
                ProfileGroup {
                    NavigationLink {
                        NoopImportView(repository: repository)
                    } label: {
                        ProfileActionRow(icon: "arrow.down.doc", title: NSLocalizedString("Importer une sauvegarde Noop", tableName: "Base", comment: "")) {
                            ProfileChevron()
                        }
                    }
                    .buttonStyle(.plain)
                    hairline
                    hevyImportRow
                }
            }

            ProfileSection(title: NSLocalizedString("Restaurer", tableName: "Base", comment: "")) {
                ProfileGroup {
                    switch backup.status {
                    case .restoring:
                        ProfileProgressRow(text: NSLocalizedString("Restauration en cours — NE quitte PAS l'app", tableName: "Base", comment: ""))
                    default:
                        Button {
                            showRestoreConfirm = true
                        } label: {
                            ProfileActionRow(icon: "square.and.arrow.down", title: NSLocalizedString("Restaurer depuis un fichier", tableName: "Base", comment: ""))
                        }
                        .buttonStyle(.plain)
                        .confirmationDialog(
                            NSLocalizedString("Restaurer depuis un fichier ?", tableName: "Base", comment: ""),
                            isPresented: $showRestoreConfirm,
                            titleVisibility: .visible
                        ) {
                            Button(NSLocalizedString("Choisir un fichier…", tableName: "Base", comment: ""), role: .destructive) {
                                showImporter = true
                            }
                            Button(NSLocalizedString("Annuler", tableName: "Base", comment: ""), role: .cancel) {}
                        } message: {
                            Text(NSLocalizedString("Remplace toutes les données locales par le contenu du fichier choisi. Ne quitte pas l'app pendant la restauration.", tableName: "Base", comment: ""))
                        }
                    }
                }
            }

            ProfileSection(title: NSLocalizedString("Vérifier", tableName: "Base", comment: "")) {
                ProfileGroup {
                    Button {
                        showVerifier = true
                    } label: {
                        ProfileActionRow(icon: "checkmark.shield", title: NSLocalizedString("Vérifier une sauvegarde", tableName: "Base", comment: ""))
                    }
                    .buttonStyle(.plain)
                    .disabled(backup.isValidating)
                    if backup.isValidating {
                        hairline
                        ProfileProgressRow(text: NSLocalizedString("Vérification…", tableName: "Base", comment: ""))
                    }
                    if let message = backup.validationMessage {
                        hairline
                        ProfileStatusRow(text: message, symbol: "info.circle")
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("Sauvegarde", tableName: "Base", comment: ""))
        .fileImporter(isPresented: $showHevyImporter, allowedContentTypes: [.commaSeparatedText]) { result in
            switch result {
            case .success(let url): Task { await importHevy(from: url) }
            case .failure(let error):
                hevyFailed = true
                hevyMessage = String(format: NSLocalizedString("backup.import.error", tableName: "Base", comment: ""), error.localizedDescription)
            }
        }
        .sheet(isPresented: $showExporter) {
            if let url = exportURL {
                BackupExporter(url: url) {
                    showExporter = false
                    try? FileManager.default.removeItem(at: url)
                    exportURL = nil
                }
            }
        }
        .sheet(isPresented: $showImporter) {
            BackupImporter(
                onPick: { url in
                    showImporter = false
                    Task { await backup.importBackup(from: url) }
                },
                onCancel: { showImporter = false }
            )
        }
        .sheet(isPresented: $showVerifier) {
            BackupImporter(
                onPick: { url in
                    showVerifier = false
                    Task { await backup.validateBackup(from: url) }
                },
                onCancel: { showVerifier = false }
            )
        }
    }

    // MARK: - Import Hevy

    /// Bouton et bilan de l'import d'un export CSV Hevy (horaires des séances seulement).
    @ViewBuilder private var hevyImportRow: some View {
        Button {
            hevyMessage = nil
            showHevyImporter = true
        } label: {
            ProfileActionRow(icon: "dumbbell", title: NSLocalizedString("backup.hevy.button", tableName: "Base", comment: ""),
                             subtitle: NSLocalizedString("backup.hevy.footnote", tableName: "Base", comment: ""))
        }
        .buttonStyle(.plain)
        .disabled(hevyWorking || connection.bleManager.currentStore == nil)
        .accessibilityHint(NSLocalizedString("backup.hevy.hint", tableName: "Base", comment: ""))
        if hevyWorking {
            hairline
            ProfileProgressRow(text: NSLocalizedString("backup.hevy.working", tableName: "Base", comment: ""))
        }
        if let hevyMessage {
            hairline
            ProfileStatusRow(text: hevyMessage, symbol: hevyFailed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill", isError: hevyFailed)
        }
    }

    @MainActor private func importHevy(from url: URL) async {
        guard let store = connection.bleManager.currentStore else { return }
        hevyWorking = true
        hevyFailed = false
        hevyMessage = nil
        defer { hevyWorking = false }
        do {
            let decoded = try await Task.detached(priority: .utility) { () throws -> String? in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return HevyCSVParser.decode(try Data(contentsOf: url))
            }.value
            guard let text = decoded else {
                hevyFailed = true
                hevyMessage = NSLocalizedString("backup.hevy.encoding", tableName: "Base", comment: "")
                return
            }
            let report = try await HevyImportStore(store: store).importCSV(text, defaults: .standard)
            hevyMessage = String(format: NSLocalizedString("backup.hevy.result", tableName: "Base", comment: ""),
                                 report.inserted, report.updated, report.duplicates, report.skippedRows)
            if report.inserted + report.updated > 0 { repository.requestRefresh(force: true) }
        } catch let error as HevyCSVParser.ParseError {
            hevyFailed = true
            hevyMessage = error == .empty
                ? NSLocalizedString("backup.hevy.empty", tableName: "Base", comment: "")
                : NSLocalizedString("backup.hevy.notHevy", tableName: "Base", comment: "")
        } catch {
            hevyFailed = true
            hevyMessage = String(format: NSLocalizedString("backup.import.error", tableName: "Base", comment: ""), error.localizedDescription)
        }
    }
}
