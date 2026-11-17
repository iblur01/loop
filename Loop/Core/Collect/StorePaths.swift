import Foundation

/// Filesystem locations for Loop's local store. Single source of truth shared by the SQLite store,
/// the JSON cache, and the iCloud backup layer — all live under `<AppSupport>/Loop/`.
enum StorePaths {
    /// `<AppSupport>/Loop/`, created if needed.
    static func baseDirectory() throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                              appropriateFor: nil, create: true)
            .appendingPathComponent("Loop", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// `<AppSupport>/Loop/whoop.sqlite` — the durable RAW store (never in an iCloud ubiquity
    /// container; backed up only via explicit snapshot + CKAsset).
    static func databaseFileURL() throws -> URL {
        try baseDirectory().appendingPathComponent("whoop.sqlite")
    }

    /// `<AppSupport>/Loop/whoop.sqlite` as a path string (GRDB takes a path, not a URL).
    static func defaultDatabasePath() throws -> String {
        try databaseFileURL().path
    }

    /// `<AppSupport>/Loop/cache.json` — the UI projection (instant restore, avoids a full recompute).
    static func cacheFileURL() throws -> URL {
        try baseDirectory().appendingPathComponent("cache.json")
    }
}
