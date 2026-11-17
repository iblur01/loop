import Foundation
import GRDB

/// Read-only checks for an exported backup. Passing these checks does not restore a backup or
/// prove that every application-level value is valid.
public enum BackupValidation {
    public enum Failure: LocalizedError {
        case invalidPackage(String)
        public var errorDescription: String? {
            switch self { case .invalidPackage(let reason): return reason }
        }
    }

    public struct Result: Equatable {
        public let schemaVersion: Int
        public let hasCache: Bool
    }

    public static func validate(package: URL) throws -> Result {
        let fm = FileManager.default
        let metaURL = package.appendingPathComponent("meta.json")
        let dbURL = package.appendingPathComponent("whoop.sqlite")
        guard fm.fileExists(atPath: metaURL.path), fm.fileExists(atPath: dbURL.path) else {
            throw Failure.invalidPackage("Sauvegarde invalide : métadonnées ou base manquantes.")
        }
        let metadata: [String: Any]
        do {
            guard let json = try JSONSerialization.jsonObject(with: Data(contentsOf: metaURL)) as? [String: Any] else {
                throw Failure.invalidPackage("Métadonnées de sauvegarde invalides.")
            }
            metadata = json
        } catch {
            throw Failure.invalidPackage("Métadonnées de sauvegarde illisibles.")
        }
        guard let schema = metadata["schemaVersion"] as? Int, schema > 0,
              schema <= WhoopStoreInfo.schemaVersion else {
            throw Failure.invalidPackage("Version de sauvegarde invalide ou plus récente que l'application.")
        }
        let cache = package.appendingPathComponent("cache.json")
        let hasCache = fm.fileExists(atPath: cache.path)
        if hasCache {
            do {
                guard try JSONSerialization.jsonObject(with: Data(contentsOf: cache)) is [String: Any] else {
                    throw Failure.invalidPackage("Cache invalide.")
                }
            } catch { throw Failure.invalidPackage("Cache de sauvegarde illisible.") }
        }
        // Validate a temporary copy: SQLite may create sidecars even for a read-only WAL database.
        // Backups produced by Loop are standalone snapshots, so sidecars indicate an incomplete or
        // foreign package and must not be ignored.
        guard !fm.fileExists(atPath: dbURL.path + "-wal"),
              !fm.fileExists(atPath: dbURL.path + "-shm") else {
            throw Failure.invalidPackage("La sauvegarde contient des fichiers SQLite annexes non pris en charge.")
        }
        let temporary = fm.temporaryDirectory.appendingPathComponent("loop-backup-check-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: temporary) }
        let copiedDB = temporary.appendingPathComponent("whoop.sqlite")
        do { try fm.copyItem(at: dbURL, to: copiedDB) }
        catch { throw Failure.invalidPackage("Base de sauvegarde illisible.") }
        var config = Configuration()
        config.prepareDatabase { db in try db.execute(sql: "PRAGMA query_only = ON") }
        let queue: DatabaseQueue
        do { queue = try DatabaseQueue(path: copiedDB.path, configuration: config) }
        catch { throw Failure.invalidPackage("Base de sauvegarde illisible : \(error.localizedDescription)") }
        do {
            try queue.read { db in
                guard try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok" else {
                    throw Failure.invalidPackage("Base de sauvegarde corrompue.")
                }
                let tables = try Set(String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
                let required: Set<String> = ["grdb_migrations", "device", "hrSample", "rrInterval", "event", "battery", "rawBatch"]
                guard required.isSubset(of: tables) else {
                    throw Failure.invalidPackage("Le fichier ne contient pas le schéma Loop attendu.")
                }
                let migrations = try Set(String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations"))
                let supported = Set((1...WhoopStoreInfo.schemaVersion).map { "v\($0)" })
                guard migrations.contains("v1"), migrations.isSubset(of: supported) else {
                    throw Failure.invalidPackage("La base utilise des migrations non reconnues.")
                }
            }
        } catch let error as Failure { throw error }
          catch { throw Failure.invalidPackage("Impossible de vérifier la base de sauvegarde.") }
        return Result(schemaVersion: schema, hasCache: hasCache)
    }
}
