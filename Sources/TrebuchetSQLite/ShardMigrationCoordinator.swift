import Foundation
import GRDB

// MARK: - Migration Result

/// Result of a single shard migration
public struct MigrationResult: Sendable {
    public let shardID: Int
    public let sourceNodeID: String
    public let targetNodeID: String
    public let epoch: UInt64
    public let snapshotSizeBytes: UInt64
    public let durationSeconds: TimeInterval
    public let success: Bool
    public let error: String?

    public init(
        shardID: Int,
        sourceNodeID: String,
        targetNodeID: String,
        epoch: UInt64,
        snapshotSizeBytes: UInt64,
        durationSeconds: TimeInterval,
        success: Bool,
        error: String?
    ) {
        self.shardID = shardID
        self.sourceNodeID = sourceNodeID
        self.targetNodeID = targetNodeID
        self.epoch = epoch
        self.snapshotSizeBytes = snapshotSizeBytes
        self.durationSeconds = durationSeconds
        self.success = success
        self.error = error
    }
}

// MARK: - Transfer Agent Protocol

/// Protocol for transferring shard snapshot files between nodes
public protocol ShardTransferAgent: Sendable {
    /// Transfer a snapshot file to the target node. Returns the path on the target.
    func transfer(snapshotPath: String, shardID: Int, targetNodeID: String) async throws -> String

    /// Signal the target node to open the transferred shard
    func activateOnTarget(shardID: Int, targetNodeID: String, snapshotPath: String) async throws
}

// MARK: - Local Transfer Agent

/// Default local transfer agent for single-machine rebalancing (just copies files)
public struct LocalShardTransferAgent: ShardTransferAgent {
    public let targetRoot: String

    public init(targetRoot: String) {
        self.targetRoot = targetRoot
    }

    public func transfer(snapshotPath: String, shardID: Int, targetNodeID: String) async throws -> String {
        let destDir = "\(targetRoot)/shards/shard-\(String(format: "%04d", shardID))"
        try FileManager.default.createDirectory(atPath: destDir, withIntermediateDirectories: true)
        let destPath = "\(destDir)/main.sqlite"
        if FileManager.default.fileExists(atPath: destPath) {
            try FileManager.default.removeItem(atPath: destPath)
        }
        try FileManager.default.copyItem(atPath: snapshotPath, toPath: destPath)
        return destPath
    }

    public func activateOnTarget(shardID: Int, targetNodeID: String, snapshotPath: String) async throws {
        // For local transfers, the file is already in place — no remote activation needed
    }
}

// MARK: - Shard Migration Coordinator

/// Coordinates the migration of shards between nodes.
///
/// Implements the seven-step migration protocol from the architecture canvas:
/// 1. Mark shard as migrating
/// 2. Quiesce writes (drain)
/// 3. Snapshot the shard (WAL checkpoint + file copy)
/// 4. Transfer the snapshot file to the target node
/// 5. Reopen on target node (activate)
/// 6. Switch router epoch (atomic cutover)
/// 7. Resume writes (close on source)
public actor ShardMigrationCoordinator {
    private let shardManager: SQLiteShardManager
    private let ownership: ShardOwnershipMap
    private let transferAgent: ShardTransferAgent
    private let snapshotsDir: String

    public init(
        shardManager: SQLiteShardManager,
        ownership: ShardOwnershipMap,
        transferAgent: ShardTransferAgent,
        snapshotsDir: String
    ) {
        self.shardManager = shardManager
        self.ownership = ownership
        self.transferAgent = transferAgent
        self.snapshotsDir = snapshotsDir
    }

    /// Execute a full migration for a single shard
    public func migrateShard(_ shardID: Int, to targetNodeID: String) async throws -> MigrationResult {
        let startTime = Date()
        let sourceNodeID = await ownership.ownerNode(for: shardID) ?? "unknown"

        do {
            // Step 1: Mark as migrating
            try await ownership.beginMigration(shardID: shardID, targetNodeID: targetNodeID)

            // Step 2: Drain — quiesce writes
            try await ownership.beginDrain(shardID: shardID)

            // Step 3: Snapshot — checkpoint WAL and copy the database file
            let snapshotPath = try await snapshotShard(shardID)
            let snapshotSize = fileSize(at: snapshotPath)

            // Step 4: Transfer to target
            let targetPath = try await transferAgent.transfer(
                snapshotPath: snapshotPath,
                shardID: shardID,
                targetNodeID: targetNodeID
            )

            // Step 5: Activate on target
            try await transferAgent.activateOnTarget(
                shardID: shardID,
                targetNodeID: targetNodeID,
                snapshotPath: targetPath
            )

            // Step 6: Epoch cutover — atomic ownership flip
            try await ownership.completeMigration(shardID: shardID)

            // Step 7: Close shard on source
            await shardManager.closeShard(shardID)

            // Clean up snapshot
            try? FileManager.default.removeItem(atPath: snapshotPath)

            let newEpoch = await ownership.currentEpoch

            return MigrationResult(
                shardID: shardID,
                sourceNodeID: sourceNodeID,
                targetNodeID: targetNodeID,
                epoch: newEpoch,
                snapshotSizeBytes: snapshotSize,
                durationSeconds: Date().timeIntervalSince(startTime),
                success: true,
                error: nil
            )
        } catch {
            // Rollback on failure — best-effort, swallow errors
            try? await ownership.rollbackMigration(shardID: shardID)

            return MigrationResult(
                shardID: shardID,
                sourceNodeID: sourceNodeID,
                targetNodeID: targetNodeID,
                epoch: await ownership.currentEpoch,
                snapshotSizeBytes: 0,
                durationSeconds: Date().timeIntervalSince(startTime),
                success: false,
                error: error.localizedDescription
            )
        }
    }

    /// Execute migrations for multiple shards according to a rebalance plan.
    ///
    /// Migrations run sequentially to avoid overwhelming the system.
    /// Stops on first failure to prevent cascading issues.
    public func executePlan(_ plan: RebalancePlan) async -> [MigrationResult] {
        var results: [MigrationResult] = []

        for move in plan.moves {
            let result: MigrationResult
            do {
                result = try await migrateShard(move.shardID, to: move.targetNodeID)
            } catch {
                result = MigrationResult(
                    shardID: move.shardID,
                    sourceNodeID: move.sourceNodeID,
                    targetNodeID: move.targetNodeID,
                    epoch: 0,
                    snapshotSizeBytes: 0,
                    durationSeconds: 0,
                    success: false,
                    error: "Migration threw unexpectedly: \(error.localizedDescription)"
                )
            }
            results.append(result)

            // Stop on first failure to prevent cascading issues
            if !result.success {
                break
            }
        }

        return results
    }

    // MARK: - Private

    private func snapshotShard(_ shardID: Int) async throws -> String {
        let pool = try await shardManager.openShard(shardID)
        let snapshotDir = "\(snapshotsDir)/migration"
        try FileManager.default.createDirectory(atPath: snapshotDir, withIntermediateDirectories: true)
        let snapshotPath = "\(snapshotDir)/shard-\(String(format: "%04d", shardID)).sqlite"

        // Checkpoint WAL first for a clean snapshot
        try await pool.write { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }

        // Copy the database file (WAL is checkpointed, so the main file is complete)
        let sourcePath = await shardManager.shardPath(shardID)
        if FileManager.default.fileExists(atPath: snapshotPath) {
            try FileManager.default.removeItem(atPath: snapshotPath)
        }
        try FileManager.default.copyItem(atPath: sourcePath, toPath: snapshotPath)

        return snapshotPath
    }

    private func fileSize(at path: String) -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
    }
}
