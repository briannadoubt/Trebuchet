# State Versioning and Optimistic Locking

Prevent data corruption during concurrent updates with version-based conflict detection.

## Overview

State versioning provides optimistic locking to prevent lost updates when multiple instances of an actor write to the same state concurrently. This is critical for zero-downtime deployments and distributed actor systems.

## The Problem

Without versioning, concurrent writes can corrupt state:

```swift
// Instance A and B both load counter = 5
// Instance A increments to 6 and saves
// Instance B increments to 6 and saves (overwriting A's update!)
// Final value: 6 (should be 7)
```

## The Solution: Optimistic Locking

Each state has a version number that increments on every write. Before saving, the system checks if the version matches:

```swift
@Trebuchet
distributed actor Counter: StatefulActor {
    struct PersistentState: Codable, Sendable {
        var count: Int = 0
    }

    var persistentState = PersistentState()

    distributed func increment(store: any ActorStateStore) async throws {
        // Safe update with automatic retry on version conflicts
        try await updateStateSafely(store: store) { current in
            var state = current ?? PersistentState()
            state.count += 1
            return state
        }
    }
}
```

## Version-Safe Methods

### saveIfVersion

Save state only if the version matches:

```swift
let snapshot = try await store.loadWithVersion(
    for: "actor-1",
    as: MyState.self
)

let newVersion = try await store.saveIfVersion(
    updatedState,
    for: "actor-1",
    expectedVersion: snapshot!.version
)
```

Throws `ActorStateError.versionConflict` if another write happened first.

### updateWithRetry

Automatically retry on version conflicts:

```swift
let finalState = try await store.updateWithRetry(
    for: "actor-1",
    as: MyState.self,
    maxRetries: 3
) { currentState in
    var state = currentState ?? MyState()
    state.counter += 1
    return state
}
```

Uses exponential backoff: 200ms, 400ms, 800ms.

### StateUpdater Helper

Convenient wrapper for common patterns:

```swift
let updater = StateUpdater<MyState>(
    store: store,
    actorID: "actor-1"
)

let newState = try await updater.update { current in
    var state = current ?? MyState()
    state.lastUpdate = Date()
    return state
}
```

## Error Handling

### Version Conflicts

```swift
do {
    try await store.saveIfVersion(state, for: id, expectedVersion: 5)
} catch ActorStateError.versionConflict(let expected, let actual) {
    print("Expected version \(expected) but state is at \(actual)")
    // Reload and retry
}
```

### Max Retries Exceeded

```swift
do {
    try await store.updateWithRetry(for: id, as: State.self) { ... }
} catch ActorStateError.maxRetriesExceeded {
    print("Too much contention - consider backoff strategy")
}
```

## Deployment Scenarios

### Rolling Deployment

When deploying v2 alongside v1:

1. Both versions load state (version N)
2. Both process requests and modify state
3. v1 tries to save (version N) → succeeds, becomes N+1
4. v2 tries to save (version N) → fails, retries
5. v2 reloads state (version N+1), applies changes, saves as N+2

Result: No lost updates.

### Concurrent Requests

Multiple requests to the same actor instance:

```swift
// Request 1: Increment counter
Task {
    try await actor.increment(store: store)
}

// Request 2: Increment counter
Task {
    try await actor.increment(store: store)
}

// Both succeed, counter increases by 2
```

## Database Support

### PostgreSQL

Uses conditional UPDATE:

```sql
UPDATE actor_states
SET state = $1,
    sequence_number = sequence_number + 1,
    updated_at = NOW()
WHERE actor_id = $2
  AND sequence_number = $3  -- Version check
RETURNING sequence_number
```

Returns 0 rows if version doesn't match.

### DynamoDB

Uses conditional expressions:

```
PutItem:
  ConditionExpression: "sequenceNumber = :expected"
  ExpressionAttributeValues:
    ":expected": 5
```

Throws `ConditionalCheckFailedException` on mismatch.

### In-Memory

For testing and local development:

```swift
let store = InMemoryStateStore()
try await store.saveIfVersion(state, for: id, expectedVersion: 3)
```

## Best Practices

### 1. Always Use Versioned Updates in Production

```swift
// ❌ Don't: Direct save in distributed environment
try await store.save(state, for: actorID)

// ✅ Do: Version-safe update
try await store.updateWithRetry(for: actorID, as: State.self) { current in
    // Transform state
}
```

### 2. Keep Transform Functions Fast

```swift
// ❌ Don't: Slow operations in transform
try await store.updateWithRetry(...) { current in
    let data = try await fetchFromAPI()  // Slow!
    return transform(current, with: data)
}

// ✅ Do: Fetch outside, transform inside
let data = try await fetchFromAPI()
try await store.updateWithRetry(...) { current in
    return transform(current, with: data)
}
```

### 3. Handle Max Retries Gracefully

```swift
do {
    try await store.updateWithRetry(for: id, as: State.self) { ... }
} catch ActorStateError.maxRetriesExceeded {
    // Back off and try again later
    try await Task.sleep(for: .seconds(1))
    // Or queue for retry
    await retryQueue.enqueue(actorID: id, operation: ...)
}
```

### 4. Test Concurrent Scenarios

```swift
// Simulate concurrent updates
async let update1 = actor.increment(store: store)
async let update2 = actor.increment(store: store)
async let update3 = actor.increment(store: store)

try await (update1, update2, update3)

// Verify all succeeded
let finalState = try await store.load(for: id, as: State.self)
XCTAssertEqual(finalState.count, 3)
```

## See Also

- ``ActorStateStore``
- ``StateUpdater``
- ``ActorStateError``
- ``StatefulActor``
