# TrebuchetSurrealDB

SurrealDB integration for Trebuchet distributed actors with type-safe ORM support.

## Overview

TrebuchetSurrealDB provides seamless integration between Trebuchet distributed actors and SurrealDB, enabling:

- **Type-safe models** using `SurrealModel` protocol
- **Automatic schema generation** from Swift types
- **ActorStateStore implementation** for framework-managed state
- **Direct ORM access** for custom domain models
- **Graph relationships** for related actors and entities
- **Type-safe queries** using KeyPath syntax

## Installation

Add TrebuchetSurrealDB to your Package.swift:

```swift
dependencies: [
    .package(url: "https://github.com/your-org/Trebuchet.git", from: "0.2.0"),
],
targets: [
    .target(
        name: "YourTarget",
        dependencies: [
            .product(name: "TrebuchetSurrealDB", package: "Trebuchet"),
        ]
    ),
]
```

## Quick Start

### Option 1: Using ActorStateStore Pattern

For simple state persistence, use the `SurrealDBStateStore`:

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

    init(actorSystem: TrebuchetRuntime, stateStore: SurrealDBStateStore) async throws {
        self.actorSystem = actorSystem
        self.stateStore = stateStore

        // Load persisted state
        if let loaded = try await stateStore.load(for: id.id, as: State.self) {
            state = loaded
        }
    }

    distributed func increment() async throws {
        state.count += 1
        try await persistState()
    }

    private func persistState() async throws {
        try await stateStore.save(state, for: id.id)
    }
}
```

### Option 2: Using Direct ORM Access

For full control over your data models, use SurrealDB's ORM directly:

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

    init(actorSystem: TrebuchetRuntime, db: SurrealDB) async throws {
        self.actorSystem = actorSystem
        self.db = db

        // Auto-generate schema from Swift type
        try await db.defineTable(for: Todo.self)
    }

    distributed func addTodo(_ text: String) async throws -> Todo {
        var todo = Todo(text: text, completed: false, actorId: id.id)
        return try await db.create(todo)
    }

    distributed func getTodos() async throws -> [Todo] {
        return try await db.query(
            Todo.self,
            where: [\.actorId == id.id],
            orderBy: [(\.text, true)]
        )
    }

    distributed func toggleTodo(_ todoId: String) async throws {
        guard var todo = try await db.select(todoId) as Todo? else {
            throw TodoError.notFound
        }
        todo.completed.toggle()
        _ = try await db.update(todo)
    }
}
```

## Configuration

### Development

Use the configuration helpers for quick setup:

```swift
import TrebuchetSurrealDB

// Option 1: Default development configuration
let config = SurrealDBConfiguration.development()
let stateStore = try await SurrealDBStateStore(configuration: config)

// Option 2: Custom configuration
let config = SurrealDBConfiguration(
    url: "ws://localhost:8000/rpc",
    namespace: "development",
    database: "myapp",
    auth: .root(username: "root", password: "root")
)
let stateStore = try await SurrealDBStateStore(configuration: config)

// Option 3: Direct parameters
let stateStore = try await SurrealDBStateStore(
    url: "ws://localhost:8000/rpc",
    namespace: "development",
    database: "myapp",
    username: "root",
    password: "root"
)
```

### Production

Use environment variables for production deployments:

```bash
export SURREALDB_URL="ws://your-server:8000/rpc"
export SURREALDB_NAMESPACE="production"
export SURREALDB_DATABASE="myapp"
export SURREALDB_USERNAME="your-username"
export SURREALDB_PASSWORD="your-password"
```

```swift
import TrebuchetSurrealDB

// Load configuration from environment
let config = try SurrealDBConfiguration.fromEnvironment()
let stateStore = try await SurrealDBStateStore(configuration: config)
```

### CloudGateway Integration

Use the CloudGateway extensions for seamless integration:

```swift
import TrebuchetCloud
import TrebuchetSurrealDB

// Option 1: From environment (recommended for production)
let gateway = try await CloudGateway.withSurrealDBFromEnvironment()

// Option 2: With configuration object
let config = SurrealDBConfiguration.development()
let gateway = try await CloudGateway.withSurrealDB(configuration: config)

// Option 3: Direct parameters
let gateway = try await CloudGateway.withSurrealDB(
    url: "ws://localhost:8000/rpc",
    namespace: "development",
    database: "myapp"
)

// Expose actors
try await gateway.expose(TodoList(actorSystem: gateway.system, db: gateway.db))
try await gateway.run()
```

## ORM Features

### Type-Safe Models

Define models using Swift types:

```swift
import SurrealDB

struct User: Codable, Sendable {
    @ID var id: String?
    var username: String
    var email: String
    var createdAt: Date

    static var tableName: String { "users" }
}
```

### Automatic Schema Generation

Generate database schema from your Swift types:

```swift
// Define the table schema
try await db.defineTable(for: User.self)

// This generates and executes:
// DEFINE TABLE users SCHEMAFULL;
// DEFINE FIELD username ON users TYPE string;
// DEFINE FIELD email ON users TYPE string;
// DEFINE FIELD createdAt ON users TYPE datetime;
```

