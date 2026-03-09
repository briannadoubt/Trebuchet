# Trebuchet SQLite Architecture Canvas

## Purpose
Design and implement a simple, low-cost, horizontally scalable persistence architecture for the Trebuchet distributed actor runtime using SQLite as the default storage engine and GRDB as the Swift integration layer.

This document is intended to be an implementation-ready architecture and planning canvas for Trebuchet’s database subsystem, including:

- the core SQLite architecture
- Swift-facing interfaces and protocols
- actor and shard lifecycle behavior
- deployment models from local dev to production clusters
- object-storage-backed durability options
- operational model and failure handling
- `trebuchet db` CLI design and subcommands

Primary goals:

- extremely low operational complexity
- minimal infrastructure cost
- clean Swift-first API surface
- compatibility with Trebuchet distributed actors
- support for both persistent-node and mostly-stateless-node deployments
- straightforward local development and production operations

---

# Executive Summary

Trebuchet should treat SQLite as a **local durable storage engine**, not as a network database. Trebuchet itself provides the distribution layer through actor routing, placement, ownership, and migration.

Core idea:

- actors own state
- SQLite persists state locally
- GRDB provides the Swift integration layer
- Trebuchet routes requests to the node that owns the relevant actor or shard
- optional object storage provides portable durability for stateless recovery and migration

This avoids the complexity of running a distributed database while preserving strong performance and low cost.

---

# Architectural Positioning

## What SQLite is doing

SQLite is the default on-node persistence engine for Trebuchet services.

SQLite is responsible for:

- durable local writes
- append-only event log storage
- efficient ordered reads
- compact deployment footprint
- fast recovery from local disk

SQLite is not responsible for:

- cluster-wide consensus
- distributed transactions
- network query serving
- shard discovery
- actor placement

Those responsibilities belong to Trebuchet.

## What GRDB is doing

GRDB is the Swift integration layer over SQLite.

GRDB is responsible for:

- Swift-friendly record mapping
- migrations
- connection and pool configuration
- concurrency-safe reads and writes
- transaction boundaries
- schema lifecycle support

GRDB should be Trebuchet’s default SQLite adapter implementation.

## What Trebuchet is doing

Trebuchet is the distributed systems layer.

Trebuchet is responsible for:

- actor placement
- shard ownership
- routing
- actor activation and deactivation
- replication policy hooks
- migration orchestration
- recovery orchestration
- deployment topology modeling

---

# Design Principles

## 1. Actor-Owned Data
Each actor owns the data it mutates.

Examples:

ConversationActor → message log
UserActor → user profile and device registry
DeviceActor → per-device session state
DeliveryActor → delivery tracking
KeyServerActor → prekey bundles and sender key metadata

This eliminates most distributed coordination because ownership is explicit.

## 2. Append-Only First
Trebuchet persistence should be log-oriented wherever possible.

For messaging workloads in particular:

- writes append events
- reads replay or scan ordered logs
- mutation-heavy row updates are minimized
- recovery is deterministic

## 3. Local-First Storage
The hot path should always be:

Trebuchet actor
→ local GRDB pool
→ local SQLite file

No network database hop should be required for standard actor persistence.

## 4. Deterministic Routing
The system must be able to answer:

- which node owns this actor?
- which shard stores this keyspace?
- how does a request reach it?

This should be deterministic from topology state and shard routing rules.

## 5. Portable Durability
Durability should not depend exclusively on a single machine surviving forever.

Trebuchet should support:

- local persistent-disk durability
- snapshot backups
- replica streams
- portable segment upload to object storage

## 6. Operational Simplicity
Everything about this design should be simpler than running Postgres clusters, Cassandra, FoundationDB, or a managed distributed database.

---

# Storage Modes

Trebuchet should support two primary SQLite operating modes.

## Mode A: Persistent Node Mode

Each node owns local shard files on durable disk.

Characteristics:

- simplest runtime model
- best hot-path latency
- ideal for local development and small production deployments
- requires durable node disks and backups

Flow:

