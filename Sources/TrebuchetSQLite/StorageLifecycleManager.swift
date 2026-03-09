import Foundation
import GRDB

/// The current phase of the storage lifecycle.
public enum StorageLifecyclePhase: String, Sendable, Codable {
    case uninitialized
    case bootstrapping
    case preparing
    case active
    case shuttingDown
    case shutdown
}

/// Events emitted during lifecycle transitions.
public enum StorageLifecycleEvent: Sendable {
    case phaseChanged(from: StorageLifecyclePhase, to: StorageLifecyclePhase)
    case shardOpened(shardID: Int)
    case shardClosed(shardID: Int)
    case recoveryStarted(shardID: Int)
    case recoveryCompleted(shardID: Int)
    case walCheckpointed(shardID: Int)
    case routingMigrationRequired(from: String, to: String)
    case routingMigrationStarted(from: String, to: String, oldShardCount: Int, newShardCount: Int)
    case routingMigrationResumed(state: RoutingMigrationState)
    case routingMigrationCompleted
    case error(String)
}

/// Configuration for the lifecycle manager.
public struct StorageLifecycleConfiguration: Sendable {
    /// Root directory for database files
    public var root: String
    /// Number of shards
    public var shardCount: Int
    /// Node identifier
    public var nodeID: String
    /// Whether to run WAL checkpoint on shutdown
    public var checkpointOnShutdown: Bool
    /// Whether to verify integrity on bootstrap
    public var verifyIntegrityOnBootstrap: Bool
    /// Maximum acceptable WAL size in bytes before warning
    public var walSizeWarningThreshold: UInt64
    /// Expected routing mode for this deployment
    public var routing: RoutingMode

    public init(
        root: String = ".trebuchet/db",
        shardCount: Int = 1,
        nodeID: String = "local",
        checkpointOnShutdown: Bool = true,
        verifyIntegrityOnBootstrap: Bool = true,
        walSizeWarningThreshold: UInt64 = 50 * 1024 * 1024,  // 50 MB
        routing: RoutingMode = .maglev()
    ) {
        self.root = root
        self.shardCount = shardCount
        self.nodeID = nodeID
        self.checkpointOnShutdown = checkpointOnShutdown
        self.verifyIntegrityOnBootstrap = verifyIntegrityOnBootstrap
        self.walSizeWarningThreshold = walSizeWarningThreshold
        self.routing = routing
    }
}

