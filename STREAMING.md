# Realtime State Streaming in Trebuche

This document describes the realtime state streaming feature that enables distributed actors to push state updates to clients automatically.

## Overview

Trebuche's streaming feature allows distributed actors to expose reactive state that automatically updates all connected clients in realtime. This eliminates manual polling and provides a seamless, reactive experience.

## Key Concepts

### 1. @StreamedState Macro

The `@StreamedState` macro transforms a property into a streaming state property with automatic change tracking:

```swift
@Trebuchet
public distributed actor TodoList {
    @StreamedState public var state: State = State()

    public distributed func addTodo(title: String) -> TodoItem {
        let todo = TodoItem(title: title)
        state.todos.append(todo)  // Automatically notifies all subscribers
        return todo
    }
}
```

**What it generates:**
- Backing storage (`_state_storage`)
- Continuation array for subscribers (`_state_continuations`)
- Computed property with getter/setter
- Change notification method
- Observe method (`observeState()`)
- Stream accessor for server-side iteration

### 2. @ObservedActor Property Wrapper

The `@ObservedActor` property wrapper automatically subscribes to state streams and updates SwiftUI views:

```swift
struct TodoListView: View {
    @ObservedActor("todos", observe: \TodoList.observeState)
    var state

    var body: some View {
        if let currentState = state {
            List(currentState.todos) { todo in
                Text(todo.title)
            }
        }
    }
}
```

**Features:**
- Automatic subscription on connection
- State updates trigger view re-renders
- Access actor via `$state.actor`
- Connection status via `$state.isConnecting`, `$state.error`

## Architecture

### Wire Protocol

Streaming uses a multi-envelope protocol:

1. **StreamStartEnvelope** - Sent when stream is initiated
   - `streamID`: Unique identifier for this stream
   - `callID`: Correlates with the original invocation
   - `actorID`: The actor being observed
   - `targetIdentifier`: The observe method name

2. **StreamDataEnvelope** - Sent for each state update
   - `streamID`: Stream identifier
   - `sequenceNumber`: Monotonic counter for deduplication
   - `data`: Encoded state value
   - `timestamp`: When the update was generated

3. **StreamEndEnvelope** - Sent when stream completes
   - `streamID`: Stream identifier
   - `reason`: Why the stream ended (completed, error, etc.)

4. **StreamErrorEnvelope** - Sent on error
   - `streamID`: Stream identifier
   - `errorMessage`: Error description

All envelopes are wrapped in `TrebuchetEnvelope`, a discriminated union that also includes regular RPC envelopes.

### Flow Diagram

```
Client                          Server
  │                               │
  ├─ InvocationEnvelope ────────>│  (call observeState())
  │  callID: abc-123              │
  │  target: "observeState"       │
  │                               │
  │<─ StreamStartEnvelope ────────┤  (stream initiated)
  │  streamID: xyz-789            │
  │  callID: abc-123              │
  │                               │
  │<─ StreamDataEnvelope ─────────┤  (initial state)
  │  streamID: xyz-789            │
  │  sequenceNumber: 1            │
  │                               │
  │     [state changes on server] │
  │                               │
  │<─ StreamDataEnvelope ─────────┤  (updated state)
  │  streamID: xyz-789            │
  │  sequenceNumber: 2            │
  │                               │
  │<─ StreamDataEnvelope ─────────┤  (another update)
  │  streamID: xyz-789            │
  │  sequenceNumber: 3            │
```

### Components

#### Server Side

1. **TrebuchetServer** - Detects `observe*` methods and initiates streaming
2. **TrebuchetActorSystem** - `executeStreamingTarget()` gets the stream from the actor
3. **StreamingActor Protocol** - Actors implement `_getStream(for:)` to provide encoded streams
4. **Generated Code** - `@Trebuchet` macro generates the streaming infrastructure

#### Client Side

1. **TrebuchetClient** - Routes stream envelopes to the actor system
2. **StreamRegistry** - Manages active stream subscriptions
3. **@ObservedActor** - SwiftUI integration for automatic view updates

### Sequence Number Deduplication

The `StreamRegistry` tracks the last received sequence number for each stream and filters out:
- Duplicate messages (same sequence number)
- Out-of-order messages (lower sequence number than last received)

This ensures clients receive state updates exactly once, in order.

## Usage Examples

### Basic Streaming Actor

```swift
@Trebuchet
public distributed actor Counter {
    public struct State: Codable, Sendable {
        public var count: Int
    }

    @StreamedState public var state: State = State(count: 0)

    public distributed func increment() {
        state.count += 1  // All subscribers receive update
    }
}
```

### Multiple Streamed Properties

```swift
@Trebuchet
public distributed actor GameServer {
    @StreamedState public var gameState: GameState = GameState()
    @StreamedState public var metrics: Metrics = Metrics()

    // Macro generates:
    // - observeGameState() -> AsyncStream<GameState>
    // - observeMetrics() -> AsyncStream<Metrics>
}
```

### SwiftUI View with Streaming

```swift
struct GameView: View {
    @ObservedActor("game", observe: \GameServer.observeGameState)
    var gameState

    var body: some View {
        if let state = gameState {
            VStack {
                Text("Score: \(state.score)")
                Text("Level: \(state.level)")

                Button("Next Level") {
                    Task {
                        try? await $gameState.actor?.advanceLevel()
                    }
                }
            }
        } else if $gameState.isConnecting {
            ProgressView("Connecting...")
        }
    }
}
```

### Manual Stream Subscription (Advanced)

