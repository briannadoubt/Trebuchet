# Advanced Streaming Features (Phases 7-12)

This document describes the advanced streaming features implemented in Phases 7-12.

## Phase 7: Stream Resumption & Reconnection ✅

**Status**: Implemented

Gracefully handles connection loss with automatic stream resumption.

### Components

- **StreamCheckpoint**: Tracks the last received sequence number for each stream
- **StreamCheckpointStorage**: Actor-based storage for checkpoints with expiration
- **StreamResumeEnvelope**: Wire protocol for requesting stream resumption
- **Buffer in StreamRegistry**: Keeps recent data for catch-up (default: 100 items)

### How It Works

1. **Normal Operation**:
   - Client receives StreamData with sequence numbers
   - StreamRegistry buffers recent data
   - Client tracks last sequence in checkpoint

2. **On Disconnection**:
   - Client saves checkpoint (streamID, lastSequence, actorID, method)
   - Stream continuations are cleaned up

3. **On Reconnection**:
   - Client sends StreamResumeEnvelope with checkpoint info
   - Server checks if buffered data exists:
     - **Buffer available**: Replays missed updates from buffer
     - **Buffer expired**: Sends StreamStart and current state

4. **Benefits**:
   - No data loss for brief disconnections
   - Seamless reconnection experience
   - Configurable buffer size and expiration

### Configuration

```swift
// Server-side: Configure buffer size
let registry = StreamRegistry(maxBufferSize: 200)

// Checkpoint storage with expiration
let storage = StreamCheckpointStorage(maxAge: 300) // 5 minutes
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

## Phase 8: Filtered Streams ✅

**Status**: Implemented

Server-side filtering to reduce bandwidth and client-side processing.

### Components

- **StreamFilter**: Codable filter specification
- **FilterType**: Discriminator (all, predefined, custom)
- **PredefinedFilters**: Common filters (changed, nonEmpty, threshold)

### Filter Types

1. **All** (default): No filtering, pass through all updates
2. **Predefined**: Use named filters with parameters
3. **Custom**: Not yet supported over wire (future)

### Usage

```swift
// Server defines filterable state
extension TodoList.State: Filterable {
    func matches(filter: StreamFilter) -> Bool {
        switch filter.name {
        case "nonEmpty":
            return !todos.isEmpty
        case "changed":
            // Would compare with previous value
            return true
        default:
            return true
        }
    }
}

// Client subscribes with filter
let filter = StreamFilter.predefined("nonEmpty")
let stream = await todoList.observeState(filter: filter)
// Only receives updates when todos list is non-empty
```

### Benefits

- Reduced network traffic
- Lower client-side processing
- Battery savings on mobile devices
- Easier to scale to many clients

### Common Filters

- **changed**: Only send when value actually changed
- **nonEmpty**: Only send for non-empty collections
- **threshold**: Only send when numeric value crosses threshold
- **rate-limit**: Limit update frequency

## Phase 9: Delta Encoding ✅

**Status**: Implemented

Only sends changed fields to optimize bandwidth for large state objects.

### Components

- **DeltaCodable**: Protocol for types supporting delta encoding
- **StateDelta**: Wrapper for full state or delta
- **DeltaStreamManager**: Server-side delta computation
- **DeltaStreamApplier**: Client-side delta application

### How It Works

1. **Server Side**:
   - DeltaStreamManager tracks last sent value
   - Computes delta from previous to current
   - Sends delta if available, otherwise full state

2. **Client Side**:
   - DeltaStreamApplier maintains current value
   - Applies deltas incrementally
   - Falls back to full state when needed

### Usage

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

### Benefits

- Significant bandwidth savings for large state
- Faster updates over slow connections
- Reduced JSON parsing overhead
- Ideal for incremental updates

### Trade-offs

- Added complexity in delta computation
- Requires careful implementation of delta logic
- Must handle edge cases (concurrent updates, etc.)

## Phase 10: AWS Lambda WebSocket Support

**Status**: Design complete, implementation pending

Enable streaming in AWS Lambda with WebSocket API Gateway.

### Architecture

```
Client (WebSocket)
    ↓
