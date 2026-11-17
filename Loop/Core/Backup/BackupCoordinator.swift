import Foundation
import WhoopStore
import SQLite3

// MARK: - BackupCoordinator

/// Sauvegarde/restaure les fichiers locaux (`whoop.sqlite` + `cache.json`) dans un **paquet de
/// sauvegarde** (`.loopbackup`) que l'utilisateur exporte/importe via l'app Fichiers (et qu'il peut
/// déposer dans son dossier iCloud Drive lui-même).
///
/// Choix volontaire : pas de CloudKit (réservé aux comptes Apple Developer payants). Le backup
/// fichier ne requiert **aucun entitlement** et reste un canal manuel optionnel — jamais une
/// dépendance de runtime. Le `whoop.sqlite` live reste sous `<AppSupport>/Loop/` ; on en fait un
/// snapshot SQLite cohérent, même si des écritures ont lieu pendant son export.
@MainActor
final class BackupCoordinator: ObservableObject {

    // MARK: - Status

    enum Status: Equatable {
        case idle
        case preparing   // construction du paquet d'export
        case restoring   // import + remplacement des fichiers locaux
        case error(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var lastBackupAt: Date?
    @Published private(set) var validationMessage: String?
    @Published private(set) var isValidating = false

    static let schemaKey = "schemaVersion"
    static let packageExtension = "loopbackup"

    private let deviceId: String

    // MARK: - Dépendances (closures : découplé de BLE / repository)

    private let storeProvider: () -> WhoopStore?
    private let suspend: () async -> Void
    private let resume: () async -> Void
    private let reloadCache: () async -> Void

    init(
        deviceId: String,
        store: @escaping () -> WhoopStore?,
        suspend: @escaping () async -> Void,
        resume: @escaping () async -> Void,
        reloadCache: @escaping () async -> Void
    ) {
        self.deviceId = deviceId
        self.storeProvider = store
        self.suspend = suspend
        self.resume = resume
        self.reloadCache = reloadCache
    }

    // MARK: - Export

    /// Construit un paquet `.loopbackup` (dossier) contenant `whoop.sqlite`, `cache.json` et
    /// `meta.json`, prêt à être exporté via le sélecteur Fichiers. Retourne l'URL du paquet
    /// temporaire (à exporter `asCopy`), ou nil en cas d'erreur.
    func prepareExport() async -> URL? {
        guard let store = storeProvider(), let dbPath = await store.databasePath else {
            status = .error(String(localized: "backup.database.unavailable", table: "Core"))
            return nil
        }
        status = .preparing
        do {
            // SQLite backup API captures a consistent snapshot even while writes continue.
            // 1. Paquet temporaire daté.
            let fm = FileManager.default
            let stamp = Self.fileStamp()
            let pkg = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("Loop-\(stamp).\(Self.packageExtension)", isDirectory: true)
            try? fm.removeItem(at: pkg)
            try fm.createDirectory(at: pkg, withIntermediateDirectories: true)

            let source = URL(fileURLWithPath: dbPath)
            let destination = pkg.appendingPathComponent("whoop.sqlite")
            try await Task.detached(priority: .utility) {
                try Self.snapshotDatabase(from: source, to: destination)
            }.value
            if let cacheURL = try? StorePaths.cacheFileURL(), fm.fileExists(atPath: cacheURL.path) {
                try fm.copyItem(at: cacheURL, to: pkg.appendingPathComponent("cache.json"))
            }
            let meta: [String: Any] = [
                Self.schemaKey: WhoopStoreInfo.schemaVersion,
                "deviceId": deviceId,
                "date": ISO8601DateFormatter().string(from: Date()),
            ]
            let metaData = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted])
            try metaData.write(to: pkg.appendingPathComponent("meta.json"))

            lastBackupAt = Date()
            status = .idle
            return pkg
        } catch {
            status = .error(error.localizedDescription)
            return nil
        }
    }

    // MARK: - Import / restore

