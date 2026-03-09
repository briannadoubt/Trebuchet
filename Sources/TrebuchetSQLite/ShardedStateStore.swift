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
/// ```swift
/// let config = SQLiteStorageConfiguration(root: ".trebuchet/db", shardCount: 4)
/// let manager = SQLiteShardManager(configuration: config)
/// try await manager.initialize()
/// let store = ShardedStateStore(shardManager: manager)
///
/// // Automatically routed to the correct shard:
/// try await store.save(state, for: "player-42")
/// let state = try await store.load(for: "player-42", as: PlayerState.self)
/// ```
///
/// For queries that span all shards (e.g. "find all actors matching X"),
/// use ``acrossAllShards(_:)`` which makes the fan-out explicit.
public actor ShardedStateStore: ActorStateStore {
    private let shardManager: SQLiteShardManager
    private var storeCache: [Int: SQLiteStateStore] = [:]

    public init(shardManager: SQLiteShardManager) {
        self.shardManager = shardManager
    }

    // MARK: - ActorStateStore Conformance

    public func load<State: Codable & Sendable>(
        for actorID: String,
        as type: State.Type
    ) async throws -> State? {
        let store = try await storeForActor(actorID)
        return try await store.load(for: actorID, as: type)
    }

    public func save<State: Codable & Sendable>(
        _ state: State,
        for actorID: String
    ) async throws {
        let store = try await storeForActor(actorID)
        try await store.save(state, for: actorID)
    }

    public func delete(for actorID: String) async throws {
        let store = try await storeForActor(actorID)
        try await store.delete(for: actorID)
    }

    public func exists(for actorID: String) async throws -> Bool {
        let store = try await storeForActor(actorID)
        return try await store.exists(for: actorID)
    }

    public func update<State: Codable & Sendable>(
        for actorID: String,
        as type: State.Type,
        transform: @Sendable (State?) async throws -> State
    ) async throws -> State {
        let store = try await storeForActor(actorID)
        return try await store.update(for: actorID, as: type, transform: transform)
    }

    public func getSequenceNumber(for actorID: String) async throws -> UInt64? {
        let store = try await storeForActor(actorID)
        return try await store.getSequenceNumber(for: actorID)
    }

    public func saveIfVersion<State: Codable & Sendable>(
        _ state: State,
        for actorID: String,
        expectedVersion: UInt64
    ) async throws -> UInt64 {
        let store = try await storeForActor(actorID)
        return try await store.saveIfVersion(state, for: actorID, expectedVersion: expectedVersion)
    }

    // MARK: - Cross-Shard Queries

    /// Execute a read across all shards, collecting results.
    ///
    /// Use this for operations that intentionally need data from every shard,
    /// like "list all actors" or "count total records". The fan-out is explicit
    /// so it can't happen accidentally.
    ///
    /// ```swift
    /// let allPlayers: [PlayerState] = try await store.acrossAllShards { pool in
    ///     try await pool.read { db in
    ///         try Row.fetchAll(db, sql: "SELECT state FROM actor_state")
    ///             .compactMap { row in
    ///                 let data: Data = row["state"]
    ///                 return try? JSONDecoder().decode(PlayerState.self, from: data)
    ///             }
    ///     }
    /// }
    /// ```
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
        return results
    }

    /// Returns the shard ID that a given actor ID routes to.
    ///
    /// Useful for debugging and inspecting shard distribution.
    public func shardID(for actorID: String) async -> Int {
        await shardManager.shardID(for: actorID)
    }

    /// Access the underlying ``DatabasePool`` for a specific actor's shard.
    ///
    /// Use this for domain-specific GRDB queries that go beyond the generic
    /// actor state table. The pool is guaranteed to be the correct shard.
    ///
    /// ```swift
    /// let pool = try await store.pool(for: "player-42")
    /// try await pool.write { db in
    ///     try db.execute(sql: "INSERT INTO leaderboard ...")
    /// }
    /// ```
    public func pool(for actorID: String) async throws -> DatabasePool {
        let shardID = await shardManager.shardID(for: actorID)
        return try await shardManager.openShard(shardID)
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
}