API Gateway WebSocket API
    ↓
Lambda (Connection Handler)
    → DynamoDB (Connection Table)
    → Lambda (Actor Handler)
        → DynamoDB (Actor State)
```

### Components

**New Files** (to be implemented):
- `TrebucheAWS/WebSocketAPIGateway.swift`
- `TrebucheAWS/LambdaStreamHandler.swift`
- `TrebucheAWS/ConnectionManager.swift`

### Configuration

```yaml
# trebuche.yaml
provider: aws
websocket:
  enabled: true
  stage: production
  routes:
    - $connect     # Handle new connections
    - $disconnect  # Handle disconnections
    - $default     # Handle all messages

connection_table: trebuche-connections
state_table: trebuche-actor-state
```

### Lambda Handler

```swift
@main
struct WebSocketLambdaHandler: SimpleLambdaHandler {
    let gateway: CloudGateway
    let connectionManager: ConnectionManager

    init(context: LambdaInitializationContext) async throws {
        let stateStore = DynamoDBStateStore(tableName: env("STATE_TABLE"))
        let connectionTable = env("CONNECTION_TABLE")

        gateway = CloudGateway(configuration: .init(
            stateStore: stateStore,
            registry: CloudMapRegistry(namespace: env("NAMESPACE"))
        ))

        connectionManager = ConnectionManager(
            tableName: connectionTable,
            gateway: gateway
        )

        // Register actors
        try await gateway.expose(TodoList(actorSystem: gateway.system), as: "todos")
    }

    func handle(
        _ event: APIGatewayV2WebSocketEvent,
        context: LambdaContext
    ) async throws -> APIGatewayV2Response {
        switch event.requestContext.routeKey {
        case "$connect":
            try await connectionManager.register(
                connectionID: event.requestContext.connectionId
            )
            return APIGatewayV2Response(statusCode: 200)

        case "$disconnect":
            try await connectionManager.unregister(
                connectionID: event.requestContext.connectionId
            )
            return APIGatewayV2Response(statusCode: 200)

        case "$default":
            guard let body = event.body else {
                return APIGatewayV2Response(statusCode: 400)
            }

            // Process message
            let response = await gateway.handleMessage(body)

            // Send response via API Gateway Management API
            try await connectionManager.send(
                data: response,
                to: event.requestContext.connectionId
            )

            return APIGatewayV2Response(statusCode: 200)

        default:
            return APIGatewayV2Response(statusCode: 404)
        }
    }
}
```

### Connection Management

Connections stored in DynamoDB:
```swift
struct Connection: Codable {
    let connectionID: String
    let connectedAt: Date
    var subscriptions: [StreamSubscription]  // Active streams
    var ttl: Int  // Auto-cleanup after disconnect
}
```

### Sending Updates

```swift
// From actor to client via WebSocket
public actor ConnectionManager {
    private let apiGatewayClient: APIGatewayManagementAPIClient
    private let dynamoDB: DynamoDBClient

    func send(data: Data, to connectionID: String) async throws {
        let input = PostToConnectionInput(
            connectionId: connectionID,
            data: data
        )
        try await apiGatewayClient.postToConnection(input: input)
    }

    func broadcast(data: Data, to subscriptions: [String]) async throws {
        // Get all connections with these subscriptions
        let connections = try await getConnections(with: subscriptions)

        await withTaskGroup(of: Void.self) { group in
            for connection in connections {
                group.addTask {
                    try? await self.send(data: data, to: connection.connectionID)
                }
            }
        }
    }
}
```

### Benefits

- Serverless streaming at Lambda scale
- Pay per request + connection time
- Auto-scaling built-in
- No server management

### Challenges

- Connection state in DynamoDB
- POST-to-connection API latency
- Connection limits (10k per API)
- Cold start considerations

## Phase 11: StatefulActor Protocol ✅

**Status**: Already implemented in TrebucheCloud

Automatic state persistence to external stores.

### Protocol

```swift
public protocol StatefulActor: DistributedActor
where ActorSystem == TrebuchetActorSystem {
    associatedtype PersistentState: Codable & Sendable

    func loadState(from store: any ActorStateStore) async throws
    func saveState(to store: any ActorStateStore) async throws

    var persistentState: PersistentState { get set }
}
```

### Usage with Streaming

```swift
@Trebuchet
public distributed actor TodoList: StatefulActor {
    public typealias PersistentState = State

    private let stateStore: ActorStateStore

    @StreamedState public var state = State()

    public var persistentState: State {
        get { state }
        set { state = newValue }
    }

    public init(actorSystem: ActorSystem, stateStore: ActorStateStore) async throws {
        self.actorSystem = actorSystem
        self.stateStore = stateStore

        // Load persisted state
        try await loadState(from: stateStore)
    }

    public func loadState(from store: any ActorStateStore) async throws {
        if let loaded = try await store.load(for: id.id, as: State.self) {
            state = loaded  // Triggers stream update!
        }
    }

    public func saveState(to store: any ActorStateStore) async throws {
        try await store.save(state, for: id.id)
    }

    // Mutations automatically stream AND persist
    public distributed func addTodo(title: String) async throws -> TodoItem {
        let todo = TodoItem(title: title)
        state.todos.append(todo)  // Streams to all clients

        try await saveState(to: stateStore)  // Persists to DynamoDB

        return todo
    }
}
```

### Benefits

- State survives Lambda cold starts
- Multiple Lambda instances stay in sync
- Simple persistence model
- Works with any ActorStateStore

## Phase 12: Database Change Stream Adapters

**Status**: Design complete, implementation pending

Integrate with database change streams for multi-instance sync.

### Supported Databases

1. **DynamoDB Streams**
2. **PostgreSQL LISTEN/NOTIFY**
3. **MongoDB Change Streams**
4. **Redis Pub/Sub**

### Architecture

```
Actor Instance 1 → DynamoDB → DynamoDB Stream
                        ↓
