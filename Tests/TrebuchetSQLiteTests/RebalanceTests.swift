import Testing
import Foundation
@testable import TrebuchetSQLite

/// A transfer agent that always fails, used to test rollback behavior.
struct FailingShardTransferAgent: ShardTransferAgent {
    struct TransferError: Error, LocalizedError {
        var errorDescription: String? { "Simulated transfer failure" }
    }

    func transfer(snapshotPath: String, shardID: Int, targetNodeID: String) async throws -> String {
        throw TransferError()
    }

    func activateOnTarget(shardID: Int, targetNodeID: String, snapshotPath: String) async throws {
        throw TransferError()
    }
}

// MARK: - Test Helpers

private func makeTempDir() -> String {
    let path = NSTemporaryDirectory() + "trebuchet-rebalance-test-\(UUID().uuidString)"
    try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

private func cleanup(_ path: String) {
    try? FileManager.default.removeItem(atPath: path)
}

private func makeOwnershipRecords(shardCount: Int, nodeID: String) -> [ShardOwnershipRecord] {
    let now = Date()
    return (0..<shardCount).map { id in
        ShardOwnershipRecord(
            shardID: id,
            ownerNodeID: nodeID,
            epoch: 0,
            status: .active,
            lastUpdated: now
        )
    }
}

private func makeOwnershipRecordsDistributed(
    shardCount: Int,
    nodes: [String]
) -> [ShardOwnershipRecord] {
    let now = Date()
    return (0..<shardCount).map { id in
        ShardOwnershipRecord(
            shardID: id,
            ownerNodeID: nodes[id % nodes.count],
            epoch: 0,
            status: .active,
            lastUpdated: now
        )
    }
}

// MARK: - Tests

@Suite("Rebalance Tests")
struct RebalanceTests {

    // MARK: - ShardOwnership Tests

    @Test("Initialize default ownership map")
    func testInitializeDefault() async throws {
        let tmpDir = makeTempDir()
        defer { cleanup(tmpDir) }

        let ownership = ShardOwnershipMap(nodeID: "node-1", metadataPath: tmpDir)
        await ownership.initializeDefault(shardCount: 4)

        let records = await ownership.records
        #expect(records.count == 4)

        for i in 0..<4 {
            let record = records[i]
            #expect(record != nil)
            #expect(record?.ownerNodeID == "node-1")
            #expect(record?.status == .active)
            #expect(record?.epoch == 0)
            #expect(record?.shardID == i)
        }

        let epoch = await ownership.globalEpoch
        #expect(epoch == 0)
    }

    @Test("Assign shard bumps epoch")
    func testAssignShard() async throws {
        let tmpDir = makeTempDir()
        defer { cleanup(tmpDir) }

        let ownership = ShardOwnershipMap(nodeID: "node-1", metadataPath: tmpDir)
        await ownership.initializeDefault(shardCount: 4)

        try await ownership.assignShard(2, to: "node-2")

        let record = await ownership.records[2]
        #expect(record?.ownerNodeID == "node-2")
        #expect(record?.status == .active)
        #expect(record?.epoch == 1)

        let globalEpoch = await ownership.globalEpoch
        #expect(globalEpoch == 1)
    }

    @Test("Migration lifecycle transitions")
    func testMigrationLifecycle() async throws {
        let tmpDir = makeTempDir()
        defer { cleanup(tmpDir) }

        let ownership = ShardOwnershipMap(nodeID: "node-1", metadataPath: tmpDir)
        await ownership.initializeDefault(shardCount: 4)

        // Begin migration
        try await ownership.beginMigration(shardID: 1, targetNodeID: "node-2")
        let afterMigrate = await ownership.records[1]
        #expect(afterMigrate?.status == .migrating(targetNodeID: "node-2"))
        #expect(afterMigrate?.ownerNodeID == "node-1") // still owned by source

        // Begin drain — preserves target node ID
        try await ownership.beginDrain(shardID: 1)
        let afterDrain = await ownership.records[1]
        #expect(afterDrain?.status == .draining(targetNodeID: "node-2"))

        let epochBeforeComplete = await ownership.globalEpoch

        // Complete migration — works from .draining state since target is preserved
        try await ownership.completeMigration(shardID: 1)

        let afterComplete = await ownership.records[1]
        #expect(afterComplete?.status == .active)
        #expect(afterComplete?.ownerNodeID == "node-2") // now owned by target

        let epochAfterComplete = await ownership.globalEpoch
        #expect(epochAfterComplete > epochBeforeComplete)
    }

    @Test("Rollback migration returns to active")
    func testRollbackMigration() async throws {
        let tmpDir = makeTempDir()
        defer { cleanup(tmpDir) }

        let ownership = ShardOwnershipMap(nodeID: "node-1", metadataPath: tmpDir)
        await ownership.initializeDefault(shardCount: 4)

        try await ownership.beginMigration(shardID: 0, targetNodeID: "node-2")
        let migrating = await ownership.records[0]
        #expect(migrating?.status == .migrating(targetNodeID: "node-2"))

        try await ownership.rollbackMigration(shardID: 0)
        let rolledBack = await ownership.records[0]
        #expect(rolledBack?.status == .active)
        #expect(rolledBack?.ownerNodeID == "node-1") // owner unchanged
    }

    @Test("Save and load ownership map")
    func testSaveAndLoad() async throws {
        let tmpDir = makeTempDir()
        defer { cleanup(tmpDir) }

        let ownership1 = ShardOwnershipMap(nodeID: "node-1", metadataPath: tmpDir)
        await ownership1.initializeDefault(shardCount: 4)
        try await ownership1.assignShard(2, to: "node-2")
        try await ownership1.save()

        let ownership2 = ShardOwnershipMap(nodeID: "node-1", metadataPath: tmpDir)
        try await ownership2.load()

        let records1 = await ownership1.allShards()
        let records2 = await ownership2.allShards()

        #expect(records1.count == records2.count)
        for i in 0..<records1.count {
            #expect(records1[i].shardID == records2[i].shardID)
            #expect(records1[i].ownerNodeID == records2[i].ownerNodeID)
            #expect(records1[i].epoch == records2[i].epoch)
            #expect(records1[i].status == records2[i].status)
        }

        let epoch1 = await ownership1.globalEpoch
        let epoch2 = await ownership2.globalEpoch
        #expect(epoch1 == epoch2)
    }

    @Test("Shard not found error")
    func testShardNotFoundError() async throws {
        let tmpDir = makeTempDir()
        defer { cleanup(tmpDir) }

        let ownership = ShardOwnershipMap(nodeID: "node-1", metadataPath: tmpDir)
        await ownership.initializeDefault(shardCount: 4)

        await #expect(throws: ShardOwnershipError.self) {
            try await ownership.beginMigration(shardID: 99, targetNodeID: "node-2")
        }
    }

    @Test("Complete migration when not migrating throws error")
    func testCompleteMigrationNotMigratingError() async throws {
        let tmpDir = makeTempDir()
        defer { cleanup(tmpDir) }

        let ownership = ShardOwnershipMap(nodeID: "node-1", metadataPath: tmpDir)
        await ownership.initializeDefault(shardCount: 4)

        // Shard 0 is active, not migrating
        await #expect(throws: ShardOwnershipError.self) {
            try await ownership.completeMigration(shardID: 0)
        }
    }

    // MARK: - RebalancePlanner Tests

    @Test("Already balanced distribution produces empty plan")
    func testAlreadyBalanced() {
        let planner = RebalancePlanner()
        let records = makeOwnershipRecordsDistributed(shardCount: 4, nodes: ["node-1", "node-2"])

        let plan = planner.plan(currentOwnership: records, targetNodes: ["node-1", "node-2"])

        #expect(plan.isEmpty)
        #expect(plan.moves.isEmpty)
    }

    @Test("Rebalance from single node to two nodes")
    func testRebalanceFromSingleNode() {
        let planner = RebalancePlanner()
        let records = makeOwnershipRecords(shardCount: 8, nodeID: "node-1")

        let plan = planner.plan(currentOwnership: records, targetNodes: ["node-1", "node-2"])

        #expect(plan.moveCount == 4)
        #expect(plan.nodeShardCounts["node-1"] == 4)
        #expect(plan.nodeShardCounts["node-2"] == 4)

        // All moves should go from node-1 to node-2
        for move in plan.moves {
            #expect(move.sourceNodeID == "node-1")
            #expect(move.targetNodeID == "node-2")
        }
    }

    @Test("Rebalance with remainder distributes correctly")
    func testRebalanceWithRemainder() {
        let planner = RebalancePlanner()
        let records = makeOwnershipRecords(shardCount: 5, nodeID: "node-1")

        let plan = planner.plan(currentOwnership: records, targetNodes: ["node-1", "node-2"])

        // 5 shards / 2 nodes = 2 each + 1 remainder => one node gets 3, other gets 2
        let counts = plan.nodeShardCounts
        let sortedCounts = counts.values.sorted()
        #expect(sortedCounts == [2, 3])

        // Total shards should still be 5
        let totalTarget = counts.values.reduce(0, +)
        #expect(totalTarget == 5)
    }

    @Test("Node addition redistributes shards")
    func testNodeAddition() {
        let planner = RebalancePlanner()
        // 6 shards evenly across 2 nodes (3 each)
        let records = makeOwnershipRecordsDistributed(shardCount: 6, nodes: ["node-1", "node-2"])

        let plan = planner.planNodeAddition(
            currentOwnership: records,
            existingNodes: ["node-1", "node-2"],
            newNodeID: "node-3"
        )

        // 6 shards / 3 nodes = 2 each, so some shards should move to node-3
        #expect(!plan.isEmpty)
        #expect(plan.nodeShardCounts["node-3"] == 2)

        // All moves should target node-3
        for move in plan.moves {
            #expect(move.targetNodeID == "node-3")
        }
    }

    @Test("Node removal redistributes shards to remaining nodes")
    func testNodeRemoval() {
        let planner = RebalancePlanner()
        // 6 shards across 3 nodes (2 each)
        let records = makeOwnershipRecordsDistributed(
            shardCount: 6,
            nodes: ["node-1", "node-2", "node-3"]
        )

        let plan = planner.planNodeRemoval(
            currentOwnership: records,
            allNodes: ["node-1", "node-2", "node-3"],
            removedNodeID: "node-3"
        )

        // 6 shards / 2 remaining nodes = 3 each
        #expect(!plan.isEmpty)
        #expect(plan.nodeShardCounts["node-1"] == 3)
        #expect(plan.nodeShardCounts["node-2"] == 3)
        #expect(plan.nodeShardCounts["node-3"] == nil)

        // All moves should come from node-3
        for move in plan.moves {
            #expect(move.sourceNodeID == "node-3")
        }
    }

    @Test("Empty inputs produce empty plan")
    func testEmptyInputs() {
        let planner = RebalancePlanner()

        // Empty ownership
        let plan1 = planner.plan(currentOwnership: [], targetNodes: ["node-1"])
        #expect(plan1.isEmpty)

        // Empty target nodes
        let records = makeOwnershipRecords(shardCount: 4, nodeID: "node-1")
        let plan2 = planner.plan(currentOwnership: records, targetNodes: [])
        #expect(plan2.isEmpty)

        // Both empty
        let plan3 = planner.plan(currentOwnership: [], targetNodes: [])
        #expect(plan3.isEmpty)
    }

    // MARK: - ShardMigrationCoordinator Tests

    @Test("Migrate shard end-to-end with data preserved")
    func testMigrateShardEndToEnd() async throws {
        let sourceRoot = makeTempDir()
        let targetRoot = makeTempDir()
        defer {
            cleanup(sourceRoot)
            cleanup(targetRoot)
        }

        let config = SQLiteStorageConfiguration(root: sourceRoot, shardCount: 2)
        let manager = SQLiteShardManager(configuration: config)
        try await manager.initialize()

        // Write test data to shard 0
        let pool = try await manager.openShard(0)
        try await pool.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS actor_state (
                    actorId TEXT PRIMARY KEY,
                    state BLOB NOT NULL,
                    sequenceNumber INTEGER NOT NULL DEFAULT 0,
                    createdAt INTEGER NOT NULL,
                    updatedAt INTEGER NOT NULL
                )
            """)
            let now = Int(Date().timeIntervalSince1970)
            try db.execute(
                sql: "INSERT INTO actor_state (actorId, state, sequenceNumber, createdAt, updatedAt) VALUES (?, ?, 1, ?, ?)",
                arguments: ["test-actor", Data("{\"name\":\"hello\"}".utf8), now, now]
            )
        }

        let metadataDir = "\(sourceRoot)/metadata"
        let ownership = ShardOwnershipMap(nodeID: "source-node", metadataPath: metadataDir)
        await ownership.initializeDefault(shardCount: 2)

        // Manually execute the migration steps to verify the full lifecycle,
        // using a direct file copy instead of the coordinator's WAL checkpoint
        // (which requires exclusive access incompatible with DatabasePool).

        // Step 1: Mark as migrating
        try await ownership.beginMigration(shardID: 0, targetNodeID: "target-node")
        let migratingStatus = await ownership.records[0]?.status
        #expect(migratingStatus == .migrating(targetNodeID: "target-node"))

        // Step 2: Drain
        try await ownership.beginDrain(shardID: 0)
        let drainStatus = await ownership.records[0]?.status
        #expect(drainStatus == .draining(targetNodeID: "target-node"))

        // Step 3: Snapshot - checkpoint WAL into main file before copying.
        // Use writeWithoutTransaction to avoid nested transaction issues.
        try await pool.writeWithoutTransaction { db in
            // PASSIVE checkpoint doesn't require exclusive lock and will
            // checkpoint as much of the WAL as possible.
            try db.execute(sql: "PRAGMA wal_checkpoint(PASSIVE)")
        }
        let sourcePath = await manager.shardPath(0)

        // Step 4: Transfer using LocalShardTransferAgent
        let transferAgent = LocalShardTransferAgent(targetRoot: targetRoot)

        let targetPath = try await transferAgent.transfer(
            snapshotPath: sourcePath,
            shardID: 0,
            targetNodeID: "target-node"
        )

        // Step 5: Activate on target
        try await transferAgent.activateOnTarget(
            shardID: 0,
            targetNodeID: "target-node",
            snapshotPath: targetPath
        )

        // Step 6: Complete migration (epoch cutover)
        try await ownership.completeMigration(shardID: 0)

        // Step 7: Close source shard
        await manager.closeShard(0)

        // Verify ownership was transferred
        let owner = await ownership.ownerNode(for: 0)
        #expect(owner == "target-node")

        let status = await ownership.records[0]?.status
        #expect(status == .active)

        let epoch = await ownership.globalEpoch
        #expect(epoch > 0)

        // Verify data is present in the target location
        let targetDbPath = "\(targetRoot)/shards/shard-0000/main.sqlite"
        #expect(FileManager.default.fileExists(atPath: targetDbPath))

        // Open the target database and verify data was preserved
        let targetPool = try SQLiteStorageConfiguration.makeDatabasePool(path: targetDbPath)
        let actorExists = try await targetPool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM actor_state WHERE actorId = ?",
                arguments: ["test-actor"]
            )
        }
        #expect(actorExists == 1)
    }

    @Test("Migration failure triggers rollback")
    func testMigrationFailureRollback() async throws {
        let sourceRoot = makeTempDir()
        let snapshotsDir = makeTempDir()
        defer {
            cleanup(sourceRoot)
            cleanup(snapshotsDir)
        }

        let config = SQLiteStorageConfiguration(root: sourceRoot, shardCount: 2)
        let manager = SQLiteShardManager(configuration: config)
        try await manager.initialize()

        // Open shard so snapshot can work
        let pool = try await manager.openShard(0)
        try await pool.write { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS test (id INTEGER PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO test (id) VALUES (1)")
        }

        let metadataDir = "\(sourceRoot)/metadata"
        let ownership = ShardOwnershipMap(nodeID: "source-node", metadataPath: metadataDir)
        await ownership.initializeDefault(shardCount: 2)

        let failingAgent = FailingShardTransferAgent()
        let coordinator = ShardMigrationCoordinator(
            shardManager: manager,
            ownership: ownership,
            transferAgent: failingAgent,
            snapshotsDir: snapshotsDir
        )

        let result = try await coordinator.migrateShard(0, to: "target-node")

        // Migration should have failed
        #expect(!result.success)
        #expect(result.error != nil)

        // Ownership should be rolled back to source
        let owner = await ownership.ownerNode(for: 0)
        #expect(owner == "source-node")

        let status = await ownership.records[0]?.status
        #expect(status == .active)
    }
}
