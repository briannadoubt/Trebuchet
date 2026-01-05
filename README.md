# Trebuche

Location-transparent distributed actors for Swift. Make RPC stupid simple.

[![Documentation](https://img.shields.io/badge/docs-DocC-blue)](https://bri.github.io/Trebuche/documentation/trebuche/)

## Overview

Trebuche is a Swift 6.2 distributed actor framework that lets you define actors once and use them seamlessly whether they're local or remote.

```swift
@Trebuchet
distributed actor GameRoom {
    distributed func join(player: Player) -> RoomState
}
```

## Installation

Add Trebuche to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/bri/Trebuche.git", from: "1.0.0")
]
```

Then add it to your target:

```swift
.target(
    name: "MyApp",
    dependencies: ["Trebuche"]
)
```

## Quick Start

### Server

```swift
import Trebuche

let server = TrebuchetServer(transport: .webSocket(port: 8080))
let room = GameRoom(actorSystem: server.actorSystem)
await server.expose(room, as: "main-room")
try await server.run()
```

### Client

```swift
import Trebuche

let client = TrebuchetClient(transport: .webSocket(host: "localhost", port: 8080))
try await client.connect()

let room = try client.resolve(GameRoom.self, id: "main-room")
try await room.join(player: me)  // Looks local, works remotely!
```

## Documentation

Full documentation is available at **[bri.github.io/Trebuche](https://bri.github.io/Trebuche/documentation/trebuche/)**.

## Requirements

- Swift 6.2+
- macOS 14+ / iOS 17+ / tvOS 17+ / watchOS 10+

## License

MIT