actor request
→ local SQLite write
→ optional backup/replication

## Mode B: Portable Log Mode

Nodes are mostly stateless compute hosts. Durable log segments are uploaded to object storage and loaded on activation or migration.

Characteristics:

- easier node replacement
- simpler recovery from total node loss
- better support for actor mobility
- somewhat more lifecycle complexity

Flow:

actor activated
→ pull durable segments
→ reconstruct or mount local state
→ process writes locally
→ rotate/upload segments

Trebuchet should begin with Mode A and later add Mode B as an advanced deployment option.

---

# Data Model Strategy

## Event-Log-Oriented Storage

For chat-like or actor-log workloads, state should be modeled as ordered events.

Examples:

- message sent
- delivery acknowledged
- participant added
- participant removed
- prekey consumed
- device registered

This enables:

- deterministic replay
- incremental sync
- easier replication
- easier actor migration

## State + Log Hybrid

Some actor types should use a hybrid model:

- append log for history and durability
- materialized state tables for fast current-state lookup

Example:

ConversationActor:
- messages table as append-only log
- conversation_state table as materialized summary

DeliveryActor:
- delivery_events append log
- delivery_state current-state table

---

# Suggested SQLite Schema Patterns

## Messages

```sql
CREATE TABLE messages (
    conversation_id BLOB NOT NULL,
    message_id INTEGER NOT NULL,
    sender_device BLOB NOT NULL,
    ciphertext BLOB NOT NULL,
    timestamp INTEGER NOT NULL,
    PRIMARY KEY (conversation_id, message_id)
);

CREATE INDEX idx_messages_conversation
ON messages(conversation_id, message_id);
```

## Delivery State

```sql
CREATE TABLE delivery (
    conversation_id BLOB NOT NULL,
    message_id INTEGER NOT NULL,
    device_id BLOB NOT NULL,
    state INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    PRIMARY KEY (message_id, device_id)
);

CREATE INDEX idx_delivery_device
ON delivery(device_id, state);
```

## Devices

```sql
CREATE TABLE devices (
    device_id BLOB PRIMARY KEY,
    user_id BLOB NOT NULL,
    identity_key BLOB NOT NULL,
    signed_prekey BLOB,
    last_seen INTEGER NOT NULL
);
```

## Prekeys

```sql
CREATE TABLE prekeys (
    device_id BLOB NOT NULL,
    prekey_id INTEGER NOT NULL,
    public_key BLOB NOT NULL,
    consumed_at INTEGER,
    PRIMARY KEY (device_id, prekey_id)
);
```

## Shard Metadata

```sql
CREATE TABLE shard_metadata (
    shard_id INTEGER PRIMARY KEY,
    role TEXT NOT NULL,
    epoch INTEGER NOT NULL,
    node_id TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);
```

---

# GRDB Integration

## Why GRDB

GRDB is the right default because Trebuchet is Swift-native and needs:

- a mature SQLite wrapper
- good concurrency semantics
- strong migrations story
- type-safe record APIs
- support for direct SQL where needed

Trebuchet should standardize on GRDB `DatabasePool` for server workloads.

## DatabasePool vs DatabaseQueue

Use `DatabasePool` by default for server-side Trebuchet storage because it provides:

- concurrent readers
- serialized writes
- good WAL compatibility
- safe shared access patterns

`DatabaseQueue` remains useful for:

- tests
- very small single-threaded tools
- specialized single-writer local flows

## Baseline GRDB Configuration

```swift
import GRDB

public enum TrebuchetSQLiteConfiguration {
    public static func make(path: String) throws -> DatabasePool {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL;")
            try db.execute(sql: "PRAGMA synchronous = NORMAL;")
            try db.execute(sql: "PRAGMA temp_store = MEMORY;")
            try db.execute(sql: "PRAGMA foreign_keys = ON;")
        }
        return try DatabasePool(path: path, configuration: config)
    }
}
```

## GRDB Module Boundary

Suggested package/module split:

