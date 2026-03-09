# TrebuchetSQLite Module

Local SQLite persistence for Trebuchet distributed actors, backed by GRDB.

## Overview

TrebuchetSQLite gives every actor a local SQLite database. The design principle is clear: **SQLite handles local storage, Trebuchet handles distribution.** No external database server is required.

```swift
import TrebuchetSQLite

// Simple: let Trebuchet manage the database
let stateStore = try await SQLiteStateStore()

// With a specific path
let stateStore = try await SQLiteStateStore(path: ".trebuchet/db/actors.sqlite")

// With an existing GRDB DatabasePool
let stateStore = try await SQLiteStateStore(dbPool: myPool)
```

Actor state is serialized as JSON into a managed `actor_state` table. For actors that need queryable data — messages, users, etc. — you can access the underlying `DatabasePool` directly via the `pool` property.

## State Storage

- ``SQLiteStateStore``
- ``SQLiteStorageConfiguration``

## Sharding and Distribution

- ``SQLiteShardManager``
- ``ShardOwnershipMap``
- ``ShardMigrationCoordinator``
- ``RebalancePlanner``

## Operations and Health

- ``StorageLifecycleManager``
- ``ShardHealthChecker``
- ``StorageMetrics``
