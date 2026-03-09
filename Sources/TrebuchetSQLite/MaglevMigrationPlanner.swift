import Foundation

/// Describes an actor that needs to move between shards during a routing change.
public struct ActorMigration: Sendable, Equatable {
    /// The actor ID that needs to move.
    public let actorID: String
    /// The shard index the actor is currently stored in.
    public let fromShard: Int
    /// The shard index the actor should move to.
    public let toShard: Int

    public init(actorID: String, fromShard: Int, toShard: Int) {
        self.actorID = actorID
        self.fromShard = fromShard
        self.toShard = toShard
    }
}

/// Summary of slot-level changes between two Maglev tables.
public struct MaglevDiff: Sendable {
    /// Number of slots that changed shard assignment.
    public let slotsChanged: Int
    /// Total number of slots in the table.
    public let totalSlots: Int
    /// Fraction of slots that changed (0.0 to 1.0).
    public var changeRatio: Double {
        guard totalSlots > 0 else { return 0 }
        return Double(slotsChanged) / Double(totalSlots)
    }
}

/// Computes migration plans when shard count changes under Maglev routing.
///
/// Use this to understand the impact of a shard expansion before committing
/// to it, and to generate the list of actors that need to be moved.
public struct MaglevMigrationPlanner: Sendable {
    /// The Maglev table size to use for comparison.
    public let tableSize: Int

    public init(tableSize: Int = 65537) {
        self.tableSize = tableSize
    }

    /// Compute the slot-level diff between two shard counts.
    ///
    /// This shows how many lookup table slots change assignment, which is
    /// proportional to how many actors will need to migrate.
    public func diff(oldShardCount: Int, newShardCount: Int) -> MaglevDiff {
        let oldHasher = MaglevHasher(
            shardNames: shardNames(count: oldShardCount),
            tableSize: tableSize
        )
        let newHasher = MaglevHasher(
            shardNames: shardNames(count: newShardCount),
            tableSize: tableSize
        )

        var changed = 0
        for i in 0..<tableSize {
            if oldHasher.lookupTable[i] != newHasher.lookupTable[i] {
                changed += 1
            }
        }

        return MaglevDiff(slotsChanged: changed, totalSlots: tableSize)
    }

    /// Compute which actors need to migrate when changing shard count.
    ///
    /// - Parameters:
    ///   - actorIDs: All known actor IDs to check.
    ///   - oldShardCount: Current number of shards.
    ///   - newShardCount: Target number of shards.
    /// - Returns: List of actors whose shard assignment changes.
    public func actorsToMigrate(
        actorIDs: [String],
        oldShardCount: Int,
        newShardCount: Int
    ) -> [ActorMigration] {
        let oldHasher = MaglevHasher(
            shardNames: shardNames(count: oldShardCount),
            tableSize: tableSize
        )
        let newHasher = MaglevHasher(
            shardNames: shardNames(count: newShardCount),
            tableSize: tableSize
        )

        var migrations: [ActorMigration] = []
        for id in actorIDs {
            let oldShard = oldHasher.shardIndex(for: id)
            let newShard = newHasher.shardIndex(for: id)
            if oldShard != newShard {
                migrations.append(ActorMigration(
                    actorID: id,
                    fromShard: oldShard,
                    toShard: newShard
                ))
            }
        }
        return migrations
    }

    private func shardNames(count: Int) -> [String] {
        (0..<count).map { "shard-\(String(format: "%04d", $0))" }
    }
}
