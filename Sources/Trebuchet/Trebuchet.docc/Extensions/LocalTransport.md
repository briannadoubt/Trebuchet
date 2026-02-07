# ``Trebuchet/LocalTransport``

An in-process transport implementation for local development and testing.

## Overview

`LocalTransport` provides a zero-overhead transport mechanism that routes messages directly within the same process without network overhead. It's ideal for:

- Unit testing distributed actors
- Local development workflows
- Single-process deployments
- Performance benchmarking (eliminates network latency)

## Usage

Most users should use ``TrebuchetLocal`` for a simpler API. `LocalTransport` is used internally and can be accessed via the shared singleton:

```swift
// Access the shared instance
let server = LocalTransport.shared.server

// Expose actors
let room = GameRoom(actorSystem: server.actorSystem)
await server.expose(room, as: "main-room")

// Use with client
let client = TrebuchetClient(transport: .local)
try await client.connect()
let resolved = try client.resolve(GameRoom.self, id: "main-room")
```

## Architecture

Unlike network-based transports, `LocalTransport` bypasses serialization and routes messages through in-memory channels:

1. `send(_:to:)` delivers messages directly to the server's message handler
2. `incoming` yields messages from an `AsyncStream`
3. `connect(to:)` and `listen(on:)` are no-ops (always ready)

## Performance

This transport has near-zero overhead:

- No serialization/deserialization
- No socket I/O
- No network stack traversal
- Direct in-memory routing

Use for benchmarking to measure pure actor system performance.

## Thread Safety

`LocalTransport` is an actor that provides thread-safe access to all mutable state. All message handling uses actor isolation and structured concurrency.

## Topics

### Singleton Instance

- ``shared``
- ``server``

### Transport Protocol

- ``incoming``
- ``connect(to:)``
- ``send(_:to:)``
- ``listen(on:)``
- ``shutdown()``

### See Also

- <doc:LocalTransport>
- ``TrebuchetLocal``
- ``TransportConfiguration/local``
