import Foundation

/// Strategy for routing actor IDs to shard indices.
///
/// Conforming types implement a deterministic mapping from string keys to shard
/// indices. The mapping must be stable across process restarts and identical
/// across nodes for the same configuration.
public protocol ShardRoutingStrategy: Sendable {
    /// The number of shards this strategy routes across.
    var shardCount: Int { get }

    /// Returns the shard index (0-based) for the given key.
    func shardID(for key: String) -> Int
}

/// Routes keys using `fnv1a(key) % shardCount`.
///
/// This is the legacy routing strategy. It's simple and fast, but remaps ~75%
/// of keys when adding a single shard to a 4-shard cluster. Use ``MaglevRouting``
/// for production deployments that may need to expand.
public struct ModuloRouting: ShardRoutingStrategy {
    public let shardCount: Int

    public init(shardCount: Int) {
        precondition(shardCount > 0, "shardCount must be positive")
        self.shardCount = shardCount
    }

    public func shardID(for key: String) -> Int {
        let hash = SQLiteShardManager.fnv1a(key)
        return Int(hash % UInt64(shardCount))
    }
}

/// Routes keys using Maglev consistent hashing.
///
/// When shards are added or removed, only ~1/(N+1) of keys remap. This makes
/// shard expansion operationally feasible without requiring a full data migration.
///
/// Shard names are generated as `shard-NNNN` (e.g., `shard-0000`, `shard-0001`)
/// matching the directory layout used by ``SQLiteShardManager``.
public struct MaglevRouting: ShardRoutingStrategy {
    public let shardCount: Int
    private let hasher: MaglevHasher

    /// Creates a Maglev routing strategy.
    ///
    /// - Parameters:
    ///   - shardCount: Number of shards to route across.
    ///   - tableSize: Prime lookup table size. Default 65537.
    public init(shardCount: Int, tableSize: Int = 65537) {
        precondition(shardCount > 0, "shardCount must be positive")
        self.shardCount = shardCount
        let names = (0..<shardCount).map { "shard-\(String(format: "%04d", $0))" }
        self.hasher = MaglevHasher(shardNames: names, tableSize: tableSize)
    }

    public func shardID(for key: String) -> Int {
        hasher.shardIndex(for: key)
    }
}
