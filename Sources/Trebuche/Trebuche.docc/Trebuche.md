# ``Trebuche``

Location-transparent distributed actors for Swift. Make RPC stupid simple.

@Metadata {
    @DisplayName("Trebuche")
}

## Overview

Trebuche is a Swift 6.2 location-transparent distributed actor framework that dramatically simplifies remote procedure calls. Define your actors once, and seamlessly use them whether they're local or remote.

```swift
@Trebuchet
distributed actor GameRoom {
    distributed func join(player: Player) -> RoomState
}
```

The ``Trebuchet()`` macro automatically sets up the actor system typealias, so you can focus on your business logic.

### Server Side

```swift
let server = TrebuchetServer(transport: .webSocket(port: 8080))
let room = GameRoom(actorSystem: server.actorSystem)
await server.expose(room, as: "main-room")
try await server.run()
```

### Client Side

```swift
let client = TrebuchetClient(transport: .webSocket(host: "localhost", port: 8080))
try await client.connect()
let room = try client.resolve(GameRoom.self, id: "main-room")
try await room.join(player: me)  // Looks local, works remotely!
```

## Topics

### Essentials

- <doc:GettingStarted>
- ``Trebuchet()``

### Server and Client

- ``TrebuchetServer``
- ``TrebuchetClient``

### Core Types

- ``TrebuchetActorSystem``
- ``TrebuchetActorID``
- ``TrebuchetError``

### Transport Layer

- ``TrebuchetTransport``
- ``TransportConfiguration``
- ``Endpoint``
- ``TransportMessage``
- ``TLSConfiguration``

### Serialization

- ``TrebuchetEncoder``
- ``TrebuchetDecoder``
- ``TrebuchetResultHandler``
