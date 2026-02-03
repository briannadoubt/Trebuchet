# TrebuchetSurrealDB Module

SurrealDB integration for Trebuchet distributed actors with type-safe ORM support.

## Overview

TrebuchetSurrealDB provides seamless integration between Trebuchet distributed actors and SurrealDB, enabling type-safe data persistence with automatic schema generation.

```swift
import TrebuchetSurrealDB

// Configure SurrealDB state store
let stateStore = try await SurrealDBStateStore(
    url: "ws://localhost:8000/rpc",
    namespace: "development",
    database: "myapp"
)

// Use with CloudGateway
let gateway = try await CloudGateway.withSurrealDB(
    url: "ws://localhost:8000/rpc",
    namespace: "development",
    database: "myapp"
)

// Expose actors
try await gateway.expose(TodoList(actorSystem: gateway.system, db: gateway.db))
```

## State Storage

- `SurrealDBStateStore` - ActorStateStore implementation using SurrealDB
- `StatefulActor` - Protocol for actors with persistent state

## Configuration

- `SurrealDBConfiguration` - Configuration for SurrealDB connections
- `SurrealDBConnectionPool` - Connection pooling for high-performance scenarios

## CloudGateway Extensions

- `CloudGateway.withSurrealDB(configuration:)` - Create gateway with SurrealDB state store
- `CloudGateway.withSurrealDB(url:namespace:database:username:password:)` - Create gateway with direct parameters
- `CloudGateway.withSurrealDBFromEnvironment()` - Create gateway from environment variables

## ORM Features

TrebuchetSurrealDB re-exports the SurrealDB Swift ORM, providing:

- Type-safe models with property wrappers (`@ID`, `@Index`, `@Relation`)
- Automatic schema generation from Swift types
- KeyPath-based queries for type safety
- Graph relationships with EdgeModel protocol
- Optimistic locking with version conflict detection

For detailed ORM usage, see the [surrealdb-swift documentation](https://github.com/surrealdb/surrealdb.swift).
