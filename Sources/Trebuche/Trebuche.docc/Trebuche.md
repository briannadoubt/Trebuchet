# ``Trebuche``

A Swift 6.2 location-transparent distributed actor framework that makes RPC stupid simple.

## Overview

Trebuche enables Swift distributed actors to communicate seamlessly across process and network boundaries. Define your actors once, then deploy them anywhere – from local development to cloud serverless environments.

```swift
@Trebuchet
distributed actor GameRoom {
    distributed func join(player: Player) -> RoomState
}

// Server
let server = TrebuchetServer(transport: .webSocket(port: 8080))
let room = GameRoom(actorSystem: server.actorSystem)
await server.expose(room, as: "main-room")
try await server.run()

// Client
let client = TrebuchetClient(transport: .webSocket(host: "localhost", port: 8080))
try await client.connect()
let room = try client.resolve(GameRoom.self, id: "main-room")
try await room.join(player: me)
```

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:DefiningActors>
- <doc:SwiftUIIntegration>
- <doc:Streaming>
- <doc:AdvancedStreaming>

### Actor System

- ``TrebuchetActorSystem``
- ``TrebuchetActorID``
- ``TrebuchetError``

### Server and Client

- ``TrebuchetServer``
- ``TrebuchetClient``

### Transport Layer

- ``TrebuchetTransport``
- ``Endpoint``
- ``TransportMessage``
- ``TransportConfiguration``

### Serialization

- ``TrebuchetEncoder``
- ``TrebuchetDecoder``
- ``TrebuchetResultHandler``
- ``InvocationEnvelope``
- ``ResponseEnvelope``

### SwiftUI Integration

- ``TrebuchetConnection``
- ``TrebuchetConnectionManager``
- ``ConnectionState``

### Cloud Deployment

- <doc:CloudDeploymentOverview>
- <doc:DeployingToAWS>
- <doc:AWSConfiguration>
- <doc:CloudDeployment/AWSWebSocketStreaming>
- <doc:CloudDeployment/AWSCosts>
- <doc:DeployingToGCP>
- <doc:DeployingToAzure>

### Module Reference

- <doc:TrebucheCloud>
- <doc:TrebucheAWS>
