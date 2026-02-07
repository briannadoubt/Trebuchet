# ``Trebuchet/TrebuchetLocal``

A unified server and client for in-process distributed actors.

## Overview

`TrebuchetLocal` combines the functionality of ``TrebuchetServer`` and ``TrebuchetClient`` without requiring network configuration. It's ideal for testing, SwiftUI previews, and single-process applications.

### Basic Usage

```swift
let local = await TrebuchetLocal()

// Expose an actor
let counter = Counter(actorSystem: local.actorSystem)
await local.expose(counter, as: "counter")

// Resolve and invoke
let resolved = try local.resolve(Counter.self, id: "counter")
let count = try await resolved.increment()
```

### Testing Example

```swift
@Test
func testDistributedCounter() async throws {
    let local = await TrebuchetLocal()

    let counter = Counter(actorSystem: local.actorSystem)
    await local.expose(counter, as: "test-counter")

    let resolved = try local.resolve(Counter.self, id: "test-counter")
    let result = try await resolved.increment()

    #expect(result == 1)
}
```

### Factory Pattern

Create and expose actors in one call:

```swift
let counter = await local.expose("counter") { actorSystem in
    Counter(actorSystem: actorSystem)
}

// Use directly or resolve by ID
try await counter.increment()
```

## Shared Transport

All `TrebuchetLocal` instances share the same underlying transport (``LocalTransport/shared``), allowing actors to be discovered across different instances in the same process.

## Thread Safety

`TrebuchetLocal` uses internal actors for thread-safe access to actor registries and streaming configuration. All public methods are safe to call from any context.

## Topics

### Creating an Instance

- ``init()``

### Actor Management

- ``actorSystem``
- ``expose(_:as:)``
- ``expose(_:factory:)``
- ``resolve(_:id:)``
- ``actorID(for:)``

### Streaming Configuration

- ``configureStreaming(_:)``
- ``configureStreaming(for:handler:)``
- ``configureStreaming(for:method:observe:)-4s99s``
- ``configureStreaming(for:method:observe:)-8b9le``
- ``configureStreaming(for:handler:)-6lhxr``
- ``encodeStream(_:)``

### See Also

- <doc:LocalTransport>
- ``LocalTransport``
- ``TrebuchetPreview``
