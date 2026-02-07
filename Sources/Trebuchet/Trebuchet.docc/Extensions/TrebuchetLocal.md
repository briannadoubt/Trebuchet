# ``Trebuchet/TrebuchetLocal``

## Overview

`TrebuchetLocal` combines server and client functionality for in-process distributed actor communication, making it ideal for testing, development, and single-process applications.

Each `TrebuchetLocal` instance uses an **isolated transport** - actors exposed on one instance are only accessible from that same instance. This ensures test isolation and prevents cross-contamination between test cases or different parts of your application.

## Basic Usage

```swift
@Trebuchet
distributed actor Counter {
    var count = 0

    distributed func increment() -> Int {
        count += 1
        return count
    }
}

// Create isolated local instance
let local = await TrebuchetLocal()

// Expose an actor
let counter = Counter(actorSystem: local.actorSystem)
await local.expose(counter, as: "counter")

// Resolve and invoke
let resolved = try local.resolve(Counter.self, id: "counter")
let count = try await resolved.increment()  // Returns 1
```

## Instance Isolation

Each `TrebuchetLocal` instance maintains its own isolated actor registry:

```swift
let local1 = await TrebuchetLocal()
let local2 = await TrebuchetLocal()

let counter1 = Counter(actorSystem: local1.actorSystem)
await local1.expose(counter1, as: "counter")

// This will fail - local2 cannot resolve actors from local1
let resolved = try? local2.resolve(Counter.self, id: "counter")  // nil
```

This isolation ensures:
- **Test independence**: Each test case can use its own `TrebuchetLocal` without affecting others
- **Clean state**: No shared state between instances
- **Predictable behavior**: Actors are only accessible through the instance that exposed them

## Cleanup in Tests

Use the ``shutdown()`` method to ensure deterministic cleanup between test cases:

```swift
@Test("Counter increments correctly")
func testCounter() async throws {
    let local = await TrebuchetLocal()

    let counter = Counter(actorSystem: local.actorSystem)
    await local.expose(counter, as: "counter")

    let resolved = try local.resolve(Counter.self, id: "counter")
    let count = try await resolved.increment()

    #expect(count == 1)

    // Clean up
    await local.shutdown()
}
```

## Streaming Support

Configure streaming for actors with `@StreamedState` properties:

```swift
@Trebuchet
distributed actor GameRoom {
    @StreamedState var players: [Player] = []

    distributed func addPlayer(_ player: Player) {
        players.append(player)
    }

    distributed func observePlayers() -> AsyncStream<[Player]>
}

let local = await TrebuchetLocal()

// Configure streaming
await local.configureStreaming(
    for: GameRoomStreaming.self,
    method: "observePlayers"
) { await $0.observePlayers() }

// Expose and resolve
let room = GameRoom(actorSystem: local.actorSystem)
await local.expose(room, as: "main-room")

let resolved = try local.resolve(GameRoom.self, id: "main-room")

// Subscribe to updates
for await players in try await resolved.observePlayers() {
    print("Players: \(players)")
}
```

## Topics

### Creating Instances

- ``init()``

### Managing Actors

- ``actorSystem``
- ``expose(_:as:)``
- ``resolve(_:id:)``

### Streaming Configuration

- ``configureStreaming(for:method:handler:)``
- ``configureStreaming(for:handler:)``

### Cleanup

- ``shutdown()``
