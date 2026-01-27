# Advanced Streaming Features

Stream resumption, filtering, delta encoding, and cloud integration for production deployments.

## Overview

Trebuche provides advanced streaming capabilities for production use cases including graceful reconnection, bandwidth optimization, persistent state, and cloud deployment support.

## Stream Resumption & Reconnection

> **Implementation Status**: ✅ Fully Implemented
>
> Complete stream resumption with buffered data replay for both local (TrebuchetServer)
> and cloud (WebSocketLambdaHandler) deployments.

Gracefully handles connection loss with automatic stream resumption, ensuring clients don't miss updates during brief disconnections.

### How It Works

1. **Normal Operation**:
   - Server buffers recent stream data (100 items default, 5-minute TTL)
   - Client receives StreamData with sequence numbers
   - Client tracks last sequence in checkpoint

2. **On Disconnection**:
   - Client saves checkpoint (streamID, lastSequence, actorID, method)
   - Server maintains buffer for reconnection window
   - Stream continuations are cleaned up

3. **On Reconnection**:
   - Client sends StreamResumeEnvelope with checkpoint info
   - Server checks if buffered data exists:
     - **Buffer available**: Replays missed updates from buffer
     - **Buffer expired**: Sends StreamStart and current state

### Configuration

```swift
// Server-side: Configure buffer size and TTL
let server = TrebuchetServer(/* ... */)
// Default: maxBufferSize: 100, ttl: 300 seconds

// For AWS Lambda
let handler = WebSocketLambdaHandler(/* ... */)
// Default: maxBufferSize: 100, ttl: 300 seconds
```

### Example Flow

```
Client loses connection at sequence 42
Client reconnects 30 seconds later

Client → Server: StreamResumeEnvelope {
    streamID: xyz-789
    lastSequence: 42
    actorID: "todos"
    targetIdentifier: "observeState"
}

Server checks buffer:
- Has sequences: 43, 44, 45, 46

Server → Client: StreamDataEnvelope (seq: 43)
Server → Client: StreamDataEnvelope (seq: 44)
Server → Client: StreamDataEnvelope (seq: 45)
Server → Client: StreamDataEnvelope (seq: 46)

Client now caught up!
```

### AWS Lambda Considerations

For serverless deployments, buffer replay works when the same Lambda container handles reconnection (common due to warm containers). If a different container handles the request, the stream restarts from current state. This is a correct fallback behavior with no data loss.

## Filtered Streams

> **Implementation Status**: ✅ Fully Implemented
>
> Server-side filtering with stateful tracking for "changed" filter and heuristic matching for "nonEmpty" and "threshold" filters.

Server-side filtering reduces bandwidth and client-side processing by only sending relevant updates.

### Filter Types

1. **All** (default): No filtering, pass through all updates
2. **Predefined**: Use named filters with parameters
3. **Custom**: Client-defined filter logic (extensible via Filterable protocol)

### Implemented Predefined Filters

#### Changed Filter
Only sends updates when the value actually changes from the previous value.

```swift
// Client subscribes with changed filter
let filter = StreamFilter.predefined("changed")
let stream = await todoList.observeState(filter: filter)
// Only receives updates when state changes (bytewise comparison)
```

**Implementation**: Tracks previous data values per stream and compares bytewise.

#### NonEmpty Filter
Only sends updates for non-empty collections, strings, or dictionaries.

```swift
// Only receive updates when list has items
let filter = StreamFilter.predefined("nonEmpty")
let stream = await todoList.observeState(filter: filter)
```

**Implementation**: Decodes JSON and checks:
- Arrays: `!isEmpty`
- Dictionaries: `!isEmpty`
- Strings: `!isEmpty`
- Other types: Always pass through

#### Threshold Filter
Only sends updates when numeric values cross a threshold.

```swift
// Only receive when count exceeds 100
let filter = StreamFilter.predefined("threshold", parameters: [
    "value": "100",
    "comparison": "gt",  // gt, gte, lt, lte, eq, neq
    "field": "count"     // optional: for nested values
])
let stream = await counter.observeState(filter: filter)
```

**Implementation**: Decodes JSON and extracts numeric values for comparison.

**Supported comparisons**:
- `gt` or `>`: Greater than
- `gte` or `>=`: Greater than or equal
- `lt` or `<`: Less than
- `lte` or `<=`: Less than or equal
- `eq` or `==`: Equal
- `neq` or `!=`: Not equal

### Benefits

- **Reduced network traffic**: Skip redundant or irrelevant updates
- **Lower client-side processing**: Clients only handle meaningful changes
- **Battery savings**: Fewer wake-ups on mobile devices
- **Better scalability**: Less data to broadcast to concurrent clients

### Advanced: Custom Filters with Filterable Protocol

For type-specific filtering logic, implement the `Filterable` protocol:

