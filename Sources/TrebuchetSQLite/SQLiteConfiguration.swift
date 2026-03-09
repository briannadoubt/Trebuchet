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

    /// Shard routing strategy.
    ///
    /// - `.modulo` — Legacy `fnv1a(key) % shardCount`. Simple but remaps ~75% of keys
    ///   when adding one shard to a 4-shard cluster.
    /// - `.maglev()` — Maglev consistent hashing. Only ~1/(N+1) of keys remap on expansion.
    ///   Default for new deployments.
    public var routing: RoutingMode

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
        routing: RoutingMode = .maglev(),
        cacheSizeKB: Int = 2048
    ) {
        self.root = root
        self.shardCount = shardCount
        self.mode = mode
        self.routing = routing
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

/// Shard routing mode.
public enum RoutingMode: Sendable, Equatable {
    /// Legacy modulo routing: `fnv1a(key) % shardCount`.
    case modulo
    /// Maglev consistent hashing with configurable table size.
    case maglev(tableSize: Int = 65537)

    /// The string identifier persisted in ownership metadata.
    public var persistedName: String {
        switch self {
        case .modulo: return "modulo"
        case .maglev: return "maglev"
        }
    }

    /// Reconstruct from a persisted name. Returns `.modulo` for nil (backward compat).
    public static func from(persistedName: String?) -> RoutingMode {
        switch persistedName {
        case "maglev": return .maglev()
        case "modulo", nil: return .modulo
        default: return .modulo
        }
    }

    /// Reconstruct the old routing mode from a persisted migration state.
    public static func from(migrationState: RoutingMigrationState) -> RoutingMode {
        switch migrationState.previousRoutingMode {
        case "maglev":
            return .maglev(tableSize: migrationState.previousTableSize ?? 65537)
        case "modulo":
            return .modulo
        default:
            return .modulo
        }
    }
}

/// SQLite operating mode
public enum SQLiteMode: String, Codable, Sendable, Hashable {
    /// Each node owns local shard files on durable disk
    case persistentNodes
    /// Nodes are mostly stateless, durable segments in object storage
    case portableLogs
}
