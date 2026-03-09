import Foundation
import GRDB

/// Background actor that migrates cold actors from old shards to new shards
/// after a routing configuration change.
///
/// The sweeper iterates through each old shard in batches, checking whether
/// each actor's routing has changed under the new strategy. Actors that now
/// belong on a different shard are copied and cleaned up via
/// ``ShardedStateStore/migrateActorIfNeeded(_:)``.
///
/// The sweep is intentionally throttled with configurable delays between batches
/// to avoid starving normal read/write traffic.
public actor RoutingMigrationSweeper {
    private let shardedStore: ShardedStateStore
    private let oldShardPools: [Int: DatabasePool]
    private let oldRoutingStrategy: any ShardRoutingStrategy
    private let newRoutingStrategy: any ShardRoutingStrategy
    private let batchSize: Int
    private let delayBetweenBatches: Duration

    private var sweepTask: Task<Void, Error>?
    private var _migratedCount: Int = 0
    private var _scannedCount: Int = 0
    private var _isComplete: Bool = false

    /// Progress snapshot returned by ``progress()``.
    public struct SweepProgress: Sendable {
        public let migratedCount: Int
        public let scannedCount: Int
        public let isComplete: Bool
    }

    /// Creates a new migration sweeper.
    ///
    /// - Parameters:
    ///   - shardedStore: The store that owns the migration logic.
    ///   - oldShardPools: Map of old shard ID → DatabasePool for reading old data.
    ///   - oldRoutingStrategy: The routing strategy before the config change.
    ///   - newRoutingStrategy: The routing strategy after the config change.
    ///   - batchSize: Number of actors to process per batch. Default 100.
    ///   - delayBetweenBatches: Sleep duration between batches. Default 100ms.
    public init(
        shardedStore: ShardedStateStore,
        oldShardPools: [Int: DatabasePool],
        oldRoutingStrategy: any ShardRoutingStrategy,
        newRoutingStrategy: any ShardRoutingStrategy,
        batchSize: Int = 100,
        delayBetweenBatches: Duration = .milliseconds(100)
    ) {
        self.shardedStore = shardedStore
        self.oldShardPools = oldShardPools
        self.oldRoutingStrategy = oldRoutingStrategy
        self.newRoutingStrategy = newRoutingStrategy
        self.batchSize = batchSize
        self.delayBetweenBatches = delayBetweenBatches
    }

    /// Kicks off the background sweep task.
    public func start() {
        guard sweepTask == nil else { return }
        sweepTask = Task { [self] in
            try await self.runSweep()
        }
    }

    /// Cancels the sweep if running.
    public func cancel() {
        sweepTask?.cancel()
        sweepTask = nil
    }

    /// Returns the current sweep progress.
    public func progress() -> SweepProgress {
        SweepProgress(
            migratedCount: _migratedCount,
            scannedCount: _scannedCount,
            isComplete: _isComplete
        )
    }

    // MARK: - Private

    private func runSweep() async throws {
        for shardID in oldShardPools.keys.sorted() {
            guard let pool = oldShardPools[shardID] else { continue }
            try Task.checkCancellation()

            // Use cursor-based pagination (not OFFSET) since migration deletes rows.
            var lastActorID: String? = nil
            while true {
                try Task.checkCancellation()

                let cursor = lastActorID
                let currentBatchSize = batchSize

                // Fetch a batch of actor IDs from the old shard
                let actorIDs: [String]
                if let cursor {
                    actorIDs = try await pool.read { db in
                        try Row.fetchAll(db, sql: """
                            SELECT actorId FROM actor_state
                            WHERE actorId > ?
                            ORDER BY actorId
                            LIMIT ?
                            """, arguments: [cursor, currentBatchSize])
                            .map { $0["actorId"] as String }
                    }
                } else {
                    actorIDs = try await pool.read { db in
                        try Row.fetchAll(db, sql: """
                            SELECT actorId FROM actor_state
                            ORDER BY actorId
                            LIMIT ?
                            """, arguments: [currentBatchSize])
                            .map { $0["actorId"] as String }
                    }
                }

                if actorIDs.isEmpty { break }
                lastActorID = actorIDs.last

                for actorID in actorIDs {
                    try Task.checkCancellation()

                    let oldShard = oldRoutingStrategy.shardID(for: actorID)
                    let newShard = newRoutingStrategy.shardID(for: actorID)

                    _scannedCount += 1

                    if oldShard != newShard {
                        let didMigrate = try await shardedStore.migrateActorIfNeeded(actorID)
                        if didMigrate {
                            _migratedCount += 1
                        }
                    }
                }

                // Yield to normal operations
                try await Task.sleep(for: delayBetweenBatches)
            }
        }

        // All old shards swept — finalize
        _isComplete = true
        await shardedStore.completeMigration()
    }
}
