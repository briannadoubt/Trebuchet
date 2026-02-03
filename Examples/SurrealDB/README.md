# SurrealDB Examples

This directory contains example distributed actors demonstrating direct SurrealDB ORM integration with Trebuchet.

## Prerequisites

1. **SurrealDB Server**: Install and run SurrealDB
   ```bash
   # Install SurrealDB
   brew install surrealdb/tap/surreal

   # Or download from https://surrealdb.com/install

   # Start the server
   surreal start --log trace --user root --pass root memory
   ```

2. **Swift Dependencies**: Ensure your `Package.swift` includes:
   ```swift
   dependencies: [
       .package(url: "https://github.com/your-org/Trebuchet.git", from: "0.2.0"),
       .package(url: "https://github.com/surrealdb/surrealdb.swift.git", from: "1.0.0"),
   ]
   ```

## Examples

### 1. TodoListActor.swift - Simple CRUD Example

A straightforward todo list demonstrating:
- Basic CRUD operations (Create, Read, Update, Delete)
- Type-safe queries using KeyPath syntax
- Schema auto-generation with `@ID` property wrapper
- Actor-scoped data isolation

**Key Features:**
- `addTodo(text:)` - Create new todos
- `getTodos()` - Query with filtering and sorting
- `toggleTodo(id:)` - Update operations
- `deleteTodo(id:)` - Delete operations
- `clearCompleted()` - Batch deletions
- `getStats()` - Aggregation queries

**Usage:**
```swift
import SurrealDB
import Trebuchet

// Setup database
let db = try await SurrealDB()
try await db.connect("ws://localhost:8000")
try await db.use(namespace: "todos", database: "todos")

// Create actor
let server = TrebuchetServer(transport: .webSocket(port: 8080))
let todoList = TodoListActor(
    actorSystem: server.actorSystem,
    database: db,
    actorId: "user-123"
)
await server.expose(todoList, as: "user-123-todos")

// Use the actor
let todo = try await todoList.addTodo(text: "Buy groceries")
let todos = try await todoList.getTodos()
try await todoList.toggleTodo(id: todo.id!)
```

**Model Structure:**
```swift
struct Todo {
    @ID var id: String?
    var text: String
    var completed: Bool
    let actorId: String
    let createdAt: Date
}
```

### 2. GameRoomActor.swift - Graph Relationships Example

A game room demonstrating:
- Graph database relationships using edge tables
- Many-to-many relationships with metadata
- Type-safe graph traversal
- Complex relationship queries

**Key Features:**
- `addPlayer(playerId:name:team:)` - Create nodes and relationships
- `getPlayers()` - Graph traversal queries
- `getPlayersByTeam(_:)` - Relationship filtering
- `setPlayerTeam(playerId:team:)` - Update edge metadata
- `addScore(playerId:points:)` - Update related nodes
- `removePlayer(playerId:)` - Delete relationships
- `getLeaderboard(limit:)` - Complex sorting and aggregation

**Usage:**
```swift
import SurrealDB
import Trebuchet

// Setup database
let db = try await SurrealDB()
try await db.connect("ws://localhost:8000")
try await db.use(namespace: "game", database: "game")

// Create actor
let server = TrebuchetServer(transport: .webSocket(port: 8080))
let room = GameRoomActor(
    actorSystem: server.actorSystem,
    database: db,
    roomId: "main-lobby",
    maxPlayers: 4
)
await server.expose(room, as: "main-lobby")

// Use the actor
let player = try await room.addPlayer(
    playerId: "player-123",
    name: "Alice",
    team: .red
)
let players = try await room.getPlayers()
try await room.addScore(playerId: "player-123", points: 10)
let leaderboard = try await room.getLeaderboard(limit: 3)
```

**Model Structure:**
```swift
// Nodes
struct GameRoom {
    @ID var id: String?
    var name: String
    let maxPlayers: Int
    let createdAt: Date
}

struct Player {
    @ID var id: String?
    var name: String
    var score: Int
    let joinedAt: Date
}

// Edge
struct PlayerInRoom {
    @ID var id: String?
    let from: String  // player:xxx
    let to: String    // game_room:xxx
    var team: Team?
    let joinedAt: Date
}
```

## Key Concepts

