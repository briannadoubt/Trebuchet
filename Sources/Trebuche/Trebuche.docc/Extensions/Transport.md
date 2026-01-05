# ``Trebuche/TrebuchetTransport``

## Overview

`TrebuchetTransport` is the protocol for network transport implementations. Trebuche includes a WebSocket transport, but you can implement custom transports for different protocols.

## Built-in Transports

### WebSocket Transport

The default transport uses WebSockets, which work well for bidirectional communication:

```swift
// Server
TrebuchetServer(transport: .webSocket(port: 8080))

// Client
TrebuchetClient(transport: .webSocket(host: "localhost", port: 8080))
```

## Custom Transports

Implement `TrebuchetTransport` to add support for other protocols:

```swift
public struct MyCustomTransport: TrebuchetTransport {
    public func send(_ data: Data, to endpoint: Endpoint) async throws {
        // Send data to the endpoint
    }

    public func listen(on endpoint: Endpoint) async throws {
        // Start listening for connections
    }

    public func shutdown() async {
        // Clean up resources
    }

    public var incoming: AsyncStream<TransportMessage> {
        // Return stream of incoming messages
    }
}
```

## Topics

### Protocol Requirements

- ``send(_:to:)``
- ``listen(on:)``
- ``shutdown()``
- ``incoming``