- `TrebuchetDBCore` → protocols, IDs, metadata, abstractions
- `TrebuchetDBSQLite` → GRDB-backed implementation
- `TrebuchetDBObjectStore` → durable segment/object store integration
- `TrebuchetDBCLI` → CLI bindings and operational commands

---

# Swift Interfaces

Trebuchet should define its database layer through narrow Swift protocols so that higher layers do not depend directly on GRDB implementation details.

## Core Storage Protocol

```swift
public protocol TrebuchetStore: Sendable {
    func prepare() async throws
    func beginLifecycle() async throws
    func shutdown() async throws
}
```

## Shard-Oriented Storage Protocol

```swift
public protocol TrebuchetShardStore: TrebuchetStore {
    associatedtype ShardID: Hashable & Sendable

    func openShard(_ shardID: ShardID) async throws
    func closeShard(_ shardID: ShardID) async throws
    func compactShard(_ shardID: ShardID) async throws
    func snapshotShard(_ shardID: ShardID) async throws -> URL
}
```

## Messaging Store Protocol

```swift
public protocol MessageStore: Sendable {
    func appendMessage(_ envelope: MessageEnvelope) async throws
    func fetchMessages(
        conversationID: ConversationID,
        after messageID: MessageID?,
        limit: Int
    ) async throws -> [MessageEnvelope]
}
```

## Delivery Store Protocol

```swift
public protocol DeliveryStore: Sendable {
    func markQueued(_ messageID: MessageID, for deviceID: DeviceID) async throws
    func markDelivered(_ messageID: MessageID, for deviceID: DeviceID) async throws
    func markAcknowledged(_ messageID: MessageID, for deviceID: DeviceID) async throws
    func pendingMessages(for deviceID: DeviceID, limit: Int) async throws -> [MessageID]
}
```

## Key Store Protocol

```swift
public protocol KeyStore: Sendable {
    func storePrekeyBundle(_ bundle: PrekeyBundle, for deviceID: DeviceID) async throws
    func fetchPrekeyBundle(for deviceID: DeviceID) async throws -> PrekeyBundle?
    func consumeOneTimePrekey(for deviceID: DeviceID) async throws -> OneTimePrekey?
}
```

## Object Storage Protocol

```swift
public protocol DurableSegmentStore: Sendable {
    func uploadSegment(localURL: URL, key: String) async throws
    func downloadSegment(key: String, to localURL: URL) async throws
    func listSegments(prefix: String) async throws -> [String]
}
```

## Router Protocol

```swift
public protocol ShardRouter: Sendable {
    func shardID(for conversationID: ConversationID) -> Int
    func ownerNode(for shardID: Int) -> NodeID
}
```

The rest of Trebuchet should depend primarily on these protocols rather than directly on GRDB APIs.

---

# Lifecycle Model

Trebuchet’s database layer needs an explicit lifecycle. This is one of the most important pieces because it determines how local state, activation, recovery, compaction, migration, and shutdown work.

## Lifecycle Phases

### 1. Bootstrap
Node starts. Configuration loads. Local shard registry is read.

Tasks:

- load topology metadata
- determine owned shards
- initialize database root directory
- create/open GRDB pools for local shards
- run migrations
- register shard ownership with runtime

### 2. Preparation
Storage backend verifies local files and optional remote durability state.

Tasks:

- verify SQLite files
- verify WAL health
- recover unfinished snapshots if needed
- reconcile shard metadata
- check object storage connectivity if configured

### 3. Activation
Actors and shards become available for routing.

Tasks:

- open shard pools
- start local actor supervisors
- enable request routing
- warm hot shards if desired

### 4. Hot Operation
Normal processing.

Tasks:

- append events
- serve reads
- rotate segments
- emit snapshots/backups
- compact old state
- report health/metrics

### 5. Migration / Rebalancing
Ownership moves from one node to another.

Tasks:

- mark shard as migrating
- quiesce writes
- snapshot or stream delta
- transfer durable state
- reopen on target node
- switch router epoch
- resume writes

### 6. Recovery
Node or actor comes back after failure.

