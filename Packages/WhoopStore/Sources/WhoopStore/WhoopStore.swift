import Foundation
import GRDB
import WhoopProtocol

/// OpenWhoop persistence library — decoded streams are durable; raw frames are a
/// transient, compressed, prunable outbox. Built on GRDB/SQLite.
public enum WhoopStoreInfo {
    /// Bumped whenever the migrator gains a new migration.
    public static let schemaVersion = 15
}

/// WhoopStore is an `actor`: its public API is `async`, and all GRDB work runs on the
/// actor's serial executor rather than the caller's (the main actor). DatabaseQueue calls
/// are synchronous-blocking; the actor moves them off the main thread (it does not make them
/// non-blocking). That is the intended off-main win — DatabaseQueue kept, not DatabasePool.
public actor WhoopStore {
    let dbQueue: DatabaseQueue

    /// On-disk path of the SQLite file, or nil for an in-memory store. Exposed so a backup layer
    /// can snapshot the file after a WAL checkpoint.
    public let databasePath: String?

    private init(dbQueue: DatabaseQueue, path: String?) throws {
        self.dbQueue = dbQueue
        self.databasePath = path
        try WhoopStore.makeMigrator().migrate(dbQueue)
    }

    /// Open (creating if needed) a database at `path` and run migrations.
    /// Enables WAL journal mode and a 5-second busy timeout so two handles to the same
    /// file (BLEManager + MetricsRepository) don't deadlock on write contention.
    public init(path: String) async throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            // WAL + NORMAL: no fsync per commit (only at checkpoint). An app crash cannot lose
            // committed data; only an OS crash / power loss can drop the last few transactions,
            // and the strap-side trim is acked only after our commit so the strap re-sends them.
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        config.busyMode = .timeout(5)
        try self.init(dbQueue: try DatabaseQueue(path: path, configuration: config), path: path)
    }

    /// An in-memory store (migrations applied). For tests.
    public static func inMemory() async throws -> WhoopStore {
        try WhoopStore(dbQueue: try DatabaseQueue(), path: nil)
    }

    /// Flush the WAL into the main `.sqlite` file and truncate `-wal`/`-shm`, so a plain file copy
    /// of `databasePath` captures a complete, consistent snapshot. Non-blocking for the UI (runs on
    /// the actor's serial executor). Safe to call while connected — TRUNCATE waits for active readers.
    public func checkpoint() async throws {
        try syncWrite { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    // MARK: - Synchronous GRDB helpers
    // GRDB 6 marks its sync read/write overloads @_disfavoredOverload so that in an async
    // context Swift would otherwise pick the async overloads. These thin wrappers are
    // regular (non-async) functions, so overload resolution always selects the synchronous
    // GRDB API — which then blocks on the actor's serial executor (off main thread).

    @inline(__always)
    func syncRead<T>(_ block: (Database) throws -> T) throws -> T {
        try dbQueue.read(block)
    }

    /// Stable database identity, total input revision, and per-UTC-day revisions read in one
    /// SQLite snapshot. Derived tables and sync anchors deliberately do not change this token.
    public func inputRevisions() throws -> (instance: String, revision: Int, days: [String: Int]) {
        try syncRead { db in
            let meta = try Row.fetchOne(db, sql: "SELECT instance, revision FROM input_revision WHERE id = 1")!
            let rows = try Row.fetchAll(db, sql: "SELECT day, revision FROM input_day_revision")
            var days: [String: Int] = [:]
            for row in rows { days[row["day"]] = row["revision"] }
            return (meta["instance"], meta["revision"], days)
        }
    }

    @inline(__always)
    func syncWrite<T>(_ block: (Database) throws -> T) throws -> T {
        try dbQueue.write(block)
    }

    // MARK: - Introspection (used by tests)

    public func tableNames() async throws -> Set<String> {
        try syncRead { db in
            try Set(String.fetchAll(db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
        }
    }

    public func primaryKeyColumns(_ table: String) async throws -> [String] {
        try syncRead { db in
            try db.primaryKey(table).columns
        }
    }

    public func columnNamesForTest(table: String) async throws -> [String] {
        try syncRead { db in
            try db.columns(in: table).map(\.name)
        }
    }
}