```swift
extension TodoList.State: Filterable {
    func matches(filter: StreamFilter) -> Bool {
        switch filter.name {
        case "hasUrgent":
            return todos.contains { $0.priority == .urgent }
        case "completedOnly":
            return todos.allSatisfy { $0.completed }
        default:
            return true
        }
    }
}
```

**Note**: The `Filterable` protocol provides a hook for future server-side filtering where the server can deserialize state and call type-specific matching logic.

## Delta Encoding

Sends only changed fields to optimize bandwidth for large state objects.

### How It Works

1. **Server Side**:
   - DeltaStreamManager tracks last sent value
   - Computes delta from previous to current
   - Sends delta if available, otherwise full state

2. **Client Side**:
   - DeltaStreamApplier maintains current value
   - Applies deltas incrementally
   - Falls back to full state when needed

### Implementation

```swift
// Make state support delta encoding
extension TodoList.State: DeltaCodable {
    func delta(from previous: TodoList.State) -> TodoList.State? {
        // Only include changed todos
        let changedTodos = todos.filter { todo in
            !previous.todos.contains(todo)
        }

        guard !changedTodos.isEmpty || pendingCount != previous.pendingCount else {
            return nil // No changes
        }

        return State(todos: changedTodos, pendingCount: pendingCount)
    }

    func applying(delta: TodoList.State) -> TodoList.State {
        var updated = self
        // Merge changed todos
        for todo in delta.todos {
            if let index = updated.todos.firstIndex(where: { $0.id == todo.id }) {
                updated.todos[index] = todo
            } else {
                updated.todos.append(todo)
            }
        }
        updated.pendingCount = delta.pendingCount
        return updated
    }
}

// Server uses delta manager
let manager = DeltaStreamManager<TodoList.State>()
let delta = try await manager.encode(newState)
// Automatically sends delta when possible

// Client applies deltas
let applier = DeltaStreamApplier<TodoList.State>()
let currentState = try await applier.apply(delta)
```

### When to Use Delta Encoding

- Large state objects (> 10KB)
- Frequent small updates to large collections
- Mobile or bandwidth-constrained clients
- High-frequency updates

### Trade-offs

- Added complexity in delta computation
- Requires careful implementation of merge logic
- Must handle edge cases (concurrent updates, conflicts)

## Persistent State with Streaming

Seamlessly integrate persistent state with realtime streaming for serverless deployments.

### StatefulStreamingActor

Combines persistent state storage with automatic streaming updates:

```swift
import Trebuche
import TrebucheCloud

@Trebuchet
public distributed actor TodoList: StatefulStreamingActor {
    public typealias PersistentState = State

    private let stateStore: ActorStateStore

    @StreamedState public var state = State()

    public var persistentState: State {
        get { state }
        set { state = newValue }
    }

    public init(
        actorSystem: TrebuchetActorSystem,
        stateStore: ActorStateStore
    ) async throws {
        self.actorSystem = actorSystem
        self.stateStore = stateStore
        try await loadState(from: stateStore)
    }

    public func loadState(from store: any ActorStateStore) async throws {
        if let loaded = try await store.load(for: id.id, as: State.self) {
            state = loaded  // Triggers stream update to all clients
        }
    }

    public func saveState(to store: any ActorStateStore) async throws {
        try await store.save(state, for: id.id)
    }

    public distributed func addTodo(title: String) async throws -> TodoItem {
        let todo = TodoItem(title: title)
        var newState = state
        newState.todos.append(todo)
        state = newState  // 1. Streams to all clients

        try await saveState(to: stateStore)  // 2. Persists to storage

        return todo
    }
}
```

### Helper Methods

The `StatefulStreamingActor` protocol provides convenience methods to reduce boilerplate:

#### Single Field Updates

```swift
try await updateState(\.count, to: state.count + 1, store: stateStore)
```

#### Complex Transformations

```swift
public distributed func completeTodo(_ id: UUID) async throws {
    try await transformState(store: stateStore) { currentState in
        var newState = currentState
        if let index = newState.todos.firstIndex(where: { $0.id == id }) {
            newState.todos[index].completed = true
        }
        newState.lastUpdated = Date()
        return newState
    }
    // Automatically streams AND persists
}
```

#### Async Transformations

```swift
public distributed func addTodoWithValidation(_ title: String) async throws {
    try await transformStateAsync(store: stateStore) { currentState in
        let isValid = try await validateTitle(title)
        guard isValid else {
            throw ValidationError.invalidTitle
        }

        var newState = currentState
        newState.todos.append(TodoItem(title: title))
        return newState
    }
}
```

### State Lifecycle

When state changes:
1. **@StreamedState** triggers streaming to all connected clients
2. **saveState()** persists to storage (DynamoDB, PostgreSQL, etc.)
3. **Multi-instance sync** ensures consistency across serverless deployments

### Benefits

