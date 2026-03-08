# Trebuchet

Location-transparent distributed actors for Swift.

[![Documentation](https://img.shields.io/badge/docs-DocC-blue)](https://briannadoubt.github.io/Trebuchet/documentation/trebuchet/)

## What It Does

Define an actor once. Call it from anywhere — same process, across the network, from a SwiftUI app, from a browser over WebAssembly, or from a Lambda function. Trebuchet handles the RPC, serialization, streaming, and reconnection.

```swift
@Trebuchet
distributed actor GameRoom {
    @StreamedState var players: [Player] = []

    distributed func join(player: Player) -> RoomState {
        players.append(player)
        return RoomState(players: players)
    }
}
```

That's it. No protocol buffers, no code generation, no REST endpoints. Just Swift.

## Installation

Add Trebuchet to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/briannadoubt/Trebuchet.git", from: "0.6.0")
]
```

Then add the products you need:

```swift
.target(name: "MyApp", dependencies: ["Trebuchet"])
.target(name: "MyServer", dependencies: ["Trebuchet", "TrebuchetCloud"])
```

## The System

A System is how you describe your backend. It declares which actors exist, how they're exposed, and where their state lives — all in Swift.

```swift
@main
struct MyGame: System {
    var topology: some Topology {
        GameRoom.self
            .expose(as: "room")
            .state(.surrealDB(url: nil))

        Lobby.self
            .expose(as: "lobby")

        Cluster("matchmaking") {
            MatchMaker.self
                .expose(as: "matcher")
                .state(.dynamoDB(table: "matches"))
        }
    }

    var deployments: some Deployments {
        Environment("production") {
            All.deploy(.aws(region: "us-east-1", memory: 512))
        }

        Environment("staging") {
            All.deploy(.fly(region: "iad"))
        }
    }
}
```

Run it locally:

```bash
trebuchet dev ./Server --product MyGame
```

Deploy it:

```bash
trebuchet deploy ./Server --product MyGame --provider fly
```

That's the entire workflow. No YAML. No Terraform to write. No Dockerfiles to maintain.

## Server and Client

For cases where you don't need the full System DSL — or you want manual control — the server and client APIs are straightforward:

```swift
// Server
let server = TrebuchetServer(transport: .webSocket(port: 8080))
let room = GameRoom(actorSystem: server.actorSystem)
await server.expose(room, as: "room")
try await server.run()

// Client
let client = TrebuchetClient(transport: .webSocket(host: "localhost", port: 8080))
try await client.connect()
let room = try client.resolve(GameRoom.self, id: "room")
let state = try await room.join(player: me)
```

## SwiftUI

Connect your app with one modifier:

```swift
@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .trebuchet(transport: .auto())
        }
    }
}
```

Then use actors directly in your views:

```swift
struct LobbyView: View {
    @RemoteActor(id: "lobby") var lobby: Lobby?

    var body: some View {
        switch $lobby.state {
        case .loading:
            ProgressView()
        case .resolved(let lobby):
            LobbyContent(lobby: lobby)
        case .failed(let error):
            ErrorView(error: error)
        case .disconnected:
            Text("Offline")
        }
    }
}
```

For streaming state that updates the UI automatically:

```swift
struct GameView: View {
    @ObservedActor var room: GameRoom?

