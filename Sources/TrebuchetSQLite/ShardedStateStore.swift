import Foundation
import GRDB
import TrebuchetCloud

/// A sharding-aware ``ActorStateStore`` that automatically routes operations
/// to the correct shard based on actor ID.
///
/// This is the recommended way to use SQLite with multiple shards. It wraps
/// a ``SQLiteShardManager`` and ensures every read/write hits the correct
/// shard — making accidental cross-partition queries impossible.
///
/// During a routing migration (shard count or strategy change), the store
/// operates in **migration mode**: reads fall back to the old shard on miss,
/// writes clean up stale copies, and a background ``RoutingMigrationSweeper``
/// migrates cold actors.
public actor ShardedStateStore: ActorStateStore {
    private let shardManager: SQLiteShardManager
    private let newHasher: MaglevHasher
    private var storeCache: [Int: SQLiteStateStore] = [:]

    // MARK: - Migration State

    private var migrationState: RoutingMigrationState?
    private var oldHasher: MaglevHasher?
    private var oldShardPools: [Int: DatabasePool]?

    /// Whether the store is currently in migration mode.
    public var isMigrating: Bool { migrationState != nil }

    // MARK: - Initializers

    public init(shardManager: SQLiteShardManager) async {
        self.shardManager = shardManager
        self.newHasher = await shardManager.hasher
    }

    /// Creates a sharded store in migration mode.
    ///
    /// - Parameters:
    ///   - shardManager: The shard manager for the new configuration.
    ///   - migrationState: The persisted migration state from `ownership.json`.
    ///   - oldShardPools: Pre-opened pools for old shard files.
    ///   - oldShardCount: The shard count before the configuration change.
    ///   - oldTableSize: The Maglev table size before the change. Default 65537.
    public init(
        shardManager: SQLiteShardManager,
        migrationState: RoutingMigrationState,
        oldShardPools: [Int: DatabasePool],
        oldShardCount: Int,
        oldTableSize: Int = 65537
    ) async {
        self.shardManager = shardManager
        self.newHasher = await shardManager.hasher
        self.migrationState = migrationState
        self.oldShardPools = oldShardPools
        let names = (0..<oldShardCount).map { "shard-\(String(format: "%04d", $0))" }
        self.oldHasher = MaglevHasher(shardNames: names, tableSize: oldTableSize)
    }

    // MARK: - ActorStateStore Conformance

    public func load<State: Codable & Sendable>(
        for actorID: String,
        as type: State.Type
    ) async throws -> State? {
        let store = try await storeForActor(actorID)
        if let result = try await store.load(for: actorID, as: type) {
            return result
        }

        // Migration fallback: try old shard
        guard let oldPool = oldPoolForActor(actorID) else { return nil }
        let oldStore = try await SQLiteStateStore(dbPool: oldPool)
        guard let oldResult = try await oldStore.load(for: actorID, as: type) else { return nil }

        // Migrate the row to the new shard
        _ = try await migrateActorIfNeeded(actorID)
        return oldResult
    }

    public func save<State: Codable & Sendable>(
        _ state: State,
        for actorID: String
    ) async throws {
        let store = try await storeForActor(actorID)
        try await store.save(state, for: actorID)

        // Clean up stale copy on old shard
        if let oldPool = oldPoolForActor(actorID) {
            let oldStore = try await SQLiteStateStore(dbPool: oldPool)
            try await oldStore.delete(for: actorID)
        }
    }

    public func delete(for actorID: String) async throws {
        let store = try await storeForActor(actorID)
        try await store.delete(for: actorID)

        // Also delete from old shard if migrating
        if let oldPool = oldPoolForActor(actorID) {
            let oldStore = try await SQLiteStateStore(dbPool: oldPool)
            try await oldStore.delete(for: actorID)
        }
    }

    public func exists(for actorID: String) async throws -> Bool {
        let store = try await storeForActor(actorID)
        if try await store.exists(for: actorID) {
            return true
        }

        // Check old shard during migration
        guard let oldPool = oldPoolForActor(actorID) else { return false }
        let oldStore = try await SQLiteStateStore(dbPool: oldPool)
        return try await oldStore.exists(for: actorID)
    }

    public func update<State: Codable & Sendable>(
        for actorID: String,
        as type: State.Type,
        transform: @Sendable (State?) async throws -> State
    ) async throws -> State {
        // load handles migration fallback, save handles cleanup
        let current = try await load(for: actorID, as: type)
        let new = try await transform(current)
        try await save(new, for: actorID)
        return new
    }

    public func getSequenceNumber(for actorID: String) async throws -> UInt64? {
        let store = try await storeForActor(actorID)
        if let seq = try await store.getSequenceNumber(for: actorID) {
            return seq
        }

        // Check old shard during migration
        guard let oldPool = oldPoolForActor(actorID) else { return nil }
        let oldStore = try await SQLiteStateStore(dbPool: oldPool)
        return try await oldStore.getSequenceNumber(for: actorID)
    }

    public func saveIfVersion<State: Codable & Sendable>(
        _ state: State,
        for actorID: String,
        expectedVersion: UInt64
    ) async throws -> UInt64 {
        // Ensure data is on the new shard first
        _ = try await migrateActorIfNeeded(actorID)

        let store = try await storeForActor(actorID)
        return try await store.saveIfVersion(state, for: actorID, expectedVersion: expectedVersion)
    }

    // MARK: - Cross-Shard Queries

    /// Execute a read across all shards, collecting results.
    ///
    /// During migration, this fans out across both old and new shards and
    /// deduplicates by actor ID (new shard wins).
    public func acrossAllShards<T: Sendable>(
        _ query: @Sendable (DatabasePool) async throws -> [T]
    ) async throws -> [T] {
        let shardCount = await shardManager.shardCount
        var results: [T] = []
        for shardID in 0..<shardCount {
            let pool = try await shardManager.openShard(shardID)
            let shardResults = try await query(pool)
            results.append(contentsOf: shardResults)
        }

        // During migration, also query old shards (but caller handles dedup)
        if let oldPools = oldShardPools {
            for (_, pool) in oldPools.sorted(by: { $0.key < $1.key }) {
                let oldResults = try await query(pool)
                results.append(contentsOf: oldResults)
            }
        }

        return results
    }

    /// Returns the shard ID that a given actor ID routes to.
    public func shardID(for actorID: String) async -> Int {
        await shardManager.shardID(for: actorID)
    }

    /// Access the underlying ``DatabasePool`` for a specific actor's shard.
    public func pool(for actorID: String) async throws -> DatabasePool {
        let shardID = await shardManager.shardID(for: actorID)
        return try await shardManager.openShard(shardID)
    }

    // MARK: - Migration Operations

    /// Migrate a single actor from the old shard to the new shard if needed.
    ///
    /// This copies the full row (state, sequenceNumber, timestamps) using
    /// `INSERT OR REPLACE` for crash safety, then deletes the old copy.
    ///
    /// - Returns: `true` if a migration occurred, `false` if the actor was
    ///   already on the new shard or routes to the same shard.
    @discardableResult
    public func migrateActorIfNeeded(_ actorID: String) async throws -> Bool {
        guard let oldPool = oldPoolForActor(actorID) else { return false }

        let newShardID = await shardManager.shardID(for: actorID)
        let newPool = try await shardManager.openShard(newShardID)

        // Ensure actor_state table exists on both pools
        _ = try await storeForActor(actorID)

        // Check if already on new shard
        let existsOnNew = try await newPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM actor_state WHERE actorId = ?",
                           arguments: [actorID]) ?? 0
        }
        if existsOnNew > 0 {
            // Already on new shard — just clean up old copy
            try await oldPool.write { db in
                try db.execute(sql: "DELETE FROM actor_state WHERE actorId = ?",
                             arguments: [actorID])
            }
            return false
        }

        // Read from old shard
        let row = try await oldPool.read { db -> (Data, Int64, Int, Int)? in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT state, sequenceNumber, createdAt, updatedAt
                FROM actor_state WHERE actorId = ?
                """, arguments: [actorID]) else {
                return nil
            }
            let state: Data = row["state"]
            let seq: Int64 = row["sequenceNumber"]
            let created: Int = row["createdAt"]
            let updated: Int = row["updatedAt"]
            return (state, seq, created, updated)
        }

        guard let (state, seq, created, updated) = row else { return false }

        // Copy to new shard preserving exact values
        try await newPool.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO actor_state
                (actorId, state, sequenceNumber, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [actorID, state, seq, created, updated])
        }

        // Delete from old shard
        try await oldPool.write { db in
            try db.execute(sql: "DELETE FROM actor_state WHERE actorId = ?",
                         arguments: [actorID])
        }

        return true
    }

    /// Clears migration state and closes old shard pools.
    ///
    /// Called by ``RoutingMigrationSweeper`` when the background sweep finishes.
    public func completeMigration() {
        migrationState = nil
        oldHasher = nil
        oldShardPools = nil
    }

    /// The old shard pools, exposed for the sweeper.
    public func getOldShardPools() -> [Int: DatabasePool]? {
        oldShardPools
    }

    /// The old Maglev hasher, exposed for the sweeper.
    public func getOldHasher() -> MaglevHasher? {
        oldHasher
    }

    /// The new Maglev hasher, exposed for the sweeper.
    public func getNewHasher() -> MaglevHasher {
        newHasher
    }

    // MARK: - Private

    private func storeForActor(_ actorID: String) async throws -> SQLiteStateStore {
        let shardID = await shardManager.shardID(for: actorID)
        if let cached = storeCache[shardID] {
            return cached
        }
        let pool = try await shardManager.openShard(shardID)
        let store = try await SQLiteStateStore(dbPool: pool)
        storeCache[shardID] = store
        return store
    }

    /// Returns the old shard's pool if the actor routes to a different shard
    /// under the old hasher, or nil if not migrating or same shard.
    private func oldPoolForActor(_ actorID: String) -> DatabasePool? {
        guard let oldH = oldHasher,
              let pools = oldShardPools else { return nil }

        let oldShardID = oldH.shardIndex(for: actorID)
        let newShardID = newHasher.shardIndex(for: actorID)

        // Same physical shard file — no migration needed.
        // This covers both "same shard ID with same count" and
        // "same shard ID during expansion" (shard-0002 is the same file).
        if oldShardID == newShardID {
            return nil
        }

        return pools[oldShardID]
    }
}
