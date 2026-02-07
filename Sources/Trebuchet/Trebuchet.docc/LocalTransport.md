# Local Transport

Use the local transport for in-process actor communication with zero network overhead.

## Overview

The `.local` transport enables distributed actors to communicate within a single process without network overhead. This is ideal for:

- **Testing** - Write tests without network configuration
- **SwiftUI Previews** - Set up actors in Xcode previews
- **Development** - Rapid prototyping with instant actor communication
- **Single-process deployments** - Use distributed actors without networking

Unlike network-based transports (WebSocket, TCP), local transport routes messages through in-memory channels, eliminating serialization overhead and network latency.

## Quick Start

### Testing with TrebuchetLocal

The ``TrebuchetLocal`` API combines server and client functionality for simplified in-process communication:

```swift
import Testing
import Trebuchet

@Test("Test distributed counter")
func testCounter() async throws {
    // Create a local instance
    let local = await TrebuchetLocal()

    // Expose an actor
    let counter = Counter(actorSystem: local.actorSystem)
    await local.expose(counter, as: "test-counter")

    // Resolve and invoke
    let resolved = try local.resolve(Counter.self, id: "test-counter")
    let value = try await resolved.increment()

    #expect(value == 1)
}
```

### SwiftUI Previews

Use `.local` transport with the `TrebuchetPreview` helper for Xcode previews:

```swift
import SwiftUI
import Trebuchet

#Preview {
    GameView()
        .trebuchet(transport: .local)
        .task {
            let room = GameRoom(actorSystem: TrebuchetPreview.server.actorSystem)
            await room.addPlayer(Player(name: "Alice"))
            await TrebuchetPreview.expose(room, as: "preview-room")
        }
}
```

## Using TrebuchetLocal

``TrebuchetLocal`` provides a unified API that combines ``TrebuchetServer`` and ``TrebuchetClient`` for in-process communication.

### Basic Usage

```swift
let local = await TrebuchetLocal()

// Expose actors
let gameRoom = GameRoom(actorSystem: local.actorSystem)
await local.expose(gameRoom, as: "main-room")

// Resolve actors
let room = try local.resolve(GameRoom.self, id: "main-room")
try await room.join(player: me)
```

### Factory Pattern

Create and expose actors in one call:

```swift
let counter = await local.expose("counter") { actorSystem in
    Counter(actorSystem: actorSystem)
}

// Use the actor directly
try await counter.increment()

// Or resolve it by ID
let resolved = try local.resolve(Counter.self, id: "counter")
```

### Streaming Configuration

Configure streaming for actors with `@StreamedState` properties:

```swift
await local.configureStreaming(
    for: GameRoomStreaming.self,
    method: "observePlayers"
) { await $0.observePlayers() }

let room = try local.resolve(GameRoom.self, id: "main-room")
for await players in try await room.observePlayers() {
    print("Players: \(players)")
}
```

## SwiftUI Preview Integration

The `TrebuchetPreview` helper provides static access to the shared local server for previews.

### Basic Preview Setup

```swift
#Preview {
    LobbyView()
        .trebuchet(transport: .local)
        .task {
            let lobby = Lobby(actorSystem: TrebuchetPreview.server.actorSystem)
            await lobby.addPlayer(Player(name: "Alice"))
            await TrebuchetPreview.expose(lobby, as: "lobby")
        }
}
```

### Custom PreviewModifier

For reusable preview setups, create a custom `PreviewModifier`:

```swift
struct GameRoomPreview: PreviewModifier {
    static func makeSharedContext() async throws {
        let room = GameRoom(actorSystem: TrebuchetPreview.server.actorSystem)
        await room.addPlayers([
            Player(name: "Alice"),
            Player(name: "Bob")
        ])
        await TrebuchetPreview.expose(room, as: "game-room")
    }

    func body(content: Content, context: Void) -> some View {
        content.trebuchet(transport: .local)
    }
}

#Preview("Game Room", traits: .modifier(GameRoomPreview())) {
    GameRoomView()
}
```

### Preview Trait

Use the `.trebuchet` trait for simple setups:

```swift
#Preview("Simple", traits: .trebuchet) {
    ContentView()
}
```

## Using .local with Server and Client

You can also use the `.local` transport with separate ``TrebuchetServer`` and ``TrebuchetClient`` instances:

```swift
// Server
let server = TrebuchetServer(transport: .local)
let lobby = GameLobby(actorSystem: server.actorSystem)
await server.expose(lobby, as: "lobby")

// Client
let client = TrebuchetClient(transport: .local)
try await client.connect()

// Resolve and use
let remoteLobby = try client.resolve(GameLobby.self, id: "lobby")
let players = try await remoteLobby.getPlayers()
```

## Shared Transport

All local transport instances use a shared singleton (``LocalTransport/shared``), allowing actors to discover each other across different ``TrebuchetLocal`` instances in the same process.

```swift
// Instance A
let localA = await TrebuchetLocal()
let counter = Counter(actorSystem: localA.actorSystem)
await localA.expose(counter, as: "shared-counter")

// Instance B (can resolve actors from A)
let localB = await TrebuchetLocal()
let resolved = try localB.resolve(Counter.self, id: "shared-counter")
```

## Performance Characteristics

The local transport provides:

- **Near-zero latency** - No network stack traversal
- **Zero serialization overhead** - Direct in-memory message passing
- **No socket I/O** - Bypasses all network layers
- **Instant connection** - No async handshake required

Use local transport for benchmarking to measure pure actor system performance without network overhead.

## Thread Safety

- ``LocalTransport`` is an actor providing thread-safe access
- ``TrebuchetLocal`` uses internal actors for safe concurrent access
- All message handling uses structured concurrency
- Safe to call from any context

## Topics

### Unified API

- ``TrebuchetLocal``

### Transport Layer

- ``LocalTransport``
- ``TransportConfiguration/local``

### SwiftUI Support

- ``TrebuchetPreview``
- ``TrebuchetPreviewModifier``

### See Also

- <doc:GettingStarted>
- <doc:SwiftUIIntegration>
- <doc:Streaming>