Tasks:

- recover local SQLite files if present
- otherwise restore from snapshots or durable segments
- replay pending events
- verify epoch/ownership
- rejoin routing

### 7. Shutdown
Graceful teardown.

Tasks:

- stop accepting new writes
- flush in-flight operations
- checkpoint WAL if desired
- emit final snapshot if configured
- close GRDB pools

---

# Actor Lifecycle Integration

Trebuchet actor lifecycles should integrate tightly with storage ownership.

## Actor Activation

When an actor activates:

- determine shard ID
- verify local ownership or route remotely
- open or reuse shard pool
- load materialized actor state
- optionally replay events to rebuild derived state
- begin serving requests

## Actor Deactivation

When an actor deactivates:

- flush buffered operations
- persist final checkpoints
- release ephemeral caches
- optionally keep shard pool open if shared

## Actor Migration

When actor ownership moves:

- source actor enters draining mode
- write barrier established
- snapshot or segment stream produced
- target actor reconstructs state
- routing epoch flips
- source actor deactivates

Trebuchet should define a migration contract that storage implementations can hook into.

---

# Sharding Strategy

## Maglev Consistent Hashing

Trebuchet uses Google's Maglev consistent hashing algorithm for shard assignment:

```text
shard = maglevTable[hash(key) % tableSize]
```

The Maglev algorithm builds a fixed-size lookup table (default 65537 entries) using dual-hash permutations (FNV-1a + DJB2). Each shard name generates a unique permutation sequence that populates the table in round-robin fashion.

Benefits:

- **Minimal disruption**: only ~1/(N+1) keys remap when adding a shard (vs ~75% with modulo)
- Deterministic and reproducible across restarts
- O(1) lookup after table construction
- Even distribution across shards
- No external coordination required

### Lazy Migration on Shard Count Change

When the configured shard count changes (e.g., 4 → 5 shards), Trebuchet migrates actors transparently:

1. On boot, `StorageLifecycleManager` detects the config differs from persisted state
2. `ShardedStateStore` enters **migration mode**:
   - Reads miss on new shard → fall back to old shard → copy row to new shard → delete from old
   - Writes clean up stale copies on old shards automatically
3. `RoutingMigrationSweeper` runs in the background migrating cold actors in batches
4. When sweep completes, migration state is cleared and the store returns to normal mode

Migration state is persisted in `ownership.json` to survive restarts. The process is crash-safe via `INSERT OR REPLACE` ordering — if a crash occurs between copy and delete, the actor exists on both shards and the new shard wins on restart.

## Multiple Shards Per Node

Each node should host multiple shard files, not just one. This improves load spreading and future rebalancing.

Example:

- 4 nodes
- 32 total shards
- 8 shards per node initially

## Hot Shard Isolation

Trebuchet should be able to isolate very hot conversations or keyspaces onto dedicated shards or nodes.

This may later evolve into:

- shard splitting
- conversation pinning
- dedicated hot-group placement

---

# Local Directory Layout

Suggested on-disk structure:

```text
/var/lib/trebuchet/
  db/
    shards/
      shard-0000/
        main.sqlite
        main.sqlite-wal
        main.sqlite-shm
      shard-0001/
        main.sqlite
    snapshots/
    staging/
    metadata/
      topology.json
      ownership.json
      migrations.json
```

For portable log mode:

```text
/var/lib/trebuchet/
  cache/
    conversations/
  segments/
    staging/
```

---

# Portable Log / Stateless Node Mode

## Rationale

This mode allows nodes to be mostly replaceable compute hosts. Object storage becomes the source of durable conversation history.

## Segment Model

Conversation logs are segmented by size or time.

Example object keys:

```text
conversations/<conversation-id>/segments/00000001.sqlite
conversations/<conversation-id>/segments/00000002.sqlite
```

Alternative format:

```text
shards/<shard-id>/segments/<epoch>/<segment-id>.sqlite
```

## Activation Flow

On actor or shard activation:

