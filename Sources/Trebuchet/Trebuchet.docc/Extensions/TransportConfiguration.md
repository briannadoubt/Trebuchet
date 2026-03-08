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

### WASI / Browser Behavior

On WASI/browser runtimes:

- `.webSocket(...)` is supported for client-side communication
- server listen mode (`listen(on:)`) is unavailable
- TCP transport is compiled out

### With TLS

For secure connections, provide a ``TLSConfiguration``:

```swift
let tls = try TLSConfiguration(
    certificatePath: "/etc/ssl/certs/server.pem",
    privateKeyPath: "/etc/ssl/private/server.key"
)

.webSocket(host: "0.0.0.0", port: 8443, tls: tls)
```

## Automatic Transport Resolution

Use `.auto` when you want the client to pick up its connection endpoint from environment variables at runtime. This is particularly useful inside ``System`` executables started by `trebuchet dev`, which injects `TREBUCHET_HOST` and `TREBUCHET_PORT` automatically:

```swift
let client = TrebuchetClient(transport: .auto())
try await client.connect()
```

When the environment variables are present, `.auto` resolves to `.webSocket(host:port:)` using their values. When they are absent and `allowLocalhostFallback` is `true` (the default), it falls back to `127.0.0.1:8080`.

You can customise the environment key names and fallback values with ``AutoTransportOptions``:

```swift
let options = AutoTransportOptions(
    environmentHostKey: "MY_SERVER_HOST",
    environmentPortKey: "MY_SERVER_PORT",
    fallbackHost: "127.0.0.1",
    fallbackPort: 9000,
    allowLocalhostFallback: true
)
let client = TrebuchetClient(transport: .auto(options))
```

Call ``resolved(environment:)`` to obtain the concrete transport without creating a client:

```swift
let concrete = try TransportConfiguration.auto().resolved()
// concrete == .webSocket(host: "127.0.0.1", port: 8080) when env is empty
```

## Topics

### Transport Types

- ``webSocket(host:port:tls:)``
- ``tcp(host:port:)`` (not available on WASI builds)
- ``local``
- ``auto(_:)``

### Auto-Resolution

- ``AutoTransportOptions``
- ``resolvedForRuntime(environment:)``
- ``resolved(environment:)``

### Properties

- ``endpoint``
- ``tlsEnabled``
- ``tlsConfiguration``
