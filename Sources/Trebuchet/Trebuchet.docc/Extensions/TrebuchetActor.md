# ``Trebuchet/TrebuchetActor``

## Overview

`TrebuchetActor` is a protocol that all Trebuchet distributed actors must conform to. It enforces a standard initialization interface, enabling the CLI to automatically instantiate actors for development and deployment.

The ``Trebuchet()`` macro automatically adds conformance to this protocol, so you typically don't need to conform to it manually.

## Initialization Requirements

The protocol requires a single initializer that takes only a ``TrebuchetActorSystem``:

```swift
init(actorSystem: TrebuchetActorSystem)
```

This initializer is used by:
- The `trebuchet dev` command to create actors in the development server
- The CLI-generated Lambda bootstrap code
- Dynamic actor creation via ``TrebuchetServer/onActorRequest``

## Using the @Trebuchet Macro

The ``Trebuchet()`` macro automatically adds conformance:

```swift
@Trebuchet
public distributed actor GameRoom {
    // Standard init required by TrebuchetActor
    public init(actorSystem: TrebuchetActorSystem) {
        self.actorSystem = actorSystem
        // Initialize with defaults for dev mode
    }
}
```

## Custom Initializers

For actors that need additional parameters in production, provide a separate initializer alongside the protocol-required one:

```swift
@Trebuchet
public distributed actor UserActor {
    let userID: String

    // Production initializer with custom parameters
    public init(actorSystem: TrebuchetActorSystem, userID: String) {
        self.actorSystem = actorSystem
        self.userID = userID
    }

    // Required by TrebuchetActor - used by CLI dev mode
    public init(actorSystem: TrebuchetActorSystem) {
        self.actorSystem = actorSystem
        // Provide sensible defaults for development
        self.userID = "dev-user-\(UUID())"
    }
}
```

> Important: Distributed actors do not support `convenience` initializers. You must provide separate regular initializers for each use case.

## Manual Conformance

While the macro is recommended, you can conform manually if needed:

```swift
distributed actor CustomActor: TrebuchetActor {
    typealias ActorSystem = TrebuchetActorSystem

    required init(actorSystem: TrebuchetActorSystem) {
        self.actorSystem = actorSystem
    }
}
```

## Topics

### Protocol Requirements

- ``init(actorSystem:)``

## See Also

- ``Trebuchet()``
- ``TrebuchetActorSystem``
- <doc:DefiningActors>