- determine required segments
- download latest snapshot or base segment
- download subsequent delta segments
- mount locally or replay into local DB
- resume actor service

## Rotation Flow

When a segment reaches threshold:

- seal segment
- write metadata
- upload to object store
- begin new local segment

## Cache Eviction Flow

For inactive conversations:

- flush local state
- persist checkpoint
- close pool or archive local cache
- remove local segment copies if needed

This mode should be optional, not required for the first implementation.

---

# Deployment Models

## Local Development

Single-machine setup.

Components:

- Trebuchet runtime
- SQLite via GRDB
- optional local file snapshots

Recommended defaults:

- one node
- 1–4 local shards
- no object storage required
- `trebuchet db doctor` and `trebuchet db inspect` for local ops

## Small Production

1–3 persistent nodes.

Components:

- Trebuchet runtime
- SQLite via GRDB
- local durable SSD/NVMe
- periodic snapshot uploads to object storage

Recommended defaults:

- persistent node mode
- deterministic shard placement
- nightly snapshots
- optional standby restore flow

## Medium Cluster

4–12 nodes.

Components:

- Trebuchet runtime cluster
- 16–128 shards
- SQLite on local SSD/NVMe
- shard ownership metadata
- rolling rebalancing support
- object-store backups

Recommended defaults:

- persistent node mode initially
- optional per-shard backups
- controlled migration tooling

## Elastic / Mostly Stateless Cluster

Advanced mode.

Components:

- Trebuchet runtime nodes
- local ephemeral SSD cache
- portable log segments in object storage
- actor restore/replay flow
- active shard warming and eviction

Recommended only after base architecture is stable.

---

# Operational Model

## Backups

Trebuchet should support:

- full shard snapshots
- incremental snapshot manifests
- WAL checkpoint-before-snapshot option
- upload to S3-compatible stores

## Compaction

Trebuchet should support per-shard compaction tasks.

Examples:

- VACUUM windows
- segment sealing
- old-message archival
- tombstone cleanup

## Health Checks

Trebuchet should surface:

- shard open/closed status
- SQLite file health
- last successful backup time
- WAL size warnings
- migration lock state
- object store reachability

## Metrics

Expose at least:

- write latency
- read latency
- queue depth
- open shard count
- WAL size
- checkpoint frequency
- snapshot duration
- segment upload/download duration
- restore time

---

# Failure Handling

## Node Crash with Persistent Disk Intact

Recovery:

- restart runtime
- reopen GRDB pools
- verify shard ownership
- replay or inspect WAL
- rejoin cluster

## Node Loss with Disk Lost

Recovery options:

- restore latest snapshot to replacement node
- replay later deltas if available
- reassign shard ownership

## Partial Migration Failure

Recovery:

- migration remains epoch-gated
- router continues sending traffic to source until target confirms readiness
- rollback allowed before cutover

## Object Storage Unavailable

Behavior:

- persistent-node mode continues locally
- backup/upload tasks queue or fail with clear status
- stateless portable-log mode may block new activation of cold shards if required segments unavailable

---

# Security Model

## At Rest

Trebuchet should support optional SQLite file encryption layers where appropriate, but the default design should assume application-level encrypted payloads for message bodies.

## In Transit

Trebuchet cluster RPC and object-store access must use TLS.

## Key Material

Signal-compatible key data requires careful separation:

- public and signed prekeys may be stored normally
- highly sensitive material should be minimized on server side
- message bodies remain encrypted blobs

## Backups

Backups and portable segments should support:

- bucket-level encryption
- optional application-managed envelope encryption
- manifest integrity verification

---

# Integration with `trebuchet db`

Trebuchet should have a first-class database CLI namespace. This is how developers and operators will actually interact with the storage layer.

## CLI Goals

The `trebuchet db` suite should make local development, inspection, migration, backup, restore, and operations approachable without needing users to manually inspect SQLite files or write their own scripts.

## Top-Level Shape

```text
trebuchet db <subcommand> [options]
```

## Proposed Core Subcommands

### `trebuchet db init`

