# Defining Distributed Actors

Best practices for creating distributed actors with Trebuchet.

## Overview

Distributed actors in Trebuchet follow Swift's distributed actor model with some additional considerations for network communication.

## The @Trebuchet Macro

The simplest way to create a Trebuchet actor is with the `@Trebuchet` macro:

```swift
@Trebuchet
distributed actor GameRoom {
    distributed func join(player: Player) -> RoomState
}
```

This is equivalent to:

```swift
distributed actor GameRoom: TrebuchetActor {
    typealias ActorSystem = TrebuchetActorSystem

    distributed func join(player: Player) -> RoomState
}
```

The macro adds two things:
1. A `typealias ActorSystem = TrebuchetActorSystem` (if not already present)
2. Conformance to the ``TrebuchetActor`` protocol

## Actor Initialization

All Trebuchet actors must provide an initializer that takes only a ``TrebuchetActorSystem``:

```swift
@Trebuchet
public distributed actor GameRoom {
    public init(actorSystem: TrebuchetActorSystem) {
        self.actorSystem = actorSystem
        // Initialize with defaults
    }

    distributed func join(player: Player) -> RoomState
}
```

This standard initializer is required for:
- The `trebuchet dev` command to create actors automatically
- CLI-generated deployment code
- Dynamic actor creation with ``TrebuchetServer/onActorRequest``

### Actors with Custom Parameters

For actors that need additional initialization parameters in production, provide both initializers:

```swift
@Trebuchet
public distributed actor UserActor {
    let userID: String

    // Production initializer
    public init(actorSystem: TrebuchetActorSystem, userID: String) {
        self.actorSystem = actorSystem
        self.userID = userID
    }

    // Development initializer (required by TrebuchetActor)
    public init(actorSystem: TrebuchetActorSystem) {
        self.actorSystem = actorSystem
        self.userID = "dev-user-\(UUID())"
    }
}
```

> Important: Distributed actors do not support `convenience` initializers. Provide separate regular initializers for each use case.

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
// @trebuchet:memory=1024
// @trebuchet:timeout=60
// @trebuchet:isolated=true
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

- ``TrebuchetActor``
- ``TrebuchetActorSystem``
- ``TrebuchetActorID``
- <doc:GettingStarted>
