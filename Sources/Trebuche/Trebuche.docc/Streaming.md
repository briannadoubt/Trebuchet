# Realtime State Streaming

Stream state changes from distributed actors to clients in realtime with automatic synchronization.

## Overview

Trebuche's streaming feature allows distributed actors to expose reactive state that automatically updates all connected clients in realtime. This eliminates manual polling and provides a seamless, reactive experience.

## Quick Start

### Defining a Streaming Actor

Use the `@StreamedState` macro to make a property automatically notify subscribers:

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

public struct State: Codable, Sendable {
    var todos: [TodoItem] = []
}
```

### SwiftUI Integration

Use `@ObservedActor` to automatically subscribe to state streams:

```swift
struct TodoListView: View {
    @ObservedActor("todos", observe: \TodoList.observeState)
    var state

    var body: some View {
        if let currentState = state {
            List(currentState.todos) { todo in
                Text(todo.title)
            }
        } else if $state.isConnecting {
            ProgressView("Connecting...")
        }
    }
}
```

## How It Works

### @StreamedState Macro

The `@StreamedState` macro transforms a property into a streaming state property with automatic change tracking. It generates:

- Backing storage (`_state_storage`)
- Continuation array for subscribers (`_state_continuations`)
- Computed property with getter/setter
- Change notification method
- Observe method (`observeState()`)
- Stream accessor for server-side iteration

**Example expansion:**

```swift
// From:
@StreamedState var state: State = State()

// To:
private var _state_storage: State = State()
private var _state_continuations: [AsyncStream<State>.Continuation] = []

var state: State {
    get { _state_storage }
    set {
        _state_storage = newValue
        _notifyStateChange()
    }
}

private func _notifyStateChange() {
    for continuation in _state_continuations {
        continuation.yield(_state_storage)
    }
}

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
```

### @ObservedActor Property Wrapper

The `@ObservedActor` property wrapper provides:

- Automatic subscription on connection
- State updates trigger view re-renders
- Access to the actor via `$state.actor`
- Connection status via `$state.isConnecting`, `$state.error`

## Wire Protocol

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
```

## Architecture

### Server Side

1. **TrebuchetServer** - Detects `observe*` methods and initiates streaming
2. **TrebuchetActorSystem** - `executeStreamingTarget()` gets the stream from the actor
3. **StreamingActor Protocol** - Actors implement `_getStream(for:)` to provide encoded streams
4. **Generated Code** - `@Trebuchet` macro generates the streaming infrastructure

### Client Side

1. **TrebuchetClient** - Routes stream envelopes to the actor system
2. **StreamRegistry** - Manages active stream subscriptions
3. **@ObservedActor** - SwiftUI integration for automatic view updates

### Sequence Number Deduplication

The `StreamRegistry` tracks the last received sequence number for each stream and filters out:
- Duplicate messages (same sequence number)
- Out-of-order messages (lower sequence number than last received)

This ensures clients receive state updates exactly once, in order.

## Advanced Usage

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

### Manual Stream Subscription

```swift
let client = TrebuchetClient(transport: .webSocket(host: "localhost", port: 8080))
try await client.connect()

let todoList = try client.resolve(TodoList.self, id: "todos")
let stream = await todoList.observeState()

for await state in stream {
    print("Todos: \(state.todos.count)")
}
```

### SwiftUI with Multiple Streams

```swift
struct GameView: View {
    @ObservedActor("game", observe: \GameServer.observeGameState)
    var gameState

    @ObservedActor("game", observe: \GameServer.observeMetrics)
    var metrics

    var body: some View {
        if let state = gameState, let metrics = metrics {
            VStack {
                Text("Score: \(state.score)")
                Text("Players: \(metrics.playerCount)")

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

## Performance Considerations

### Bandwidth

- Only changed state is sent (entire state object per update)
- Sequence numbers add minimal overhead (8 bytes per message)
- See <doc:AdvancedStreaming> for delta encoding to optimize large state objects

### Memory

- Each subscriber holds a continuation in the actor's array
- Continuations are weak-referenced and cleaned up on termination
- Stream registry holds active streams until explicitly removed

### Concurrency

- All stream operations are actor-isolated
- No manual locking needed
- SwiftUI updates happen on MainActor

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

## See Also

- <doc:AdvancedStreaming> - Stream resumption, filtering, and delta encoding
- <doc:SwiftUIIntegration> - Complete SwiftUI integration guide
- <doc:DefiningActors> - Actor definition patterns