    var body: some View {
        // room.players updates in real time via @StreamedState
        ForEach(room?.players ?? []) { player in
            PlayerRow(player: player)
        }
    }
}
```

## Streaming

Mark properties with `@StreamedState` and they automatically broadcast changes to all connected clients:

```swift
@Trebuchet
distributed actor Scoreboard {
    @StreamedState var scores: [String: Int] = [:]

    distributed func updateScore(player: String, points: Int) {
        scores[player, default: 0] += points
    }

    distributed func observeScores() -> AsyncStream<[String: Int]>
}
```

Clients subscribe with a standard `AsyncStream`:

```swift
for await scores in try await scoreboard.observeScores() {
    print("Live scores: \(scores)")
}
```

Streams support automatic resumption on reconnection — no data loss.

## Transports

Trebuchet ships with pluggable transports. Pick the right one for your use case:

| Transport | Use Case |
|-----------|----------|
| `.webSocket(host:port:)` | Browser clients, SwiftUI apps, general purpose |
| `.tcp(host:port:)` | High-performance server-to-server with length-prefixed framing |
| `.local` | In-process testing and SwiftUI previews, no networking |
| `.auto()` | Auto-resolves from environment variables, falls back to localhost |

```swift
// Testing without a network
let local = await TrebuchetLocal()
let actor = Counter(actorSystem: local.actorSystem)
await local.expose(actor, as: "counter")
let resolved = try local.resolve(Counter.self, id: "counter")
try await resolved.increment()  // In-process, no sockets
```

## Cloud Deployment

### AWS

```bash
trebuchet deploy ./Server --product MyGame --provider aws --region us-east-1
```

Generates Terraform and deploys:
- **Lambda** for actor execution
- **DynamoDB** for state persistence (auto-provisioned)
- **CloudMap** for actor-to-actor discovery

### Fly.io

```bash
trebuchet deploy ./Server --product MyGame --provider fly --region iad
```

Deploys as a Fly app with auto-scaling and zero-downtime deploys.

### Database Guidance

If your actors use PostgreSQL or SurrealDB without a configured connection URL, the deploy command tells you exactly what to run:

```
⚠ Actor GameRoom uses SurrealDB but no database URL is configured.

  To provision on Fly.io:
    fly apps create mygame-surrealdb
    fly volumes create surrealdb_data --app mygame-surrealdb --size 1 --region iad
    fly deploy --image surrealdb/surrealdb:latest --app mygame-surrealdb
    fly secrets set SURREALDB_URL=ws://mygame-surrealdb.internal:8000 --app mygame
```

### State Stores

| Store | Configuration | Auto-Provisioned |
|-------|--------------|------------------|
| In-memory | `.state(.memory)` | N/A |
| DynamoDB | `.state(.dynamoDB(table: "my-table"))` | Yes (AWS) |
| PostgreSQL | `.state(.postgres(databaseURL: "..."))` | Fly.io guided |
| SurrealDB | `.state(.surrealDB(url: "..."))` | Guided |

## Local Development

```bash
trebuchet dev ./Server --product MyGame
```

This:
1. Builds and runs your System executable
2. Auto-detects required databases from your topology
3. Starts them via [Compote](https://github.com/briannadoubt/compote) (macOS) or Docker Compose (Linux)
4. Injects connection URLs into the environment

Compote uses Apple's Containerization framework for sub-second container startup on macOS — no Docker Desktop required.

## Xcode Integration

For apps with a companion server package:

```bash
trebuchet xcode setup \
  --project-path . \
  --system-path ./Server \
  --product MyGame
```

Creates a managed Xcode scheme that starts the dev server on Run and stops it on Stop. One click runs both your app and your backend.

## WebAssembly

Trebuchet's WebSocket transport compiles to WASM via WASI, enabling browser-native distributed actor clients:

```bash
swift build --swift-sdk wasm32-unknown-wasi
```

The TCP transport and server-side `listen` are compiled out on WASI. Client `connect` / `send` / `receive` work natively in browser runtimes.

## Modules

| Module | Purpose |
|--------|---------|
| `Trebuchet` | Core framework — actors, transports, streaming, SwiftUI |
| `TrebuchetCloud` | Cloud gateway, provider protocol, state stores, service registry |
| `TrebuchetAWS` | AWS Lambda, DynamoDB, CloudMap implementations |
| `TrebuchetPostgreSQL` | PostgreSQL state store with LISTEN/NOTIFY sync |
| `TrebuchetSurrealDB` | SurrealDB state store with ORM, schema generation, graph relationships |
| `TrebuchetSecurity` | Authentication (API key, JWT), RBAC authorization, rate limiting |
| `TrebuchetObservability` | Structured logging, metrics, distributed tracing, CloudWatch |
| `TrebuchetCLI` | CLI library for `trebuchet dev`, `deploy`, `xcode`, `doctor` |

## CLI

```bash
trebuchet dev ./Server --product MyGame          # Run locally
trebuchet deploy ./Server --product MyGame       # Deploy to cloud
trebuchet deploy ... --dry-run                   # Preview deployment
trebuchet status                                 # Check deployment
trebuchet undeploy                               # Tear down infrastructure
trebuchet xcode setup ...                        # Wire Xcode scheme
trebuchet doctor                                 # Diagnose issues
```

Install via Mint:

```bash
mint install briannadoubt/Trebuchet
```

Or as a Swift package plugin — add Trebuchet as a dependency and use:

```bash
swift package plugin trebuchet dev . --product MyGame
```

## Requirements

- Swift 6.2+
- macOS 15+ / iOS 17+ / tvOS 17+ / watchOS 10+ / WASI

## Documentation

**[briannadoubt.github.io/Trebuchet](https://briannadoubt.github.io/Trebuchet/documentation/trebuchet/)**

## License

MIT
