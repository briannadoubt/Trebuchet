# ``Trebuchet/TrebuchetServer``

## Overview

`TrebuchetServer` is your main entry point for hosting distributed actors. It manages the transport layer, handles incoming connections, and routes remote calls to the appropriate local actors.

## Creating a Server

The simplest way to create a server uses WebSocket transport:

```swift
let server = TrebuchetServer(transport: .webSocket(port: 8080))
```

For production, add TLS:

```swift
let tls = try TLSConfiguration(
    certificatePath: "/path/to/fullchain.pem",
    privateKeyPath: "/path/to/privkey.pem"
)
let server = TrebuchetServer(transport: .webSocket(port: 8443, tls: tls))
```

## Exposing Actors

Before clients can access your actors, you must expose them with a name:

```swift
let gameRoom = GameRoom(actorSystem: server.actorSystem)
await server.expose(gameRoom, as: "main-room")
```

The name you choose becomes the identifier clients use to resolve the actor.

## Running the Server

The ``run()`` method blocks and processes incoming requests:

```swift
// This runs until shutdown() is called
try await server.run()
```

For graceful shutdown:

```swift
Task {
    // Wait for shutdown signal
    await server.shutdown()
}
try await server.run()
```

## Dynamic Actor Creation

You can configure the server to create actors on-demand when clients request them:

```swift
let server = TrebuchetServer(transport: .webSocket(port: 8080))

server.onActorRequest = { actorID in
    switch actorID.id {
    case let id where id.hasPrefix("game-room-"):
        let room = GameRoom(actorSystem: server.actorSystem)
        await server.expose(room, as: actorID.id)
    case let id where id.hasPrefix("user-"):
        let user = UserActor(actorSystem: server.actorSystem)
        await server.expose(user, as: actorID.id)
    default:
        break
    }
}

try await server.run()
```

This is particularly useful for:
- Development servers that create actors dynamically
- Multi-tenant systems where actors are created per-user or per-session
- Lazy initialization of actors only when needed

## Topics

### Creating a Server

- ``init(transport:)``

### Managing Actors

- ``expose(_:as:)``
- ``actorID(for:)``
- ``actorSystem``
- ``onActorRequest``

### Running the Server

- ``run()``
- ``shutdown()``