### Schema Auto-Generation

Both examples use `db.defineTable(for: Model.self)` to automatically generate SurrealDB schemas:

```swift
try await db.defineTable(for: Todo.self)
try await db.defineTable(for: GameRoom.self)
try await db.defineTable(for: Player.self)
try await db.defineTable(for: PlayerInRoom.self)
```

This creates:
- Tables with appropriate names
- Field definitions based on Swift types
- Indexes for common query patterns

### Type-Safe Queries

Use KeyPath syntax for type-safe queries:

```swift
// Filter by property
let todos = try await db.query(Todo.self)
    .where(\.actorId, equals: "user-123")
    .where(\.completed, equals: false)
    .fetch()

// Sort by property
let sorted = try await db.query(Todo.self)
    .orderBy(\.createdAt, ascending: false)
    .fetch()

// Combine filters and sorting
let filtered = try await db.query(Player.self)
    .where(\.score, greaterThan: 100)
    .orderBy(\.score, ascending: false)
    .limit(10)
    .fetch()
```

### @ID Property Wrapper

The `@ID` property wrapper handles SurrealDB record IDs:

```swift
struct Todo {
    @ID var id: String?  // Auto-generated on create
    var text: String
}

let todo = Todo(text: "Example")
let created = try await db.create(todo)
print(created.id!)  // "todo:abc123xyz"
```

### Graph Relationships

Create relationships using edge tables:

```swift
// Create edge from player to room
let edge = PlayerInRoom(
    from: "player:alice",
    to: "game_room:lobby",
    team: .red,
    joinedAt: Date()
)
try await db.create(edge)

// Query relationships
let edges = try await db.query(PlayerInRoom.self)
    .where(\.to, equals: "game_room:lobby")
    .fetch()

// Load related nodes
for edge in edges {
    let player = try await db.select(Player.self, id: edge.from)
}
```

### Actor Isolation

Each actor maintains its own isolated data using actor IDs:

```swift
// TodoListActor uses actorId for isolation
let myTodos = try await db.query(Todo.self)
    .where(\.actorId, equals: actorId)
    .fetch()

// GameRoomActor uses roomId for isolation
let roomPlayers = try await db.query(PlayerInRoom.self)
    .where(\.to, equals: "game_room:\(roomId)")
    .fetch()
```

## Running the Examples

### Local Development

```swift
// 1. Start SurrealDB
// surreal start --user root --pass root memory

// 2. Create a server
let db = try await SurrealDB()
try await db.connect("ws://localhost:8000")
try await db.use(namespace: "example", database: "example")

let server = TrebuchetServer(transport: .webSocket(port: 8080))

// 3. Create and expose actors
let todos = TodoListActor(
    actorSystem: server.actorSystem,
    database: db,
    actorId: "user-1"
)
await server.expose(todos, as: "user-1-todos")

let room = GameRoomActor(
    actorSystem: server.actorSystem,
    database: db,
    roomId: "lobby"
)
await server.expose(room, as: "lobby")

// 4. Run the server
try await server.run()
```

### Client Usage

```swift
// Connect to the server
let client = TrebuchetClient(transport: .webSocket(
    host: "localhost",
    port: 8080
))
try await client.connect()

// Resolve and use actors
let todos = try client.resolve(TodoListActor.self, id: "user-1-todos")
let todo = try await todos.addTodo(text: "Learn Trebuchet")

let room = try client.resolve(GameRoomActor.self, id: "lobby")
try await room.addPlayer(playerId: "alice", name: "Alice", team: .red)
```

## Best Practices

1. **Schema Generation**: Always call `defineTable` in actor `init` to ensure schemas exist
2. **Actor Isolation**: Use actor IDs or room IDs to scope data to specific actor instances
3. **Error Handling**: Create custom error types for domain-specific failures
4. **Type Safety**: Leverage KeyPath syntax for compile-time query validation
5. **Relationships**: Use edge tables for many-to-many relationships with metadata
6. **Indexes**: Define indexes on frequently queried fields for performance

## Further Reading

- [SurrealDB Documentation](https://surrealdb.com/docs)
- [Trebuchet Documentation](../../README.md)
- [TrebuchetSurrealDB Integration](../../Sources/TrebuchetSurrealDB/README.md)
