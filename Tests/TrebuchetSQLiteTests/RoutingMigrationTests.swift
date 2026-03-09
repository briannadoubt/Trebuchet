import Testing
import Foundation
import GRDB
@testable import TrebuchetSQLite

@Suite("Routing Migration Tests")
struct RoutingMigrationTests {

    // MARK: - Helpers

    /// Creates a sharded store with `shardCount` shards using modulo routing,
    /// populates it with actors, then creates a new store with `newShardCount`
    /// shards using maglev routing in migration mode.
    private func makeMigrationScenario(
        oldShardCount: Int = 4,
        newShardCount: Int = 5,
        oldRouting: RoutingMode = .modulo,
        newRouting: RoutingMode = .maglev(tableSize: 997),
        actorIDs: [String] = []
    ) async throws -> (
        oldStore: ShardedStateStore,
        newStore: ShardedStateStore,
        root: String,
        oldManager: SQLiteShardManager,
        newManager: SQLiteShardManager
    ) {
        let root = NSTemporaryDirectory() + "trebuchet-migration-\(UUID().uuidString)"

        // Set up old store
        let oldConfig = SQLiteStorageConfiguration(
            root: root, shardCount: oldShardCount, routing: oldRouting
        )
        let oldManager = SQLiteShardManager(configuration: oldConfig)
        try await oldManager.initialize()
        let oldStore = await ShardedStateStore(shardManager: oldManager)

        // Populate actors
        for actorID in actorIDs {
            try await oldStore.save(
                TestState(name: actorID, count: actorID.hashValue),
                for: actorID
            )
        }

        // Create new shard directories if expanding
        if newShardCount > oldShardCount {
            let shardsDir = "\(root)/shards"
            for i in oldShardCount..<newShardCount {
                let shardDir = "\(shardsDir)/shard-\(String(format: "%04d", i))"
                try FileManager.default.createDirectory(
                    atPath: shardDir, withIntermediateDirectories: true
                )
            }
        }

        // Build old routing strategy
        let oldStrategy: any ShardRoutingStrategy
        switch oldRouting {
        case .modulo:
            oldStrategy = ModuloRouting(shardCount: oldShardCount)
        case .maglev(let tableSize):
            oldStrategy = MaglevRouting(shardCount: oldShardCount, tableSize: tableSize)
        }

        // Open old shard pools (re-use the files created by oldManager)
        var oldPools: [Int: DatabasePool] = [:]
        for i in 0..<oldShardCount {
            oldPools[i] = try await oldManager.openShard(i)
        }

        // Create migration state
        let migrationState = RoutingMigrationState(
            previousRoutingMode: oldRouting.persistedName,
            previousShardCount: oldShardCount,
            previousTableSize: oldRouting == .modulo ? nil : 997,
            startedAt: Date(),
            migratedCount: 0
        )

        // Create new manager + store in migration mode
        let newConfig = SQLiteStorageConfiguration(
            root: root, shardCount: newShardCount, routing: newRouting
        )
        let newManager = SQLiteShardManager(configuration: newConfig)
        try await newManager.initialize()

        let newStore = await ShardedStateStore(
            shardManager: newManager,
            migrationState: migrationState,
            oldShardPools: oldPools,
            oldRoutingStrategy: oldStrategy
        )

        return (oldStore, newStore, root, oldManager, newManager)
    }

    // MARK: - Read-Through Tests

    @Test("Read-through: load finds actor from old shard")
    func readThrough() async throws {
        let actorIDs = (0..<10).map { "actor-\($0)" }
        let (_, newStore, root, _, _) = try await makeMigrationScenario(actorIDs: actorIDs)
        defer { try? FileManager.default.removeItem(atPath: root) }

        // Every actor saved under old routing should be loadable via new store
        for actorID in actorIDs {
            let loaded = try await newStore.load(for: actorID, as: TestState.self)
            #expect(loaded != nil, "Actor \(actorID) should be found via read-through")
            #expect(loaded?.name == actorID)
        }
    }

