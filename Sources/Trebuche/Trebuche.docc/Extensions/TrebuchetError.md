# ``Trebuche/TrebuchetError``

## Overview

`TrebuchetError` represents errors that can occur during distributed actor operations. All errors conform to `Sendable` and provide descriptive messages.

## Common Error Cases

### Connection Errors

```swift
case .connectionFailed(host: "server.local", port: 8080, underlying: error)
case .connectionClosed
```

These occur when the network connection fails or drops unexpectedly.

### Actor Errors

```swift
case .actorNotFound(actorID)
case .remoteInvocationFailed("Method threw an exception")
```

These occur when the remote actor can't be found or the method call fails.

### Serialization Errors

```swift
case .serializationFailed(encodingError)
case .deserializationFailed(decodingError)
```

These occur when arguments or return values can't be encoded/decoded. Make sure your types conform to `Codable`.

## Error Handling Example

```swift
do {
    try await remoteActor.doSomething()
} catch let error as TrebuchetError {
    switch error {
    case .connectionClosed:
        // Reconnect and retry
        try await client.connect()
        try await remoteActor.doSomething()

    case .timeout(let duration):
        print("Call timed out after \(duration)")

    case .actorNotFound(let id):
        print("Actor \(id) not found on server")

    default:
        print("Error: \(error.description)")
    }
}
```

## Topics

### Connection Errors

- ``connectionFailed(host:port:underlying:)``
- ``connectionClosed``

### Actor Errors

- ``actorNotFound(_:)``
- ``remoteInvocationFailed(_:)``
- ``systemNotRunning``

### Serialization Errors

- ``serializationFailed(_:)``
- ``deserializationFailed(_:)``

### Other Errors

- ``timeout(duration:)``
- ``invalidConfiguration(_:)``
