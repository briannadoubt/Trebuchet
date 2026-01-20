# Defining Distributed Actors

Best practices for creating distributed actors with Trebuche.

## Overview

Distributed actors in Trebuche follow Swift's distributed actor model with some additional considerations for network communication.

## The @Trebuchet Macro

The simplest way to create a Trebuche actor is with the `@Trebuchet` macro:

```swift
@Trebuchet
distributed actor GameRoom {
    distributed func join(player: Player) -> RoomState
}
```

This is equivalent to:

```swift
distributed actor GameRoom {
    typealias ActorSystem = TrebuchetActorSystem

    distributed func join(player: Player) -> RoomState
}
```

## Method Requirements

All distributed methods must:

1. Be marked with `distributed`
2. Have parameters that conform to `Codable`
3. Have a return type that conforms to `Codable` (or be `Void`)

```swift
@Trebuchet
distributed actor UserService {
    // ✅ Good - Codable parameter and return type
    distributed func getUser(id: UUID) -> User

    // ✅ Good - Void return type
    distributed func deleteUser(id: UUID)

    // ✅ Good - Throws errors
    distributed func updateUser(_ user: User) throws -> User

    // ❌ Bad - Non-Codable parameter
    // distributed func process(stream: AsyncStream<Data>)
}
```

## Stateful Actors

For actors that need persistent state in serverless environments, conform to `StatefulActor`:

```swift
@Trebuchet
distributed actor ShoppingCart: StatefulActor {
    typealias PersistentState = CartState

    var persistentState = CartState()

    distributed func addItem(_ item: Item) -> CartState {
        persistentState.items.append(item)
        return persistentState
    }

    func loadState(from store: any ActorStateStore) async throws {
        if let state = try await store.load(for: id.id, as: CartState.self) {
            persistentState = state
        }
    }

    func saveState(to store: any ActorStateStore) async throws {
        try await store.save(persistentState, for: id.id)
    }
}

struct CartState: Codable, Sendable {
    var items: [Item] = []
}
```

## Actor Annotations

Use comments to configure actor deployment:

```swift
// @trebuche:memory=1024
// @trebuche:timeout=60
// @trebuche:isolated=true
@Trebuchet
distributed actor HeavyProcessor {
    distributed func process(data: Data) -> ProcessedResult
}
```

These annotations are read by the CLI during deployment.

## Error Handling

Distributed methods can throw errors that are serialized across the network:

```swift
enum GameError: Error, Codable {
    case roomFull
    case invalidPlayer
    case gameAlreadyStarted
}

@Trebuchet
distributed actor GameRoom {
    distributed func join(player: Player) throws -> RoomState {
        guard players.count < maxPlayers else {
            throw GameError.roomFull
        }
        // ...
    }
}
```

## See Also

- ``TrebuchetActorSystem``
- ``TrebuchetActorID``
- <doc:GettingStarted>
