/// TrebuchetSQLite - The recommended persistence backend for Trebuchet distributed actors.
///
/// This module provides a production-ready ``ActorStateStore`` implementation backed by
/// SQLite via GRDB. It is the default choice for Trebuchet deployments because it requires
/// no external services, delivers single-digit-microsecond reads through memory-mapped I/O,
/// and scales horizontally via a built-in sharding architecture.
///
/// ## Why SQLite?
///
/// SQLite eliminates the operational overhead of running a separate database process.
/// Actor state lives on the same node that owns the actor, so every read is local and
/// every write goes through SQLite's battle-tested WAL journal. Trebuchet's transport
/// layer handles routing requests to the correct node -- the storage path stays local
/// regardless of cluster size.
///
/// - **Single server:** actor -> local GRDB pool -> local SQLite file.
/// - **Multi-server:** Trebuchet routes to the owning node; the same local write path applies.
///
/// ## Sharding Architecture
///
/// For workloads that exceed what a single SQLite file can sustain, TrebuchetSQLite
/// distributes actors across multiple shard files. Each shard is an independent SQLite
/// database with its own WAL, connection pool, and file-system footprint:
///
/// ```
/// .trebuchet/db/
///   shards/
///     shard-0000/main.sqlite
///     shard-0001/main.sqlite
///   metadata/
///     topology.json
/// ```
///
/// Actors are assigned to shards via consistent hashing on their actor ID, ensuring
/// even distribution and minimal reshuffling when shards are added or removed.
///
/// ## Key Types
///
/// - ``SQLiteStateStore`` -- Core ``ActorStateStore`` conformance. Stores actor state as
///   JSON alongside a monotonic sequence number for optimistic locking. Supports both
///   single-file and pooled configurations.
///
/// - ``SQLiteShardManager`` -- Manages the shard directory layout, creates and opens
///   shard database files, and provides pool access keyed by shard ID.
///
/// - ``ShardOwnershipMap`` -- Tracks which node owns each shard. Used by the transport
///   layer to route requests and by the migration coordinator to plan moves.
///
/// - ``StorageLifecycleManager`` -- Drives the storage layer through its lifecycle
///   phases (uninitialized -> bootstrapping -> active -> shutdown), opening and closing
///   shard databases, running WAL checkpoints, and emitting lifecycle events.
///
/// - ``ShardHealthChecker`` -- Runs SQLite integrity checks, monitors WAL and file
///   sizes, and produces per-shard and cluster-wide health reports with a simple
///   healthy/degraded/unhealthy status.
///
/// - ``StorageMetrics`` -- Collects latency samples for reads, writes, and deletes,
///   and exposes aggregated statistics (min, max, mean, p50, p99) for observability.
///
/// - ``ShardMigrationCoordinator`` -- Orchestrates live shard moves between nodes by
///   draining writes, snapshotting the database file, transferring it to the target
///   node, and updating ownership atomically.
///
/// - ``RebalancePlanner`` -- Given the current shard distribution and set of live nodes,
///   computes a minimal set of ``ShardMove`` operations to reach an even distribution.
///
/// ## Usage
///
/// ```swift
/// import TrebuchetSQLite
///
/// // Simplest setup -- single database file
/// let store = try await SQLiteStateStore(path: ".trebuchet/db/state.sqlite")
///
/// // Sharded setup for higher throughput
/// let config = SQLiteStorageConfiguration(root: ".trebuchet/db", shardCount: 4)
/// let manager = SQLiteShardManager(configuration: config)
/// try await manager.initialize()
/// let pool = try await manager.pool(for: 0)
/// let store = try await SQLiteStateStore(dbPool: pool)
///
/// // Wire into a CloudGateway
/// let gateway = CloudGateway(configuration: .init(stateStore: store))
/// ```
///
/// ## GRDB Re-export
///
/// This module re-exports GRDB so consumers can use `DatabasePool`, `DatabaseQueue`,
/// and GRDB's query interface without adding a separate dependency.
@_exported import GRDB
@_exported import TrebuchetCloud
