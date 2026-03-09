import Foundation
import GRDB

/// Configuration for Trebuchet's SQLite storage layer.
public struct SQLiteStorageConfiguration: Sendable {
    /// Root directory for database files
    public var root: String

    /// Number of shards (each gets its own SQLite file)
    public var shardCount: Int

    /// SQLite operating mode
    public var mode: SQLiteMode

    /// Maglev lookup table size. Must be prime. Default 65537.
    ///
    /// This controls the size of the consistent-hashing lookup table used to
    /// assign actor IDs to shards. Larger values give more uniform distribution
    /// but use more memory. The default is suitable for most deployments.
    public var maglevTableSize: Int

    /// Page cache size per connection in kilobytes.
    ///
    /// Each GRDB `DatabasePool` opens multiple connections (1 writer + up to 5
    /// readers by default), and every connection maintains its own page cache.
    /// With the SQLite default of ~2000 pages (≈8 MB), a 16-shard setup can
    /// use ~770 MB just for page caches.
    ///
    /// Tune this down for actor-state workloads that don't need large caches:
    /// - `2048` (default) — SQLite default, good for read-heavy analytical queries
    /// - `512` — ~2 MB per connection, reasonable for most Trebuchet workloads
    /// - `256` — ~1 MB per connection, minimal footprint
    public var cacheSizeKB: Int

    public init(
        root: String = ".trebuchet/db",
        shardCount: Int = 1,
        mode: SQLiteMode = .persistentNodes,
        maglevTableSize: Int = 65537,
        cacheSizeKB: Int = 2048
    ) {
        self.root = root
        self.shardCount = shardCount
        self.mode = mode
        self.maglevTableSize = maglevTableSize
        self.cacheSizeKB = cacheSizeKB
    }

    /// Create a configured GRDB DatabasePool for a given path
    public static func makeDatabasePool(path: String, cacheSizeKB: Int = 2048) throws -> DatabasePool {
        var config = Configuration()
        let cacheKB = cacheSizeKB
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA temp_store = MEMORY")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA cache_size = -\(cacheKB)")
        }

        // Ensure directory exists
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )

        return try DatabasePool(path: path, configuration: config)
    }
}

/// SQLite operating mode
public enum SQLiteMode: String, Codable, Sendable, Hashable {
    /// Each node owns local shard files on durable disk
    case persistentNodes
    /// Nodes are mostly stateless, durable segments in object storage
    case portableLogs
}