### Type-Safe Queries

Query with KeyPath-based conditions:

```swift
// Simple query
let users = try await db.query(User.self)

// Query with conditions
let activeUsers = try await db.query(
    User.self,
    where: [\.createdAt > Date().addingTimeInterval(-86400)]
)

// Query with multiple conditions, ordering, and limit
let topUsers = try await db.query(
    User.self,
    where: [
        \.username != "",
        \.email != ""
    ],
    orderBy: [(\.createdAt, false)],  // false = descending
    limit: 10
)
```

### Graph Relationships

Model relationships using edge tables:

```swift
struct GameRoom: Codable, Sendable {
    @ID var id: String?
    var name: String
    var maxPlayers: Int

    static var tableName: String { "game_rooms" }
}

struct Player: Codable, Sendable {
    @ID var id: String?
    var username: String
    var score: Int

    static var tableName: String { "players" }
}

// Edge table connecting players to rooms
struct PlayerInRoom: Codable, Sendable {
    @ID var id: String?
    var from: String  // Player ID
    var to: String    // GameRoom ID
    var team: String?
    var joinedAt: Date

    static var tableName: String { "player_in_room" }
}

// Create relationship
let edge = PlayerInRoom(
    from: player.id!,
    to: room.id!,
    team: "blue",
    joinedAt: Date()
)
_ = try await db.create(edge)

// Query relationships
let edges = try await db.query(
    PlayerInRoom.self,
    where: [\.to == room.id!]
)
let playerIds = edges.map(\.from)
```

## Advanced Features

### Connection Pooling

For high-performance scenarios, use connection pooling:

```swift
import TrebuchetSurrealDB

// Create connection pool
let pool = SurrealDBConnectionPool(
    configuration: config,
    maxConnections: 10
)

// Use connection from pool
let result = try await pool.withConnection { db in
    try await db.query(User.self)
}

// Cleanup
await pool.shutdown()
```

### Optimistic Locking

Use version checks for concurrent updates:

```swift
// Load current state with version
let currentVersion = try await stateStore.getSequenceNumber(for: actorId)

// Update with version check
try await stateStore.saveIfVersion(
    newState,
    for: actorId,
    expectedVersion: currentVersion
)
// Throws ActorStateError.versionConflict if version doesn't match
```

### Atomic Updates

Use the update method for atomic transformations:

```swift
try await stateStore.update(for: actorId, as: State.self) { state in
    state.count += 1
    return state
}
```

## Examples

See the `Examples/SurrealDB/` directory for complete examples:

- **TodoListActor.swift** - Simple CRUD operations with type-safe queries
- **GameRoomActor.swift** - Graph relationships with edge tables
- **README.md** - Detailed usage instructions and patterns

## Testing

Run tests with a local SurrealDB instance:

```bash
# Start SurrealDB
docker-compose -f docker-compose.surrealdb.yml up -d

# Run tests
swift test --filter TrebuchetSurrealDBTests

# Cleanup
docker-compose -f docker-compose.surrealdb.yml down -v
```

## Key Advantages

- **Type Safety**: Swift types define schema, no string-based queries
- **Auto-Schema**: SchemaGenerator creates tables from models
- **Relationships**: Native graph support for complex data models
- **Zero Boilerplate**: CRUD operations just work
- **Migration-Friendly**: Schema changes tracked in Swift code
- **Full ORM**: All SurrealDB features available

## Architecture

```
TrebuchetSurrealDB/
├── TrebuchetSurrealDB.swift         # Module exports and documentation
├── SurrealDBStateStore.swift        # ActorStateStore implementation
├── Configuration.swift              # Configuration types
└── CloudGatewayExtensions.swift     # Gateway integration helpers

Examples/SurrealDB/
├── TodoListActor.swift              # Simple CRUD example
├── GameRoomActor.swift              # Graph relationships example
└── README.md                        # Detailed usage guide

Tests/TrebuchetSurrealDBTests/
├── TestHelpers.swift                # Test utilities
├── SurrealDBStateStoreTests.swift   # State store tests
└── IntegrationTests.swift           # ORM integration tests
```

## Performance Considerations

- **Connection Pooling**: Use `SurrealDBConnectionPool` for high-throughput scenarios
- **Batch Operations**: Group multiple operations in transactions
- **Indexes**: Define indexes on frequently queried fields
- **Caching**: Consider caching frequently accessed data in actor memory

## Comparison with Other Backends

| Feature | SurrealDB | DynamoDB | PostgreSQL |
|---------|-----------|----------|------------|
| Type-safe ORM | ✅ | ❌ | ✅ |
| Graph relationships | ✅ | ❌ | ✅ (via joins) |
| Schema auto-generation | ✅ | ❌ | ✅ |
| Multi-model (doc/graph/relational) | ✅ | ❌ | ❌ |
| Serverless | ✅ | ✅ | ❌ |
| Real-time subscriptions | ✅ | ✅ (streams) | ✅ (LISTEN/NOTIFY) |

## License

Same as Trebuchet main package.

## Contributing

See [CONTRIBUTING.md](../../CONTRIBUTING.md) in the main repository.