    @Test("Save cleans up old shard")
    func saveCleanup() async throws {
        let (_, newStore, root, oldManager, _) = try await makeMigrationScenario(
            actorIDs: ["actor-cleanup"]
        )
        defer { try? FileManager.default.removeItem(atPath: root) }

        // Save through new store
        try await newStore.save(TestState(name: "updated", count: 99), for: "actor-cleanup")

        // Verify old shard is cleaned up
        let oldRouting = ModuloRouting(shardCount: 4)
        let oldShardID = oldRouting.shardID(for: "actor-cleanup")
        let oldPool = try await oldManager.openShard(oldShardID)

        let count = try await oldPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM actor_state WHERE actorId = ?",
                           arguments: ["actor-cleanup"]) ?? 0
        }
        #expect(count == 0, "Old shard should have no copy after save")

        // Verify new store has the updated data
        let loaded = try await newStore.load(for: "actor-cleanup", as: TestState.self)
        #expect(loaded?.name == "updated")
    }

    @Test("Delete hits both shards")
    func deleteBothShards() async throws {
        let (_, newStore, root, oldManager, _) = try await makeMigrationScenario(
            actorIDs: ["actor-delete"]
        )
        defer { try? FileManager.default.removeItem(atPath: root) }

        // Delete through new store
        try await newStore.delete(for: "actor-delete")

        // Verify gone from old shard
        let oldRouting = ModuloRouting(shardCount: 4)
        let oldShardID = oldRouting.shardID(for: "actor-delete")
        let oldPool = try await oldManager.openShard(oldShardID)

        let count = try await oldPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM actor_state WHERE actorId = ?",
                           arguments: ["actor-delete"]) ?? 0
        }
        #expect(count == 0)

        // Verify gone from new store
        #expect(try await newStore.exists(for: "actor-delete") == false)
    }

    @Test("exists checks both shards")
    func existsBothShards() async throws {
        let (_, newStore, root, _, _) = try await makeMigrationScenario(
            actorIDs: ["actor-exists"]
        )
        defer { try? FileManager.default.removeItem(atPath: root) }

        // Actor exists on old shard only — should still return true
        #expect(try await newStore.exists(for: "actor-exists") == true)

        // Non-existent actor
        #expect(try await newStore.exists(for: "actor-nonexistent") == false)
    }

    // MARK: - Sequence Number Tests

    @Test("Sequence numbers survive migration exactly")
    func sequenceNumberPreservation() async throws {
        let root = NSTemporaryDirectory() + "trebuchet-seqmig-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }

        let oldConfig = SQLiteStorageConfiguration(root: root, shardCount: 4, routing: .modulo)
        let oldManager = SQLiteShardManager(configuration: oldConfig)
        try await oldManager.initialize()
        let oldStore = await ShardedStateStore(shardManager: oldManager)

        // Save multiple times to build up sequence number
        let actorID = "actor-seq"
        try await oldStore.save(TestState(name: "v1", count: 1), for: actorID)
        try await oldStore.save(TestState(name: "v2", count: 2), for: actorID)
        try await oldStore.save(TestState(name: "v3", count: 3), for: actorID)
        let originalSeq = try await oldStore.getSequenceNumber(for: actorID)
        #expect(originalSeq == 3)

        // Create new store in migration mode
        let oldStrategy = ModuloRouting(shardCount: 4)
        var oldPools: [Int: DatabasePool] = [:]
        for i in 0..<4 { oldPools[i] = try await oldManager.openShard(i) }

        // Expand to 5 shards
        let shardsDir = "\(root)/shards"
        let shardDir = "\(shardsDir)/shard-\(String(format: "%04d", 4))"
        try FileManager.default.createDirectory(atPath: shardDir, withIntermediateDirectories: true)

        let newConfig = SQLiteStorageConfiguration(root: root, shardCount: 5, routing: .maglev(tableSize: 997))
        let newManager = SQLiteShardManager(configuration: newConfig)
        try await newManager.initialize()

        let migrationState = RoutingMigrationState(
            previousRoutingMode: "modulo",
            previousShardCount: 4,
            startedAt: Date()
        )

        let newStore = await ShardedStateStore(
            shardManager: newManager,
            migrationState: migrationState,
            oldShardPools: oldPools,
            oldRoutingStrategy: oldStrategy
        )

        // Load triggers migration — sequence number should be preserved
        let loaded = try await newStore.load(for: actorID, as: TestState.self)
        #expect(loaded?.name == "v3")

        let migratedSeq = try await newStore.getSequenceNumber(for: actorID)
        #expect(migratedSeq == originalSeq, "Sequence number must be preserved exactly after migration")
    }

    @Test("saveIfVersion preserves sequence number across migration")
    func saveIfVersionMigration() async throws {
        let root = NSTemporaryDirectory() + "trebuchet-savever-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }

        let oldConfig = SQLiteStorageConfiguration(root: root, shardCount: 4, routing: .modulo)
        let oldManager = SQLiteShardManager(configuration: oldConfig)
        try await oldManager.initialize()
        let oldStore = await ShardedStateStore(shardManager: oldManager)

        let actorID = "actor-version"
        try await oldStore.save(TestState(name: "v1", count: 1), for: actorID)
        try await oldStore.save(TestState(name: "v2", count: 2), for: actorID)
        // Sequence number is now 2

        // Create migration scenario
        let oldStrategy = ModuloRouting(shardCount: 4)
        var oldPools: [Int: DatabasePool] = [:]
        for i in 0..<4 { oldPools[i] = try await oldManager.openShard(i) }

        let shardsDir = "\(root)/shards"
        try FileManager.default.createDirectory(
            atPath: "\(shardsDir)/shard-0004", withIntermediateDirectories: true
        )

        let newConfig = SQLiteStorageConfiguration(root: root, shardCount: 5, routing: .maglev(tableSize: 997))
        let newManager = SQLiteShardManager(configuration: newConfig)
        try await newManager.initialize()

        let newStore = await ShardedStateStore(
            shardManager: newManager,
            migrationState: RoutingMigrationState(
                previousRoutingMode: "modulo",
                previousShardCount: 4,
                startedAt: Date()
            ),
            oldShardPools: oldPools,
            oldRoutingStrategy: oldStrategy
        )

        // saveIfVersion with expected=2 should work (migrate first, then CAS)
        let newVersion = try await newStore.saveIfVersion(
            TestState(name: "v3", count: 3),
            for: actorID,
            expectedVersion: 2
        )
        #expect(newVersion == 3)
    }

    // MARK: - Background Sweep Tests

    @Test("Background sweep migrates all actors")
    func backgroundSweep() async throws {
        let actorIDs = (0..<20).map { "sweep-actor-\($0)" }
        let (_, newStore, root, oldManager, newManager) = try await makeMigrationScenario(
            actorIDs: actorIDs
        )
        defer { try? FileManager.default.removeItem(atPath: root) }

        let oldStrategy = ModuloRouting(shardCount: 4)
        let newStrategy = await newManager.routingStrategy

        var oldPools: [Int: DatabasePool] = [:]
        for i in 0..<4 { oldPools[i] = try await oldManager.openShard(i) }

        let sweeper = RoutingMigrationSweeper(
            shardedStore: newStore,
            oldShardPools: oldPools,
            oldRoutingStrategy: oldStrategy,
            newRoutingStrategy: newStrategy,
            batchSize: 5,
            delayBetweenBatches: .milliseconds(10)
        )

        await sweeper.start()

        // Wait for sweep to complete
        var progress = await sweeper.progress()
        var attempts = 0
        while !progress.isComplete && attempts < 100 {
            try await Task.sleep(for: .milliseconds(50))
            progress = await sweeper.progress()
            attempts += 1
        }

        #expect(progress.isComplete, "Sweep should complete within timeout")
        #expect(progress.scannedCount > 0, "Should have scanned actors")

        // All actors should be loadable from the new store (no longer in migration mode)
        #expect(await newStore.isMigrating == false, "Migration should be cleared after sweep")

        // Verify all actors accessible via the new routing
        let verifyStore = await ShardedStateStore(shardManager: newManager)
        for actorID in actorIDs {
            let loaded = try await verifyStore.load(for: actorID, as: TestState.self)
            #expect(loaded != nil, "Actor \(actorID) should exist on new shard after sweep")
        }

        // Verify actors that moved are on their new shard (not the old one)
        for actorID in actorIDs {
            let oldShardID = oldStrategy.shardID(for: actorID)
            let newShardID = newStrategy.shardID(for: actorID)
            if oldShardID != newShardID {
                // This actor moved — verify it's on the new shard
                let newPool = try await newManager.openShard(newShardID)
                let newCount = try await newPool.read { db in
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM actor_state WHERE actorId = ?",
                                   arguments: [actorID]) ?? 0
                }
                #expect(newCount == 1, "Moved actor \(actorID) should be on new shard \(newShardID)")
            }
        }
    }

    // MARK: - Edge Cases

    @Test("Single shard (1→1) is a no-op")
    func singleShardNoOp() async throws {
        let (_, newStore, root, _, _) = try await makeMigrationScenario(
            oldShardCount: 1,
            newShardCount: 1,
            oldRouting: .modulo,
            newRouting: .maglev(tableSize: 997),
            actorIDs: ["actor-single"]
        )
        defer { try? FileManager.default.removeItem(atPath: root) }

        // Both old and new route to shard 0 — should load without migration
        let loaded = try await newStore.load(for: "actor-single", as: TestState.self)
        #expect(loaded != nil)
    }

    @Test("Same-shard actors don't trigger migration")
    func sameShard() async throws {
        // Find an actor that routes to the same shard under both strategies
        let oldStrategy = ModuloRouting(shardCount: 4)
        let newStrategy = MaglevRouting(shardCount: 5, tableSize: 997)

        var sameShard: String? = nil
        for i in 0..<1000 {
            let key = "stable-\(i)"
            if oldStrategy.shardID(for: key) == newStrategy.shardID(for: key) {
                sameShard = key
                break
            }
        }

        guard let actorID = sameShard else {
            // Very unlikely but skip if no match found
            return
        }

        let (_, newStore, root, _, _) = try await makeMigrationScenario(
            actorIDs: [actorID]
        )
        defer { try? FileManager.default.removeItem(atPath: root) }

        // migrateActorIfNeeded should return false for same-shard actors
        let didMigrate = try await newStore.migrateActorIfNeeded(actorID)
        #expect(didMigrate == false, "Same-shard actor should not trigger migration")
    }

    @Test("acrossAllShards returns results from both old and new shards")
    func acrossAllShardsDedup() async throws {
        let actorIDs = (0..<10).map { "cross-\($0)" }
        let (_, newStore, root, _, _) = try await makeMigrationScenario(actorIDs: actorIDs)
        defer { try? FileManager.default.removeItem(atPath: root) }

        // Migrate some actors to new shards
        for i in 0..<3 {
            _ = try await newStore.load(for: actorIDs[i], as: TestState.self)
        }

        // Fan-out should find all actors (some on new, some on old)
        let allIDs: [String] = try await newStore.acrossAllShards { pool in
            try await pool.read { db in
                try Row.fetchAll(db, sql: "SELECT actorId FROM actor_state")
                    .map { $0["actorId"] as String }
            }
        }

        // All actors should appear (caller is responsible for dedup in production,
        // but we should see at least the expected count)
        let uniqueIDs = Set(allIDs)
        #expect(uniqueIDs.count == actorIDs.count,
               "Should find all \(actorIDs.count) actors across shards")
    }

    // MARK: - RoutingMigrationState Persistence

    @Test("RoutingMigrationState round-trips through JSON")
    func migrationStatePersistence() throws {
        let state = RoutingMigrationState(
            previousRoutingMode: "modulo",
            previousShardCount: 4,
            previousTableSize: nil,
            startedAt: Date(timeIntervalSince1970: 1000000),
            migratedCount: 42
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(RoutingMigrationState.self, from: data)

        #expect(decoded == state)
    }

    @Test("OwnershipFile round-trips with migration state")
    func ownershipFileWithMigration() throws {
        let migration = RoutingMigrationState(
            previousRoutingMode: "maglev",
            previousShardCount: 8,
            previousTableSize: 65537,
            startedAt: Date(timeIntervalSince1970: 1000000),
            migratedCount: 0
        )

        let file = OwnershipFile(
            globalEpoch: 5,
            shards: [],
            routingMode: "maglev",
            shardCount: 10,
            routingMigration: migration
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(file)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(OwnershipFile.self, from: data)

        #expect(decoded.shardCount == 10)
        #expect(decoded.routingMigration == migration)
    }

    @Test("RoutingMode.from(migrationState:) reconstructs correctly")
    func routingModeFromMigrationState() {
        let moduloState = RoutingMigrationState(
            previousRoutingMode: "modulo",
            previousShardCount: 4
        )
        #expect(RoutingMode.from(migrationState: moduloState) == .modulo)

        let maglevState = RoutingMigrationState(
            previousRoutingMode: "maglev",
            previousShardCount: 8,
            previousTableSize: 997
        )
        #expect(RoutingMode.from(migrationState: maglevState) == .maglev(tableSize: 997))

        let maglevDefaultState = RoutingMigrationState(
            previousRoutingMode: "maglev",
            previousShardCount: 4
        )
        #expect(RoutingMode.from(migrationState: maglevDefaultState) == .maglev(tableSize: 65537))
    }
}