```swift
let client = TrebuchetClient(transport: .webSocket(host: "localhost", port: 8080))
try await client.connect()

let todoList = try client.resolve(TodoList.self, id: "todos")
let stream = await todoList.observeState()

for await state in stream {
    print("Todos: \(state.todos.count)")
}
```

## Implementation Details

### Macro Expansion

Given this code:

```swift
@Trebuchet
distributed actor TodoList {
    @StreamedState var state: State = State()
}
```

The macros expand to approximately:

```swift
distributed actor TodoList {
    public typealias ActorSystem = TrebuchetActorSystem

    // Storage (from @StreamedState)
    private var _state_storage: State = State()
    private var _state_continuations: [AsyncStream<State>.Continuation] = []

    // Computed property (from @StreamedState)
    var state: State {
        get { _state_storage }
        set {
            _state_storage = newValue
            _notifyStateChange()
        }
    }

    // Notification method (from @StreamedState)
    private func _notifyStateChange() {
        for continuation in _state_continuations {
            continuation.yield(_state_storage)
        }
    }

    // Observe method (from @Trebuchet)
    public func observeState() -> AsyncStream<State> {
        AsyncStream { continuation in
            _state_continuations.append(continuation)
            continuation.yield(_state_storage)  // Send initial state

            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?._removeStateContinuation(continuation)
                }
            }
        }
    }

    // Continuation removal (from @Trebuchet)
    private func _removeStateContinuation(_ continuation: AsyncStream<State>.Continuation) {
        _state_continuations.removeAll { $0 === continuation }
    }

    // Stream accessor for server (from @Trebuchet)
    public func _getStream(for propertyName: String) async -> AsyncStream<Data>? {
        switch propertyName {
        case "state":
            let stream = await observeState()
            return AsyncStream { continuation in
                Task {
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    for await value in stream {
                        if let data = try? encoder.encode(value) {
                            continuation.yield(data)
                        }
                    }
                    continuation.finish()
                }
            }
        default:
            return nil
        }
    }
}
```

### Server Stream Handling

When a client calls `observeState()`:

1. **Detection**: `TrebuchetServer.handleMessage()` sees the method name starts with "observe"
2. **Initiation**: Calls `handleStreamingInvocation()` instead of normal RPC
3. **Start**: Sends `StreamStartEnvelope` to client
4. **Execution**: Calls `actorSystem.executeStreamingTarget()` to get the data stream
5. **Iteration**: Loops over the stream, sending `StreamDataEnvelope` for each value
6. **Completion**: Sends `StreamEndEnvelope` when stream finishes

### Client Stream Handling

When receiving stream envelopes:

1. **Registration**: `StreamRegistry.createRemoteStream()` creates an `AsyncStream<Data>`
2. **Start**: `handleStreamStart()` acknowledges the stream
3. **Data**: `handleStreamData()` yields data to the stream (with deduplication)
4. **Completion**: `handleStreamEnd()` finishes the stream

## Testing

The streaming implementation includes comprehensive tests in `StreamingTests.swift`:

- ✅ Envelope encoding/decoding
- ✅ Sequence number preservation
- ✅ Stream registry lifecycle
- ✅ Data delivery
- ✅ Duplicate filtering

Run tests:
```bash
swift test --filter StreamingTests
```

## Performance Considerations

### Bandwidth

- Only changed state is sent (entire state object per update)
- Consider delta encoding for large state objects (future enhancement)
- Sequence numbers add minimal overhead (8 bytes per message)

### Memory

- Each subscriber holds a continuation in the actor's array
- Continuations are weak-referenced and cleaned up on termination
- Stream registry holds active streams until explicitly removed

### Concurrency

- All stream operations are actor-isolated
- No manual locking needed
- SwiftUI updates happen on MainActor

## Future Enhancements

### Phase 7: Stream Resumption
- Reconnection with last sequence number
- Replay missed updates from buffer
- Seamless reconnection experience

### Phase 8: Filtered Streams
- Server-side filtering to reduce bandwidth
- Client specifies filter predicates
- Only matching updates sent

### Phase 9: Delta Encoding
- Send only changed fields
- Significant bandwidth savings for large state
- Backwards compatible

### Phase 10-12: Cloud Deployment
- AWS Lambda + API Gateway WebSocket support
- DynamoDB persistence integration
- Multi-region distribution

## Troubleshooting

### Streams Not Updating

**Problem**: Views don't update when state changes

**Solutions**:
- Ensure property is marked with `@StreamedState`
- Verify mutations use property setter (not direct storage access)
- Check connection state in SwiftUI view

### Connection Issues

**Problem**: `$state.isConnecting` stays true

**Solutions**:
- Verify server is running and accessible
- Check WebSocket endpoint configuration
- Look for errors in `$state.error`

### Build Errors

**Problem**: "Cannot find 'observeState' in scope"

**Solutions**:
- Ensure `@Trebuchet` macro is applied to actor
- Verify `@StreamedState` is applied to property
- Clean build folder and rebuild

## Summary

Trebuche's streaming feature provides:

✅ **Zero boilerplate** - Just add `@StreamedState` to properties
✅ **Automatic updates** - State changes push to all clients instantly
✅ **Type-safe** - Full compiler enforcement
✅ **SwiftUI native** - `@ObservedActor` integrates seamlessly
✅ **Reliable** - Sequence numbers prevent duplicates/out-of-order
✅ **Tested** - Comprehensive test coverage

The implementation demonstrates how Swift's modern concurrency, macros, and distributed actors can create elegant, reactive distributed systems with minimal code.