Initialize database root, create directories, write metadata, and prepare shard files.

Responsibilities:

- create database directory layout
- initialize shard metadata
- create empty shard files
- write topology defaults
- optionally run initial migrations

Example:

```text
trebuchet db init --path .trebuchet/db --shards 16
```

### `trebuchet db migrate`

Run pending GRDB/SQLite migrations across local shards.

Responsibilities:

- discover local shard files
- run migration set
- report version state
- fail safely on partial migration

Example:

```text
trebuchet db migrate --path /var/lib/trebuchet/db
```

### `trebuchet db status`

Show storage topology and health.

Responsibilities:

- list local shards
- show open/closed state
- show ownership and epoch
- show SQLite file size and WAL size
- show last snapshot/backup time

Example:

```text
trebuchet db status --verbose
```

### `trebuchet db inspect`

Inspect a shard, conversation, or metadata record.

Responsibilities:

- inspect shard schema
- inspect table counts
- inspect a conversation log
- inspect delivery queues
- inspect key metadata

Examples:

```text
trebuchet db inspect shard 3

trebuchet db inspect conversation 01HXYZ...
```

### `trebuchet db doctor`

Validate and diagnose local storage health.

Responsibilities:

- check for corruption indicators
- verify required tables and indexes
- validate metadata consistency
- inspect WAL health
- report unsafe configuration

Example:

```text
trebuchet db doctor --repair-suggestions
```

### `trebuchet db snapshot`

Create a local or remote snapshot.

Responsibilities:

- checkpoint if configured
- create consistent snapshot artifact
- optionally upload to object store
- emit manifest metadata

Examples:

```text
trebuchet db snapshot --shard 4

trebuchet db snapshot --all --upload
```

### `trebuchet db restore`

Restore a shard or database root from snapshot.

Responsibilities:

- download snapshot if remote
- unpack to target path
- verify metadata compatibility
- update ownership state if requested

Examples:

```text
trebuchet db restore --snapshot s3://bucket/shard-0003.tar.zst
```

### `trebuchet db compact`

Run storage compaction tasks.

Responsibilities:

- VACUUM shard
- checkpoint WAL
- seal/upload old segments
- prune stale cache files

Example:

```text
trebuchet db compact --shard 3
```

### `trebuchet db rebalance`

Plan or execute shard redistribution.

Responsibilities:

- compute ownership changes
- show migration plan
- optionally execute controlled migration
- coordinate epoch cutover

Examples:

```text
trebuchet db rebalance --plan

trebuchet db rebalance --apply
```

### `trebuchet db segments`

Manage portable log mode segments.

Responsibilities:

- list segments
- inspect manifests
- upload sealed segments
- fetch segments locally
- repair missing manifests

Examples:

```text
trebuchet db segments list --conversation 01HXYZ...

trebuchet db segments upload --pending
```

### `trebuchet db shell`

Open an operator shell for local shard inspection.

Responsibilities:

- select shard DB
- open read-only by default
- expose safe SQL inspection mode

Example:

```text
trebuchet db shell --shard 1
```

## Recommended Additional Subcommands

- `trebuchet db vacuum`
- `trebuchet db checkpoint`
- `trebuchet db backup list`
- `trebuchet db backup prune`
- `trebuchet db ownership show`
- `trebuchet db ownership set`
- `trebuchet db warm`
- `trebuchet db evict`

---

# How `trebuchet db` Maps to Runtime Lifecycle

The CLI should correspond directly to the runtime lifecycle model.

- bootstrap → `init`, `migrate`
- preparation → `doctor`, `status`
- hot operation → `status`, `inspect`, `shell`
- durability → `snapshot`, `restore`, `segments`
- maintenance → `compact`, `vacuum`, `checkpoint`
- scaling → `rebalance`, `ownership`

This alignment is important so that operators can reason about the system consistently.

---

# Trebuchet Runtime API Concepts

Trebuchet should expose storage as a configuration primitive in the topology DSL.

## Example Service Configuration

