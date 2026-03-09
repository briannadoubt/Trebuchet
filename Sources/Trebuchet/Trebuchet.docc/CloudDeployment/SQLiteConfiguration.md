# SQLite State Storage

Configure SQLite for zero-dependency local actor state persistence with optional sharding for multi-node deployments.

## Overview

The TrebuchetSQLite module provides a local SQLite storage engine backed by [GRDB](https://github.com/groue/GRDB.swift). No external database server is required — actor state is stored on disk next to your running process.

**Design principle:** SQLite handles local storage, Trebuchet handles distribution. When multiple nodes run in a cluster, Trebuchet routes each actor request to the node that owns its shard. Within a node, all reads and writes go to a local SQLite file.

```
Single node:  actor → local GRDB pool → local SQLite file
Multi-node:   Trebuchet routes to owning node → same local write path
```

All database pools use WAL mode (`journal_mode=WAL`, `synchronous=NORMAL`) for safe concurrent reads alongside writes.

## Quick Start

Enable SQLite persistence in your System DSL:

```swift
import Trebuchet
import TrebuchetSQLite

struct MySystem: System {
    var topology: some Topology {
        Actor(ChatRoom.self, id: "main")
            .state(.sqlite(path: nil))  // nil = default path in .trebuchet/db/
    }
}
```

Or configure the state store directly when hosting actors:

```swift
import TrebuchetSQLite

let stateStore = try await SQLiteStateStore(path: ".trebuchet/db/state.sqlite")

let gateway = CloudGateway(configuration: .init(
    stateStore: stateStore,
    registry: myRegistry
))
```

## Storage Patterns

### Generic Blob Store

`SQLiteStateStore` serializes entire actor state as JSON into a managed `actor_state` table. This is the default pattern — zero boilerplate.

```swift
// Save actor state
try await stateStore.save(myState, for: "actor-123")

// Load actor state
let state = try await stateStore.load(for: "actor-123", as: MyState.self)

// Optimistic locking — throws ActorStateError.versionConflict on mismatch
let newVersion = try await stateStore.saveIfVersion(
    myState,
    for: "actor-123",
    expectedVersion: 3
)
```

### Domain-Specific Tables

For actors that need queryable data, access the underlying `DatabasePool` directly via the `pool` property. Both patterns can coexist in the same shard database — the generic store uses its own `actor_state` table and does not interfere with domain tables.

```swift
import TrebuchetSQLite
import GRDB

// Define a GRDB model
struct DBMessage: Codable, FetchableRecord, PersistableRecord {
    var id: String
    var conversationID: String
    var text: String
    var timestamp: Date
}

// Query via the pool
let pool = stateStore.pool
let messages = try await pool.read { db in
    try DBMessage
        .filter(Column("conversationID") == conversationID)
        .order(Column("timestamp").desc)
        .limit(50)
        .fetchAll(db)
}
```

## Sharding

For multi-node deployments, the `SQLiteShardManager` distributes actor state across multiple SQLite files using deterministic hash-based routing:

```
shard = hash(actorID) % shardCount
```

Each shard is a fully independent SQLite database with its own WAL, its own `DatabasePool`, and its own file on disk.

### On-Disk Layout

```
.trebuchet/db/
  shards/
    shard-0000/
      main.sqlite
      main.sqlite-wal
      main.sqlite-shm
    shard-0001/
      main.sqlite
    ...
  metadata/
    topology.json       # Shard count, mode
    ownership.json      # Which node owns which shard (epoch-gated)
  snapshots/
    2024-03-08_daily/   # Named snapshot sets
```

### Sizing Guidance

| Deployment | Nodes | Shards | Notes |
|------------|-------|--------|-------|
| Local dev | 1 | 1 | No sharding overhead |
| Small production | 1–3 | 4–16 | Room to rebalance later |
| Medium cluster | 4–12 | 16–128 | Good load distribution |
| Large cluster | 12+ | 64–256 | Start with more shards than needed |

The key rule: **start with more shards than you think you need.** Each shard is cheap — an empty SQLite file is 0 bytes until first write — and having more shards enables finer-grained rebalancing. You can always move shards onto fewer nodes, but splitting a shard requires data migration.

### Ownership and Routing

Every shard has an owner node tracked in `ownership.json`. The ownership map uses **monotonic epochs** — every reassignment bumps the epoch, so stale routing is always detectable.

```json
{
  "globalEpoch": 3,
  "shards": [
    { "shardID": 0, "ownerNodeID": "node-1", "epoch": 1, "status": { "type": "active" } },
    { "shardID": 1, "ownerNodeID": "node-2", "epoch": 3, "status": { "type": "active" } }
  ]
}
```

## Shard Migration

When a shard moves between nodes, `ShardMigrationCoordinator` executes a 7-step protocol that is **safe to interrupt at any point**:

1. **Mark migrating** — ownership.json records intent; shard still serves traffic
2. **Drain** — quiesce writes, let in-flight operations complete
3. **Snapshot** — WAL checkpoint + file copy
4. **Transfer** — copy snapshot to target node
5. **Activate on target** — target opens the transferred database file
6. **Epoch cutover** — atomic ownership flip, bumps globalEpoch
7. **Close on source** — source closes its pool, cleans up snapshot

The epoch only flips in step 6, after the target has confirmed it can serve the data. If the process crashes at steps 1–5, the source continues owning the shard.

## Rebalancing

When nodes are added or removed, `RebalancePlanner` computes the minimum number of shard moves to reach even distribution:

```bash
$ trebuchet db rebalance --nodes node-1,node-2,node-3 --plan

Rebalance Plan
  Total shards: 12
  Target nodes: node-1, node-2, node-3
  Ideal per node: 4

  Planned moves (4):
    shard-0004: node-1 -> node-3
    shard-0005: node-1 -> node-3
    ...
```

Use `--apply` instead of `--plan` to execute the moves.

## CLI Reference: `trebuchet db`

The `trebuchet db` command family manages SQLite storage from the terminal. All commands invoke `/usr/bin/sqlite3` directly — no GRDB dependency in the CLI.

| Command | Description |
|---------|-------------|
| `db init --shards N` | Create directory layout, empty shard files, topology metadata |
| `db status [--verbose]` | Show shard sizes, WAL sizes, table and row counts |
| `db doctor` | Integrity checks, WAL mode validation, oversized WAL warnings |
| `db migrate` | Verify shard accessibility (GRDB migrations run automatically on connect) |
| `db snapshot [--name X]` | WAL checkpoint + `sqlite3 .backup` for consistent snapshots |
| `db restore <name>` | Restore shard files from a named snapshot |
| `db compact [--vacuum]` | WAL checkpoint with optional VACUUM for disk reclamation |
| `db shell <shard> [--read-write]` | Interactive `sqlite3` shell (read-only by default) |
| `db inspect <shard> [--table X] [--schema] [--verbose]` | Inspect tables, schemas, row counts, records |
| `db ownership show\|init\|set` | View, initialize, or modify the shard-to-node ownership map |
| `db rebalance --nodes a,b,c [--plan\|--apply]` | Compute and optionally execute shard redistribution |

### Common Workflows

```bash
# Initialize storage with 8 shards
trebuchet db init --shards 8

# Check shard health
trebuchet db doctor

# Inspect a specific shard
trebuchet db inspect 0 --schema --verbose

# Take a named snapshot before a deployment
trebuchet db snapshot --name pre-deploy-v2

# Restore from a snapshot if something goes wrong
trebuchet db restore pre-deploy-v2

# Compact storage after deleting many actors
trebuchet db compact --vacuum
```

## Health Monitoring

`ShardHealthChecker` provides per-shard health reports and a cluster-wide `StorageHealthReport`:

- SQLite integrity check (`PRAGMA integrity_check`)
- WAL mode validation
- WAL size monitoring with configurable thresholds
- Migration status tracking

`StorageMetrics` tracks rolling-window statistics: write/read latency (min, max, mean, p50, p99), open shard count, WAL size, and checkpoint/snapshot counters.

## See Also

- <doc:PostgreSQLConfiguration> - PostgreSQL for multi-instance state synchronization
- <doc:DeployingToAWS> - DynamoDB state store for AWS Lambda deployments
- <doc:CloudDeploymentOverview> - Overview of state storage options