    /// Restaure depuis un paquet `.loopbackup` choisi par l'utilisateur. SAFE : suspend le store,
    /// remplace les fichiers, rouvre. `picked` est une URL sécurisée (document picker).
    func importBackup(from picked: URL) async {
        status = .restoring
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        let sqliteSrc = picked.appendingPathComponent("whoop.sqlite")
        guard fm.fileExists(atPath: sqliteSrc.path) else {
            status = .error(String(localized: "backup.package.invalid", table: "Core"))
            return
        }

        // Garde-fou : ne pas restaurer un schéma plus récent que l'app (migrations forward-only).
        let metaURL = picked.appendingPathComponent("meta.json")
        if let data = try? Data(contentsOf: metaURL),
           let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let v = meta[Self.schemaKey] as? Int, v > WhoopStoreInfo.schemaVersion {
            status = .error(String(format: String(localized: "backup.schema.new", table: "Core"), v, WhoopStoreInfo.schemaVersion))
            return
        }

        let cacheSrc = picked.appendingPathComponent("cache.json")
        let hasCache = fm.fileExists(atPath: cacheSrc.path)

        // Fenêtre critique : store fermé → remplacement → réouverture. resume() doit TOUJOURS
        // s'exécuter, même si la copie échoue.
        await suspend()
        do {
            try replaceLocalFiles(sqlite: sqliteSrc, cache: hasCache ? cacheSrc : nil)
        } catch {
            await resume()
            status = .error(error.localizedDescription)
            return
        }
        await resume()
        await reloadCache()
        status = .idle
    }

    /// Checks a selected package without touching the live database or promising restoration.
    func validateBackup(from picked: URL) async {
        guard !isValidating else { return }
        isValidating = true
        validationMessage = nil
        let scoped = picked.startAccessingSecurityScopedResource()
        defer {
            if scoped { picked.stopAccessingSecurityScopedResource() }
            isValidating = false
        }
        do {
            let result = try await Task.detached(priority: .utility) {
                try BackupValidation.validate(package: picked)
            }.value
            validationMessage = String(format: String(localized: "backup.schema.valid", table: "Core"), result.schemaVersion)
        } catch {
            validationMessage = String(format: String(localized: "backup.validation.failed", table: "Core"), error.localizedDescription)
        }
    }

    // MARK: - Fichiers

    /// Create a transactionally consistent snapshot of a live SQLite database.
    nonisolated static func snapshotDatabase(from source: URL, to destination: URL) throws {
        var src: OpaquePointer?
        var dst: OpaquePointer?
        guard sqlite3_open_v2(source.path, &src, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let src { sqlite3_close(src) }
            throw BackupFileError.database(String(localized: "backup.database.open", table: "Core"))
        }
        defer { sqlite3_close(src) }
        guard sqlite3_open_v2(destination.path, &dst, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            if let dst { sqlite3_close(dst) }
            throw BackupFileError.database(String(localized: "backup.database.create", table: "Core"))
        }
        defer { sqlite3_close(dst) }
        guard let backup = sqlite3_backup_init(dst, "main", src, "main") else {
            throw BackupFileError.database(String(localized: "backup.database.prepare", table: "Core"))
        }
        let result = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finish == SQLITE_OK else {
            throw BackupFileError.database(String(format: String(localized: "backup.database.copy", table: "Core"), Int(result)))
        }
    }

    enum BackupFileError: LocalizedError {
        case database(String)
        var errorDescription: String? {
            switch self { case .database(let message): return message }
        }
    }

    /// Remplace `whoop.sqlite` (+ supprime -wal/-shm périmés) et `cache.json` par les versions
    /// importées. À n'appeler QUE store fermé (cf. `suspend()`).
    private func replaceLocalFiles(sqlite: URL, cache: URL?) throws {
        let fm = FileManager.default
        let dbURL = try StorePaths.databaseFileURL()
        for sidecar in ["", "-wal", "-shm"] {
            let u = URL(fileURLWithPath: dbURL.path + sidecar)
            if fm.fileExists(atPath: u.path) { try fm.removeItem(at: u) }
        }
        try fm.copyItem(at: sqlite, to: dbURL)

        if let cache {
            let cacheURL = try StorePaths.cacheFileURL()
            if fm.fileExists(atPath: cacheURL.path) { try fm.removeItem(at: cacheURL) }
            try fm.copyItem(at: cache, to: cacheURL)
        }
    }

    private static func fileStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return f.string(from: Date())
    }
}
