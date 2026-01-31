# ``Trebuchet/TrebuchetActorSystem``

## Overview

`TrebuchetActorSystem` is the core implementation of Swift's `DistributedActorSystem` protocol. It manages actor lifecycles, handles serialization, and coordinates remote method invocations.

In most cases, you won't interact with the actor system directly. Instead, you'll use ``TrebuchetServer`` or ``TrebuchetClient`` which manage the system for you.

## How It Works

When you create a distributed actor, the system:

1. Assigns a unique ``TrebuchetActorID`` to the actor
2. Registers the actor in its local registry
3. Makes the actor available for remote calls (if using a server)

When you call a method on a distributed actor:

1. The system serializes the method name and arguments
2. For local actors, it executes directly
3. For remote actors, it sends the call over the transport and awaits the response

## Direct Usage

While ``TrebuchetServer`` and ``TrebuchetClient`` are recommended, you can use the system directly:

```swift
let system = TrebuchetActorSystem.forServer(host: "0.0.0.0", port: 8080)
let actor = MyActor(actorSystem: system)
```

## Observability

The actor system provides optional callbacks for observing activity:

```swift
let server = TrebuchetServer(transport: .webSocket(port: 8080))

// Log method invocations
server.actorSystem.onInvocation = { actorID, method in
    print("📞 \(actorID).\(method)")
}

// Log stream lifecycle
server.actorSystem.onStreamStart = { actorID, method in
    print("🌊 Stream started: \(actorID).\(method)")
}

server.actorSystem.onStreamEnd = { actorID, method in
    print("🏁 Stream ended: \(actorID).\(method)")
}

// Log errors
server.actorSystem.onError = { actorID, error in
    print("❌ Error in \(actorID): \(error)")
}
```

These callbacks are useful for:
- Development debugging and tracing
- Production monitoring and metrics
- Audit logging of actor interactions

## Topics

### Creating a System

- ``init()``
- ``forServer(host:port:)``
- ``forClient()``

### System Properties

- ``host``
- ``port``

### Observability

- ``onInvocation``
- ``onStreamStart``
- ``onStreamEnd``
- ``onError``

### Dynamic Actor Creation

- ``onActorRequest``
- ``nameToIDTranslator``

### Serialization Types

- ``SerializationRequirement``
- ``InvocationEncoder``
- ``InvocationDecoder``
- ``ResultHandler``
