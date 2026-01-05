# Getting Started with Trebuche

Learn how to build distributed applications with location-transparent actors.

## Overview

Trebuche makes it easy to build networked Swift applications using distributed actors. Your actors work the same whether they're running locally or on a remote server.

## Adding Trebuche to Your Project

Add Trebuche as a dependency in your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/your-org/Trebuche.git", from: "1.0.0")
]
```

Then add it to your target:

```swift
.target(
    name: "MyApp",
    dependencies: ["Trebuche"]
)
```

## Defining a Distributed Actor

Use the ``Trebuchet()`` macro to mark your distributed actors:

```swift
import Trebuche

@Trebuchet
distributed actor Counter {
    private var value = 0

    distributed func increment() -> Int {
        value += 1
        return value
    }

    distributed func getValue() -> Int {
        value
    }
}
```

The macro automatically adds the required `ActorSystem` typealias, so you don't need any boilerplate.

### Serialization Requirements

All parameters and return types of `distributed` methods must conform to `Codable`. This ensures they can be serialized for network transport.

```swift
struct Player: Codable, Sendable {
    let id: String
    let name: String
}

@Trebuchet
distributed actor GameRoom {
    private var players: [Player] = []

    distributed func join(player: Player) -> [Player] {
        players.append(player)
        return players
    }
}
```

## Creating a Server

Use ``TrebuchetServer`` to host your actors:

```swift
import Trebuche

@main
struct GameServer {
    static func main() async throws {
        // Create a server on port 8080
        let server = TrebuchetServer(
            transport: .webSocket(port: 8080)
        )

        // Create and expose an actor
        let room = GameRoom(actorSystem: server.actorSystem)
        await server.expose(room, as: "lobby")

        print("Server running on port 8080")
        try await server.run()
    }
}
```

### Exposing Multiple Actors

You can expose as many actors as you need:

```swift
let lobby = GameRoom(actorSystem: server.actorSystem)
let ranked = GameRoom(actorSystem: server.actorSystem)
let counter = Counter(actorSystem: server.actorSystem)

await server.expose(lobby, as: "lobby")
await server.expose(ranked, as: "ranked")
await server.expose(counter, as: "global-counter")
```

## Creating a Client

Use ``TrebuchetClient`` to connect and resolve remote actors:

```swift
import Trebuche

let client = TrebuchetClient(
    transport: .webSocket(host: "localhost", port: 8080)
)

try await client.connect()

// Resolve a remote actor
let lobby = try client.resolve(GameRoom.self, id: "lobby")

// Call methods as if it were local!
let players = try await lobby.join(player: Player(id: "1", name: "Alice"))
print("Players in lobby: \(players)")
```

## Using TLS for Secure Connections

For production deployments, enable TLS:

```swift
// Server with TLS
let tls = try TLSConfiguration(
    certificatePath: "/path/to/cert.pem",
    privateKeyPath: "/path/to/key.pem"
)

let server = TrebuchetServer(
    transport: .webSocket(port: 8443, tls: tls)
)
```

## Error Handling

Trebuche throws ``TrebuchetError`` for various failure conditions:

```swift
do {
    let room = try client.resolve(GameRoom.self, id: "unknown")
    try await room.join(player: me)
} catch let error as TrebuchetError {
    switch error {
    case .actorNotFound(let id):
        print("Actor not found: \(id)")
    case .connectionFailed(let reason):
        print("Connection failed: \(reason)")
    case .remoteInvocationFailed(let message):
        print("Remote call failed: \(message)")
    default:
        print("Error: \(error)")
    }
}
```

## Next Steps

- Explore ``TrebuchetServer`` for advanced server configuration
- Learn about ``TrebuchetTransport`` for custom transport implementations
- Check out ``TrebuchetActorID`` to understand actor identification
