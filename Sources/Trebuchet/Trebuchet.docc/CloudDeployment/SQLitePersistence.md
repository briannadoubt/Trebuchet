# SQLite Persistence

Configure SQLite as the persistence backend for Trebuchet actors — zero setup, production-ready, with optional sharding.

## Overview

TrebuchetSQLite is the recommended state store for most Trebuchet deployments. It stores actor state in local SQLite files managed by GRDB, with WAL mode enabled for high read concurrency and single-digit-microsecond read latency.

**Why SQLite?**

- **Zero infrastructure** — no external database process to run or manage
- **ACID transactions** — full durability guarantees out of the box
- **High read performance** — memory-mapped I/O, WAL mode, per-connection page cache
- **Built-in sharding** — distribute actors across multiple files for write-heavy workloads
- **Zero-downtime resharding** — actors migrate transparently on first access via lazy read-through

Compare to other options:

| Feature | SQLite | PostgreSQL | DynamoDB |
|---------|--------|-----------|----------|
| **Setup** | Zero config | Server required | AWS account |
| **ACID** | ✅ | ✅ | ❌ Limited |
| **Cost** | Free | Free | Pay per request |
| **Multi-node shared state** | ❌ (route to owner) | ✅ | ✅ |
| **Sharding** | ✅ Built-in | Manual partitioning | Native |

> Tip: If you need a shared external database accessible from multiple independent processes simultaneously, use PostgreSQL or DynamoDB. SQLite works best when Trebuchet routes each actor to its owning node and that node owns the database files.

## Quick Start

Add `TrebuchetSQLite` to your package dependencies:

```swift
.product(name: "TrebuchetSQLite", package: "Trebuchet")
```

Then implement `makeStateStore(for:)` on your `System`:

```swift
import Trebuchet
import TrebuchetSQLite

@main struct MyGame: System {
    static func makeStateStore(
        for config: StateConfiguration
    ) async throws -> (any Sendable)? {
        try await Self.makeSQLiteStateStore(for: config)
    }

    var topology: some Topology {
        GameRoom.self
            .expose(as: "game-room")
            .state(.sqlite())
    }
}
```

That's it. Trebuchet creates a single SQLite file at `.trebuchet/db/shards/shard-0000/main.sqlite` and wires it into your actor system automatically.

## Sharding

For workloads that generate high write volume, distribute actors across multiple SQLite shard files. Each shard is an independent database with its own WAL, connection pool, and filesystem footprint.

### Enabling Shards

Pass `shards:` in the topology DSL:

```swift
var topology: some Topology {
    GameRoom.self
        .expose(as: "game-room")
        .state(.sqlite(shards: 4))
}
```

Actors are assigned to shards via `MaglevHasher` — Google's Maglev consistent hashing algorithm — so adding a shard remaps only ~1/(N+1) of actors rather than ~75% with modulo hashing.

The resulting layout on disk:

```
.trebuchet/db/
  shards/
    shard-0000/main.sqlite
    shard-0001/main.sqlite
    shard-0002/main.sqlite
    shard-0003/main.sqlite
  metadata/
    topology.json
```

### Choosing a Shard Count

- **1 shard** (default) — suitable for most single-server deployments
- **4–16 shards** — appropriate for workloads with thousands of concurrent actors
- **16+ shards** — high-throughput scenarios; monitor `cacheSizeKB` to control memory usage

> Important: Once you set a shard count in production, reducing it triggers a migration. Increasing is safe with minimal remapping.

## Lazy Migration

When `shards:` changes between deployments, Trebuchet migrates actors transparently — no downtime or manual migration scripts:

1. **Reads** — on a miss in the new shard, the store falls back to the old shard, copies the row, then deletes the stale copy.
2. **Writes** — save to the new shard, clean up any stale copy on the old shard.
3. **Background sweep** — a `RoutingMigrationSweeper` actor migrates cold actors (those not accessed organically) in batches, throttled to avoid starving normal traffic.

Migration state is persisted to `ownership.json` and survives restarts. On restart after a crash during migration, the new shard wins (via `INSERT OR REPLACE` ordering).

## Configuration

For advanced tuning, build a `SQLiteStorageConfiguration` directly:

```swift
import TrebuchetSQLite

let config = SQLiteStorageConfiguration(
    root: ".trebuchet/db",  // root directory for all shard files
    shardCount: 8,           // number of SQLite shard files
    cacheSizeKB: 512,        // page cache per GRDB connection (default 2048)
    maglevTableSize: 65537   // prime lookup table size for Maglev (default 65537)
)
let manager = SQLiteShardManager(configuration: config)
try await manager.initialize()
let store = await ShardedStateStore(shardManager: manager)
```

### Tuning `cacheSizeKB`

Each GRDB `DatabasePool` opens multiple connections (1 writer + up to 5 readers). Every connection maintains its own page cache. With the default of 2048 KB per connection, a 16-shard setup can use ~770 MB just for page caches.

Tune this down for actor-state workloads:

- `2048` — SQLite default, suits read-heavy analytical queries
- `512` — ~2 MB per connection, reasonable for most Trebuchet workloads
- `256` — ~1 MB per connection, minimal footprint

## Stateful Actors

Use `StatefulActor` from `TrebuchetCloud` to persist actor state automatically:

```swift
import Trebuchet
import TrebuchetCloud

@Trebuchet
distributed actor GameRoom: StatefulActor {
    typealias PersistentState = GameState

    @StreamedState var state = GameState()
    let stateStore: any ActorStateStore

    var persistentState: GameState {
        get { state }
        set { state = newValue }
    }

    distributed func updateScore(player: String, points: Int) async throws {
        try await transformState(store: stateStore) { current in
            var next = current
            next.scores[player, default: 0] += points
            return next
        }
    }
}
```

The `actorSystem.stateStore` property (available when `TrebuchetCloud` is imported) carries the store created by `makeStateStore(for:)`, so `StatefulActor` implementations can access it at init time.

## Health Monitoring

`ShardHealthChecker` provides per-shard and cluster-wide health:

```swift
let checker = ShardHealthChecker(shardManager: manager)
let report = await checker.checkHealth()
// report.status: .healthy / .degraded / .unhealthy
// report.shards: per-shard WAL size, file size, integrity check result
```

`StorageMetrics` exposes latency statistics:

```swift
let metrics = StorageMetrics()
// After operations:
let stats = metrics.readStats()
// stats.p50, stats.p99, stats.mean in microseconds
```

## See Also

- <doc:TrebuchetSQLite>
- <doc:CloudDeployment/PostgreSQLConfiguration>
- <doc:StateVersioning>