```swift
struct ChatService: Service {
    var topology: some Topology {
        Cluster {
            ConversationActor.self
            DeliveryActor.self
            KeyServerActor.self
        }
        .storage(
            .sqlite(
                root: "/var/lib/trebuchet/db",
                shards: 32,
                durability: .snapshots(bucket: "trebuchet-prod"),
                mode: .persistentNodes
            )
        )
    }
}
```

## Portable Log Example

```swift
struct ChatService: Service {
    var topology: some Topology {
        Cluster {
            ConversationActor.self
        }
        .storage(
            .sqlite(
                root: "/var/lib/trebuchet/cache",
                shards: 64,
                durability: .portableSegments(bucket: "trebuchet-prod"),
                mode: .portableLogs
            )
        )
    }
}
```

## Storage Configuration Surface

Trebuchet should likely define something conceptually like:

```swift
public enum StorageBackend {
    case sqlite(root: String, shards: Int, durability: DurabilityMode, mode: SQLiteMode)
}

public enum SQLiteMode {
    case persistentNodes
    case portableLogs
}

public enum DurabilityMode {
    case none
    case snapshots(bucket: String)
    case portableSegments(bucket: String)
}
```

This can evolve, but the shape should remain explicit and operationally understandable.

---

# Implementation Phases

## Phase 1: Core SQLite Foundation

Deliver:

- `TrebuchetDBCore`
- `TrebuchetDBSQLite`
- local directory layout
- GRDB configuration
- shard creation/open/close
- migration framework
- `trebuchet db init|migrate|status|doctor`

## Phase 2: Actor Persistence Integration

Deliver:

- `MessageStore`, `DeliveryStore`, `KeyStore`
- actor activation hooks
- local persistent-node mode
- message append and fetch flows
- delivery tracking

## Phase 3: Durability and Operations

Deliver:

- snapshot creation and restore
- object storage integration
- `snapshot`, `restore`, `compact`, `shell`
- metrics and health reporting

## Phase 4: Rebalancing and Migration

Deliver:

- ownership metadata
- shard migration protocol
- rebalance planner
- epoch cutover logic
- `trebuchet db rebalance`

## Phase 5: Portable Log Mode

Deliver:

- segment manifests
- upload/download flows
- cache warming/eviction
- stateless actor activation from object storage
- `trebuchet db segments`

---

# Open Design Questions

These should be resolved before implementation hardens:

1. Should shard ownership metadata live only in local files, or also in a cluster control plane?
2. What is the minimum migration barrier needed for safe shard handoff?
3. How much state should be replayed from log vs stored as materialized summary tables?
4. Should `trebuchet db shell` support read-write mode or remain read-only except behind a flag?
5. What backup artifact format is preferred: raw SQLite copy, tarball, or manifest + segments?
6. How aggressively should portable-log mode evict local cache files?
7. Should encryption-at-rest be a first-class built-in concern or left to deployment environment initially?

---

# Recommended Immediate Next Steps

1. Freeze the protocol surface for `TrebuchetStore`, `TrebuchetShardStore`, and the first domain stores.
2. Build `TrebuchetDBSQLite` around GRDB `DatabasePool`.
3. Implement the initial on-disk layout and migration system.
4. Implement `trebuchet db init`, `migrate`, `status`, and `doctor` first.
5. Wire `ConversationActor` persistence end-to-end on a single node.
6. Add snapshot and restore before attempting migration and portable logs.
7. Only after the persistent-node model is solid, add object-store-backed portable-log mode.

---

# Summary

Trebuchet does not need a distributed database to offer distributed persistence. It should instead use:

- SQLite as the local storage engine
- GRDB as the Swift integration layer
- actor ownership as the sharding model
- Trebuchet routing as the distribution mechanism
- optional snapshots or portable segments for durability and recovery
- `trebuchet db` as the operational control surface

This gives Trebuchet a database architecture that is:

- Swift-native
- cheap to run
- simple to manage
- easy to develop locally
- scalable enough for serious messaging workloads
- extensible into more advanced portable-log and stateless-node deployments

