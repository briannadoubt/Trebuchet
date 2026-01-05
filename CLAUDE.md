# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# Build the package
swift build

# Run tests
swift test

# Run a specific test
swift test --filter TrebucheTests.testName
```

## Architecture

Trebuche is a Swift 6.2 location-transparent distributed actor framework that makes RPC stupid simple.

### Core Components

```
Sources/Trebuche/
├── Trebuche.swift              # Main entry, @Trebuchet macro declaration
├── ActorSystem/
│   ├── TrebuchetActorSystem.swift  # DistributedActorSystem implementation
│   ├── TrebuchetActorID.swift      # Actor identification (local/remote)
│   ├── TrebuchetError.swift        # Error types
│   └── Serialization.swift         # Encoder/Decoder/ResultHandler for wire format
├── Transport/
│   ├── Transport.swift             # Transport protocol, Endpoint, TransportMessage
│   └── WebSocket/
│       └── WebSocketTransport.swift # WebSocket implementation using swift-nio
├── Server/
│   └── TrebuchetServer.swift       # Server API for hosting actors
└── Client/
    └── TrebuchetClient.swift       # Client API for resolving remote actors

Sources/TrebucheMacros/
└── TrebucheMacros.swift            # @Trebuchet macro implementation
```

### Key Types

- **TrebuchetActorSystem**: Core `DistributedActorSystem` conformance
- **TrebuchetActorID**: Identifies actors (local or remote with host:port)
- **TrebuchetServer/TrebuchetClient**: High-level API for exposing and resolving actors
- **TrebuchetTransport**: Protocol for pluggable network transports
- **@Trebuchet macro**: Adds `typealias ActorSystem = TrebuchetActorSystem` to distributed actors

### Usage Pattern

```swift
// Define once
@Trebuchet
distributed actor GameRoom {
    distributed func join(player: Player) -> RoomState
}

// Server
let server = TrebuchetServer(transport: .webSocket(port: 8080))
let room = GameRoom(actorSystem: server.actorSystem)
await server.expose(room, as: "main-room")
try await server.run()

// Client
let client = TrebuchetClient(transport: .webSocket(host: "localhost", port: 8080))
try await client.connect()
let room = try client.resolve(GameRoom.self, id: "main-room")
try await room.join(player: me)
```

### Dependencies

- **swift-nio**: Cross-platform networking
- **websocket-kit**: WebSocket support
- **swift-syntax**: Macro implementation

### Tests

Tests use Swift Testing framework (`import Testing`). Run with `swift test`.