/// Orchestrates the full storage lifecycle for a Trebuchet node.
///
/// Manages the transition through bootstrap → prepare → activate → shutdown,
/// coordinating the shard manager, ownership map, and health checker.
public actor StorageLifecycleManager {
    public private(set) var phase: StorageLifecyclePhase = .uninitialized

    private let configuration: StorageLifecycleConfiguration
    private let shardManager: SQLiteShardManager
    private let ownership: ShardOwnershipMap
    private var eventHandler: (@Sendable (StorageLifecycleEvent) -> Void)?

    public init(
        configuration: StorageLifecycleConfiguration,
        shardManager: SQLiteShardManager,
        ownership: ShardOwnershipMap
    ) {
        self.configuration = configuration
        self.shardManager = shardManager
        self.ownership = ownership
    }

    /// Set a handler for lifecycle events (logging, metrics, etc.)
    public func onEvent(_ handler: @escaping @Sendable (StorageLifecycleEvent) -> Void) {
        self.eventHandler = handler
    }

    // MARK: - Lifecycle Phases

    /// Execute the full startup sequence: bootstrap → prepare → activate.
    public func start() async throws {
        try await bootstrap()
        try await prepare()
        try await activate()
    }

    /// Phase 1: Bootstrap
    /// - Create directory layout
    /// - Load or initialize ownership metadata
    /// - Initialize shard manager
    public func bootstrap() async throws {
        let oldPhase = phase
        phase = .bootstrapping
        emit(.phaseChanged(from: oldPhase, to: .bootstrapping))

        // Create directory structure
        try await shardManager.initialize()

        // Create snapshots directory
        let snapshotsDir = "\(configuration.root)/snapshots"
        try FileManager.default.createDirectory(atPath: snapshotsDir, withIntermediateDirectories: true)

        // Load or initialize ownership
        do {
            try await ownership.load()

            let persistedMode = await ownership.routingMode
            let configuredName = configuration.routing.persistedName
            let persistedName = persistedMode ?? "modulo"
            let ownershipShardCount = await ownership.shardCount
            let ownershipRecordCount = await ownership.records.count
            let persistedShardCount = ownershipShardCount ?? ownershipRecordCount
            let existingMigration = await ownership.routingMigration

            let routingChanged = persistedName != configuredName
            let shardCountChanged = persistedShardCount != configuration.shardCount

            if routingChanged || shardCountChanged {
                if let existing = existingMigration {
                    // Migration already in progress — resume it
                    emit(.routingMigrationResumed(state: existing))
                } else {
                    // Start a new migration
                    let previousTableSize: Int?
                    if case .maglev(let ts) = RoutingMode.from(persistedName: persistedName) {
                        previousTableSize = ts
                    } else {
                        previousTableSize = nil
                    }

                    let migrationState = RoutingMigrationState(
                        previousRoutingMode: persistedName,
                        previousShardCount: persistedShardCount,
                        previousTableSize: previousTableSize,
                        startedAt: Date(),
                        migratedCount: 0
                    )
                    await ownership.setMigrationState(migrationState)
                    await ownership.setShardCount(configuration.shardCount)
                    await ownership.setRoutingMode(configuredName)

                    // Create new shard directories if expanding
                    if configuration.shardCount > persistedShardCount {
                        let shardsDir = "\(configuration.root)/shards"
                        for i in persistedShardCount..<configuration.shardCount {
                            let shardDir = "\(shardsDir)/shard-\(String(format: "%04d", i))"
                            try FileManager.default.createDirectory(
                                atPath: shardDir,
                                withIntermediateDirectories: true
                            )
                        }
                    }

                    // Update ownership records for new shard count
                    await ownership.initializeDefault(shardCount: configuration.shardCount)
                    await ownership.setRoutingMode(configuredName)
                    await ownership.setShardCount(configuration.shardCount)
                    await ownership.setMigrationState(migrationState)
                    try await ownership.save()

                    emit(.routingMigrationStarted(
                        from: persistedName,
                        to: configuredName,
                        oldShardCount: persistedShardCount,
                        newShardCount: configuration.shardCount
                    ))
                }
            }
        } catch {
            // No existing ownership file — initialize defaults
            await ownership.initializeDefault(shardCount: configuration.shardCount)
            await ownership.setRoutingMode(configuration.routing.persistedName)
            await ownership.setShardCount(configuration.shardCount)
            try await ownership.save()
        }
    }

    /// Migrate the persisted routing strategy to match the current configuration.
    ///
    /// This updates the ownership metadata to record the new routing mode.
    /// **Important:** This does NOT move actor data between shards. Use
    /// ``RebalancePlanner/planShardExpansion(actorIDs:oldShardCount:newShardCount:tableSize:)``
    /// to compute the required data migrations, then execute them before calling this method.
    public func migrateRoutingStrategy() async throws {
        let configuredName = configuration.routing.persistedName
        await ownership.setRoutingMode(configuredName)
        try await ownership.save()
    }

    /// Phase 2: Prepare
    /// - Verify SQLite files exist and are accessible
    /// - Check WAL health
    /// - Run integrity checks if configured
    /// - Open locally-owned shards
    public func prepare() async throws {
        let ownedShards = await ownership.shardsOnNode(configuration.nodeID)

        for record in ownedShards {
            let shardID = record.shardID

            // Open the shard (creates the file if needed)
            let pool = try await shardManager.openShard(shardID)
            emit(.shardOpened(shardID: shardID))

            // Verify integrity if configured
            if configuration.verifyIntegrityOnBootstrap {
                let issues = try verifyShardIntegrity(pool: pool, shardID: shardID)
                for issue in issues {
                    emit(.error("Shard \(shardID): \(issue)"))
                }
            }

            // Check WAL size
            let walPath = await shardManager.shardPath(shardID) + "-wal"
            if let attrs = try? FileManager.default.attributesOfItem(atPath: walPath),
               let walSize = attrs[.size] as? UInt64,
               walSize > configuration.walSizeWarningThreshold {
                emit(.error("Shard \(shardID): WAL size \(walSize) exceeds threshold \(configuration.walSizeWarningThreshold)"))
            }
        }
    }

    /// Phase 3: Activate — mark the node as ready for traffic.
    public func activate() async throws {
        let oldPhase = phase
        phase = .active
        emit(.phaseChanged(from: oldPhase, to: .active))
    }

    /// Graceful shutdown.
    /// - Stop accepting writes (via phase change)
    /// - Checkpoint WAL on each shard if configured
    /// - Close all shard pools
    public func shutdown() async throws {
        let oldPhase = phase
        phase = .shuttingDown
        emit(.phaseChanged(from: oldPhase, to: .shuttingDown))

        let ownedShards = await ownership.shardsOnNode(configuration.nodeID)

        for record in ownedShards {
            let shardID = record.shardID

            if configuration.checkpointOnShutdown {
                // Best-effort WAL checkpoint
                if let pool = try? await shardManager.openShard(shardID) {
                    try? await pool.write { db in
                        try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
                    }
                    emit(.walCheckpointed(shardID: shardID))
                }
            }

            await shardManager.closeShard(shardID)
            emit(.shardClosed(shardID: shardID))
        }

        phase = .shutdown
        emit(.phaseChanged(from: .shuttingDown, to: .shutdown))
    }

    // MARK: - Recovery

    /// Recover a single shard after a crash or restart.
    /// - Reopens the GRDB pool
    /// - Verifies WAL state
    /// - Checks ownership epoch
    public func recoverShard(_ shardID: Int) async throws {
        emit(.recoveryStarted(shardID: shardID))

        // Reopen the pool (GRDB handles WAL recovery automatically)
        let pool = try await shardManager.openShard(shardID)
        emit(.shardOpened(shardID: shardID))

        // Verify integrity
        let issues = try verifyShardIntegrity(pool: pool, shardID: shardID)
        for issue in issues {
            emit(.error("Recovery shard \(shardID): \(issue)"))
        }

        // Verify ownership
        let isOwned = await ownership.isLocallyOwned(shardID)
        if !isOwned {
            emit(.error("Shard \(shardID) is not owned by this node (\(configuration.nodeID))"))
        }

        emit(.recoveryCompleted(shardID: shardID))
    }

    /// Recover all locally-owned shards.
    public func recoverAllShards() async throws {
        let ownedShards = await ownership.shardsOnNode(configuration.nodeID)
        for record in ownedShards {
            try await recoverShard(record.shardID)
        }
    }

    // MARK: - Queries

    /// Whether the manager is in an active state accepting operations.
    public var isActive: Bool {
        phase == .active
    }

    /// The current routing migration state, if any.
    public func routingMigration() async -> RoutingMigrationState? {
        await ownership.routingMigration
    }

    // MARK: - Private

    private func verifyShardIntegrity(pool: DatabasePool, shardID: Int) throws -> [String] {
        var issues: [String] = []

        try pool.read { db in
            // Quick integrity check
            let result = try String.fetchOne(db, sql: "PRAGMA integrity_check(1)")
            if result != "ok" {
                issues.append("Integrity check failed: \(result ?? "unknown")")
            }

            // Verify WAL mode
            let journalMode = try String.fetchOne(db, sql: "PRAGMA journal_mode")
            if journalMode != "wal" {
                issues.append("Expected WAL mode, found: \(journalMode ?? "unknown")")
            }

            // Check foreign keys
            let fkViolations = try Int.fetchOne(db, sql: "PRAGMA foreign_key_check") ?? 0
            if fkViolations > 0 {
                issues.append("Found \(fkViolations) foreign key violation(s)")
            }
        }

        return issues
    }

    private func emit(_ event: StorageLifecycleEvent) {
        eventHandler?(event)
    }
}
