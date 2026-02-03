# Getting Started with TrebuchetSurrealDB

Learn how to integrate SurrealDB with your Trebuchet distributed actors.

## Overview

TrebuchetSurrealDB provides two main patterns for data persistence:

1. **ActorStateStore Pattern**: Framework-managed state using ``SurrealDBStateStore``
2. **Direct ORM Pattern**: Full control using SurrealDB's ORM directly

## Installation

Add TrebuchetSurrealDB to your Package.swift dependencies:

```swift
dependencies: [
    .package(url: "https://github.com/your-org/Trebuchet.git", from: "0.2.0"),
]
```

Add it to your target:

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "TrebuchetSurrealDB", package: "Trebuchet"),
    ]
)
```

## ActorStateStore Pattern

For simple state persistence, use ``SurrealDBStateStore``:

```swift
import Trebuchet
import TrebuchetCloud
import TrebuchetSurrealDB

@Trebuchet
distributed actor Counter: StatefulActor {
    struct State: Codable, Sendable {
        var count: Int = 0
    }

    let stateStore: SurrealDBStateStore
    var state = State()

    init(actorSystem: TrebuchetActorSystem, stateStore: SurrealDBStateStore) async throws {
        self.actorSystem = actorSystem
        self.stateStore = stateStore

        // Load persisted state
        if let loaded = try await stateStore.load(for: id.id, as: State.self) {
            state = loaded
        }
    }

    distributed func increment() async throws {
        state.count += 1
        try await stateStore.save(state, for: id.id)
    }
}
```

## Direct ORM Pattern

For full control over your data models:

```swift
import Trebuchet
import SurrealDB
import TrebuchetSurrealDB

@Trebuchet
distributed actor TodoList {
    private let db: SurrealDB

    struct Todo: Codable, Sendable {
        @ID var id: String?
        var text: String
        var completed: Bool
        var actorId: String

        static var tableName: String { "todos" }
    }

    init(actorSystem: TrebuchetActorSystem, db: SurrealDB) async throws {
        self.actorSystem = actorSystem
        self.db = db

        // Auto-generate schema
        try await db.defineTable(for: Todo.self)
    }

    distributed func addTodo(_ text: String) async throws -> Todo {
        var todo = Todo(text: text, completed: false, actorId: id.id)
        return try await db.create(todo)
    }

    distributed func getTodos() async throws -> [Todo] {
        return try await db.query(
            Todo.self,
            where: [\.actorId == id.id]
        )
    }
}
```

## Development Setup

Use the default development configuration:

```swift
let config = SurrealDBConfiguration.development()
let stateStore = try await SurrealDBStateStore(configuration: config)
```

This connects to:
- URL: `ws://localhost:8000/rpc`
- Namespace: `development`
- Database: `development`
- Auth: Root (root/root)

## Production Setup

Use environment variables for production:

```bash
export SURREALDB_URL="ws://your-server:8000/rpc"
export SURREALDB_NAMESPACE="production"
export SURREALDB_DATABASE="myapp"
export SURREALDB_USERNAME="your-username"
export SURREALDB_PASSWORD="your-password"
```

```swift
let config = try SurrealDBConfiguration.fromEnvironment()
let stateStore = try await SurrealDBStateStore(configuration: config)
```

## Next Steps

- Learn about <doc:Configuration> options
- Explore <doc:DirectORMUsage> patterns
- Build <doc:GraphRelationships> with edge tables
