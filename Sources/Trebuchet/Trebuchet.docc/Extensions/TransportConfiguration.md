# ``Trebuchet/TransportConfiguration``

## Overview

`TransportConfiguration` specifies how Trebuchet communicates over the network. It's used when creating servers and clients.

## WebSocket Transport

WebSocket is the default and recommended transport:

```swift
// Server - listen on all interfaces
.webSocket(port: 8080)

// Server - specific interface
.webSocket(host: "192.168.1.100", port: 8080)

// Client
.webSocket(host: "game.example.com", port: 8080)
```

### With TLS

For secure connections, provide a ``TLSConfiguration``:

```swift
let tls = try TLSConfiguration(
    certificatePath: "/etc/ssl/certs/server.pem",
    privateKeyPath: "/etc/ssl/private/server.key"
)

.webSocket(host: "0.0.0.0", port: 8443, tls: tls)
```

## Local Transport

For in-process communication without network overhead:

```swift
// Testing
let local = TrebuchetLocal()

// SwiftUI Previews
.trebuchet(transport: .local)

// Server/Client pattern
let server = TrebuchetServer(transport: .local)
let client = TrebuchetClient(transport: .local)
```

The `.local` transport is ideal for:
- Unit testing
- SwiftUI previews
- Single-process deployments
- Performance benchmarking

See <doc:LocalTransport> for detailed usage.

## Topics

### Transport Types

- ``webSocket(host:port:tls:)``
- ``tcp(host:port:)``
- ``local``

### Properties

- ``endpoint``
- ``tlsEnabled``
- ``tlsConfiguration``
