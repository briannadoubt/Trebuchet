# ``Trebuche/TrebuchetClient``

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
