# ``Trebuchet/TransportConfiguration``

## Overview

`TransportConfiguration` specifies how Trebuchet communicates over the network. It's used when creating servers and clients.

## Local Transport

For in-process communication without network overhead, use the `.local` transport:

```swift
// Create server and client with local transport
let server = TrebuchetServer(transport: .local)
let client = TrebuchetClient(transport: .local)

// Or use TrebuchetLocal for a unified API
let local = await TrebuchetLocal()
```

The `.local` transport is ideal for:
- **Testing**: No network setup required, instant connections
- **SwiftUI Previews**: Works in sandboxed preview environments
- **Development**: Zero latency for rapid prototyping
- **Single-process apps**: Location transparency within one process

See ``TrebuchetLocal`` for a convenient unified API.

## WebSocket Transport

WebSocket is the recommended transport for network communication:

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

## Topics

### Transport Types

- ``local``
- ``webSocket(host:port:tls:)``
- ``tcp(host:port:)``

### Properties

- ``endpoint``
- ``tlsEnabled``
- ``tlsConfiguration``
