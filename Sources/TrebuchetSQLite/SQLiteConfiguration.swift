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

    public init(
        root: String = ".trebuchet/db",
        shardCount: Int = 1,
        mode: SQLiteMode = .persistentNodes
    ) {
        self.root = root
        self.shardCount = shardCount
        self.mode = mode
    }

    /// Create a configured GRDB DatabasePool for a given path
    public static func makeDatabasePool(path: String) throws -> DatabasePool {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA temp_store = MEMORY")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
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