Actor Instance 2 ← Event Processor ← Lambda
                        ↓
Actor Instance 3   (detects changes)
```

### DynamoDB Streams Example

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

### PostgreSQL Example

```swift
public actor PostgreSQLAdapter {
    private let connection: PostgresConnection

    public func start() async throws {
        // Subscribe to notifications
        try await connection.execute("LISTEN actor_state_changes")

        for try await notification in connection.notifications {
            let payload = try JSONDecoder().decode(
                StateChangeNotification.self,
                from: notification.payload
            )

            // Notify actor to reload
            await handleStateChange(payload)
        }
    }
}

// PostgreSQL trigger
CREATE OR REPLACE FUNCTION notify_state_change()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM pg_notify('actor_state_changes',
        json_build_object(
            'actorID', NEW.actor_id,
            'timestamp', NEW.updated_at
        )::text
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER actor_state_trigger
AFTER INSERT OR UPDATE ON actor_states
FOR EACH ROW EXECUTE FUNCTION notify_state_change();
```

### Benefits

- Multi-instance synchronization
- External systems can modify state
- Database as source of truth
- Real-time consistency across instances

### Use Cases

1. **Multi-Region Deployment**: Actors in different regions stay in sync
2. **Admin Tools**: Admin dashboard modifies DB, all clients see update
3. **Batch Processing**: Background job updates state, streaming clients notified
4. **Legacy Integration**: Existing systems write to DB, new actors stream changes

## Summary

### Implemented ✅

- **Phase 7**: Stream Resumption & Reconnection
- **Phase 8**: Filtered Streams
- **Phase 9**: Delta Encoding
- **Phase 11**: StatefulActor Protocol

### Documented for Future ⏭️

- **Phase 10**: AWS Lambda WebSocket Support
- **Phase 12**: Database Change Stream Adapters

### Next Steps

1. Implement Phase 10 (Lambda WebSocket)
2. Implement Phase 12 (DB Change Streams)
3. Add comprehensive tests for all phases
4. Performance benchmarking
5. Production deployment guide

All advanced features build on the core streaming infrastructure and can be adopted incrementally based on requirements.
