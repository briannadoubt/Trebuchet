import Foundation
import GRDB

/// Manages the shard directory layout for Trebuchet SQLite storage.
///
/// Directory structure:
/// ```
/// {root}/
///   shards/
///     shard-0000/main.sqlite
///     shard-0001/main.sqlite
///   metadata/
///     topology.json
/// ```
public actor SQLiteShardManager {
    private let configuration: SQLiteStorageConfiguration
    private var shardPools: [Int: DatabasePool] = [:]

    /// The number of shards managed by this instance.
    public var shardCount: Int { configuration.shardCount }

    public init(configuration: SQLiteStorageConfiguration) {
        self.configuration = configuration
    }

    /// Initialize the database directory layout and create shard files
    public func initialize() async throws {
        let root = configuration.root
        let shardsDir = "\(root)/shards"
        let metadataDir = "\(root)/metadata"

        try FileManager.default.createDirectory(atPath: shardsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: metadataDir, withIntermediateDirectories: true)

        for i in 0..<configuration.shardCount {
            let shardDir = "\(shardsDir)/shard-\(String(format: "%04d", i))"
            try FileManager.default.createDirectory(atPath: shardDir, withIntermediateDirectories: true)
        }
    }

    /// Open a shard's database pool
    public func openShard(_ shardID: Int) throws -> DatabasePool {
        if let existing = shardPools[shardID] {
            return existing
        }

        let path = shardPath(shardID)
        let pool = try SQLiteStorageConfiguration.makeDatabasePool(path: path, cacheSizeKB: configuration.cacheSizeKB)
        shardPools[shardID] = pool
        return pool
    }

    /// Close a shard's database pool
    public func closeShard(_ shardID: Int) {
        shardPools.removeValue(forKey: shardID)
    }

    /// Get the file path for a shard's database
    public func shardPath(_ shardID: Int) -> String {
        let shardName = "shard-\(String(format: "%04d", shardID))"
        return "\(configuration.root)/shards/\(shardName)/main.sqlite"
    }

    /// Determine which shard owns a given key using deterministic FNV-1a hashing.
    ///
    /// Uses FNV-1a (64-bit) instead of Swift's `Hasher` because `Hasher` is
    /// randomly seeded per process, which would break deterministic routing
    /// across restarts and between nodes.
    public func shardID(for key: String) -> Int {
        let hash = Self.fnv1a(key)
        return Int(hash % UInt64(configuration.shardCount))
    }

    /// FNV-1a 64-bit hash — stable, deterministic, and fast.
    internal static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325  // FNV offset basis
        let prime: UInt64 = 0x100000001b3       // FNV prime
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }

    /// Get status information for all shards
    public func status() throws -> [ShardStatus] {
        var statuses: [ShardStatus] = []
        let fm = FileManager.default

        for i in 0..<configuration.shardCount {
            let path = shardPath(i)
            let isOpen = shardPools[i] != nil
            var fileSize: UInt64 = 0
            var walSize: UInt64 = 0

            if let attrs = try? fm.attributesOfItem(atPath: path) {
                fileSize = attrs[.size] as? UInt64 ?? 0
            }

            let walPath = path + "-wal"
            if let attrs = try? fm.attributesOfItem(atPath: walPath) {
                walSize = attrs[.size] as? UInt64 ?? 0
            }

            statuses.append(ShardStatus(
                shardID: i,
                isOpen: isOpen,
                fileSizeBytes: fileSize,
                walSizeBytes: walSize,
                path: path
            ))
        }

        return statuses
    }

    /// Close all open shard pools
    public func shutdown() {
        shardPools.removeAll()
    }
}

/// Status of a single shard
public struct ShardStatus: Sendable {
    public let shardID: Int
    public let isOpen: Bool
    public let fileSizeBytes: UInt64
    public let walSizeBytes: UInt64
    public let path: String
}
