# TrebuchetSQLite Module

The recommended persistence backend for Trebuchet distributed actors — zero-config SQLite with built-in sharding.

## Overview

TrebuchetSQLite provides a production-ready ``ActorStateStore`` implementation backed by SQLite via GRDB. It requires no external services, delivers single-digit-microsecond reads through memory-mapped I/O, and scales horizontally via a built-in Maglev-hashed sharding architecture.

```swift
import TrebuchetSQLite

@main struct MyGame: System {
    static func makeStateStore(
        for config: StateConfiguration
    ) async throws -> (any Sendable)? {
        try await Self.makeSQLiteStateStore(for: config)
    }

    var topology: some Topology {
        GameRoom.self.state(.sqlite(shards: 4))
    }
}
```

## State Store

- `SQLiteStateStore` - Core ``ActorStateStore`` for a single SQLite database file. Stores state as JSON with a monotonic sequence number for optimistic locking.
- `ShardedStateStore` - Sharding-aware ``ActorStateStore`` that routes operations to the correct shard via Maglev consistent hashing. Use this when your workload exceeds what a single SQLite file can sustain.

## Sharding

- `SQLiteShardManager` - Manages the shard directory layout, creates and opens per-shard SQLite files, and provides pool access keyed by shard index.
- `MaglevHasher` - Consistent hash ring using Google's Maglev algorithm. Only ~1/(N+1) keys remap when a shard is added, versus ~75% with modulo hashing.
- `MaglevMigrationPlanner` - Plans which actors need to move when the shard count changes, based on old vs. new Maglev hash assignments.

## Lazy Migration

- `RoutingMigrationSweeper` - Background actor that migrates cold actors from old shards after a shard count change. Iterates shards in batches with cursor-based pagination, throttled to avoid starving normal traffic.
- `RoutingMigrationState` - Persisted migration state (stored in `ownership.json`) that survives restarts. Records which actors have been migrated and which are still pending.

## Configuration

- `SQLiteStorageConfiguration` - Configuration for the storage layer. Key properties:
  - `shardCount` — number of SQLite shard files (default 1)
  - `cacheSizeKB` — page cache size per GRDB connection in kilobytes (default 2048)
  - `maglevTableSize` — prime size for the Maglev lookup table (default 65537)
  - `root` — root directory for all database files (default `.trebuchet/db`)

## System Integration

- `System.makeSQLiteStateStore(for:)` — One-liner convenience method on the ``System`` protocol. Pass it from your ``System/makeStateStore(for:)`` override to wire SQLite into the topology DSL.

## Health and Observability

- `ShardHealthChecker` - Runs SQLite integrity checks and monitors WAL and file sizes, producing per-shard health reports with healthy/degraded/unhealthy status.
- `StorageMetrics` - Collects latency samples for reads, writes, and deletes, and exposes aggregated statistics (min, max, mean, p50, p99).
- `StorageLifecycleManager` - Drives the storage layer through lifecycle phases (uninitialized → bootstrapping → active → shutdown).

## Rebalancing

- `ShardMigrationCoordinator` - Orchestrates live shard moves between nodes by draining writes, snapshotting the database, transferring it to the target node, and updating ownership atomically.
- `RebalancePlanner` - Computes a minimal set of shard moves to reach an even distribution across nodes.
- `ShardOwnershipMap` - Tracks which node owns each shard, used by the transport layer for routing and by the migration coordinator for planning.

## See Also

- <doc:CloudDeployment/SQLitePersistence>
- <doc:CloudDeployment/PostgreSQLConfiguration>
