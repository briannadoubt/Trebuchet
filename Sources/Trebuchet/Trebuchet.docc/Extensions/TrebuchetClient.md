# ``Trebuchet/TrebuchetClient``

## Overview

`TrebuchetClient` connects to a remote server and provides access to distributed actors. Once connected, you can resolve actors by their name and call their methods as if they were local.

## Connecting to a Server

```swift
let client = TrebuchetClient(
    transport: .webSocket(host: "game.example.com", port: 8080)
)
try await client.connect()
```

## Resolving Remote Actors

Use ``resolve(_:id:)`` with the actor type and the name it was exposed as:

```swift
let room = try client.resolve(GameRoom.self, id: "main-room")
```

The returned actor proxy is fully type-safe. You call its methods normally:

```swift
let players = try await room.join(player: me)
```

## Stream Resumption

After a reconnection, you can resume streams from where they left off using ``resumeStream(_:)``:

```swift
// Assume you have a checkpoint saved from before disconnection
let resume = StreamResumeEnvelope(
    streamID: checkpoint.streamID,
    lastSequence: checkpoint.lastSequence,
    actorID: actorID,
    targetIdentifier: "observeState"
)

// Resume the stream
try await client.resumeStream(resume)
```

This allows the server to replay any buffered data the client missed during disconnection, ensuring no state updates are lost.

For SwiftUI apps, this is handled automatically by `@ObservedActor`. See <doc:AdvancedStreaming> for more details.

## Disconnecting

When you're done, disconnect cleanly:

```swift
await client.disconnect()
```

## Topics

### Creating a Client

- ``init(transport:)``

### Connection Management

- ``connect()``
- ``disconnect()``

### Resolving Actors

- ``resolve(_:id:)``
- ``actorSystem``

### Streaming

- ``resumeStream(_:)``