- State survives Lambda cold starts
- Automatic synchronization across instances
- Simple mental model: one change, two effects
- Helper methods reduce boilerplate
- Flexible control over persistence strategy

## Database Change Stream Integration

Synchronize actor state across multiple instances using database change streams.

### Supported Databases

- **DynamoDB Streams** - For AWS Lambda deployments
- **PostgreSQL LISTEN/NOTIFY** - For PostgreSQL-backed actors
- **MongoDB Change Streams** - For MongoDB deployments (planned)
- **Redis Pub/Sub** - For Redis-backed state (planned)

### DynamoDB Streams

Automatically sync actor state changes across Lambda instances:

```swift
public actor DynamoDBStreamAdapter {
    private let stream: DynamoDBStreamsClient
    private let actorRegistry: ActorRegistry

    public func start() async throws {
        for try await event in stream.events() {
            guard let actorID = event.keys["actorID"] else { continue }

            // Get the actor instance
            guard let actor = await actorRegistry.get(id: actorID) else {
                continue
            }

            // Reload state from DynamoDB
            if let statefulActor = actor as? any StatefulActor {
                try await statefulActor.loadState(from: stateStore)
                // State reload triggers stream updates to clients!
            }
        }
    }
}
```

### PostgreSQL LISTEN/NOTIFY

> **Implementation Status**: ✅ Fully Implemented
>
> Complete PostgreSQL integration with state storage and LISTEN/NOTIFY for multi-instance
> synchronization using PostgresNIO.

Implementation includes:
- ✅ PostgreSQLStateStore for actor state persistence
- ✅ PostgreSQLStreamAdapter for LISTEN/NOTIFY pub/sub
- ✅ Automatic sequence number tracking
- ✅ Connection pooling with NIO EventLoopGroup
- ✅ Database schema and triggers

#### Usage

The TrebuchePostgreSQL module provides production-ready PostgreSQL integration:

```swift
import TrebuchePostgreSQL

// State Store for actor persistence
let stateStore = try await PostgreSQLStateStore(
    host: "localhost",
    database: "trebuche",
    username: "postgres",
    password: "password"
)

// Use with StatefulStreamingActor
@Trebuchet
distributed actor GameRoom: StatefulStreamingActor {
    typealias PersistentState = State

    @StreamedState var state = State()
    let stateStore: ActorStateStore

    var persistentState: State {
        get { state }
        set { state = newValue }
    }

    distributed func updateScore(_ playerId: String, points: Int) async throws {
        try await transformState(store: stateStore) { currentState in
            var newState = currentState
            newState.scores[playerId, default: 0] += points
            return newState
        }
        // Automatically persists to PostgreSQL AND streams to all clients!
    }
}

// Stream Adapter for multi-instance synchronization
let adapter = try await PostgreSQLStreamAdapter(
    host: "localhost",
    database: "trebuche",
    username: "postgres"
)

let notificationStream = try await adapter.start()

// Process state change notifications
for await change in notificationStream {
    print("Actor \(change.actorID) updated to sequence \(change.sequenceNumber)")
    // Reload actor state from PostgreSQL
    try await reloadActor(id: change.actorID)
}
```

#### Database Setup

Create the required schema and triggers in your PostgreSQL database:

```sql
-- Create actor_states table
CREATE TABLE actor_states (
    actor_id VARCHAR(255) PRIMARY KEY,
    state BYTEA NOT NULL,
    sequence_number BIGINT NOT NULL DEFAULT 0,
    updated_at TIMESTAMP NOT NULL DEFAULT NOW(),
    created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_actor_states_updated ON actor_states(updated_at);
CREATE INDEX idx_actor_states_sequence ON actor_states(sequence_number);

-- Create notification function
CREATE OR REPLACE FUNCTION notify_actor_state_change()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM pg_notify('actor_state_changes',
        json_build_object(
            'actorID', NEW.actor_id,
            'sequenceNumber', NEW.sequence_number,
            'timestamp', EXTRACT(EPOCH FROM NEW.updated_at)
        )::text
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create trigger
CREATE TRIGGER actor_state_change_trigger
AFTER INSERT OR UPDATE ON actor_states
FOR EACH ROW
EXECUTE FUNCTION notify_actor_state_change();
```

See `Sources/TrebuchePostgreSQL/` for complete implementation.

### Use Cases

- **Multi-Region Deployment**: Actors in different regions stay synchronized
- **Admin Tools**: Admin dashboard modifies database, all clients see updates
- **Batch Processing**: Background jobs update state, streaming clients notified
- **Legacy Integration**: Existing systems write to database, new actors stream changes

## See Also

- <doc:Streaming> - Core streaming concepts and basics
- <doc:DeployingToAWS> - AWS deployment guide
- <doc:AWSConfiguration> - AWS configuration reference
- <doc:CloudDeployment/AWSCosts> - AWS cost analysis and optimization
