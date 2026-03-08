# Trebuchet

Location-transparent distributed actors for Swift. Make RPC stupid simple.

[![Documentation](https://img.shields.io/badge/docs-DocC-blue)](https://briannadoubt.github.io/Trebuchet/documentation/trebuchet/)

## Overview

Trebuchet is a Swift 6.2 distributed actor framework that lets you define actors once and use them seamlessly whether they're local or remote.

```swift
@Trebuchet
distributed actor GameRoom {
    distributed func join(player: Player) -> RoomState
}
```

## Installation

### Library

Add Trebuchet to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/briannadoubt/Trebuchet.git", from: "1.0.0")
]
```

Then add it to your target:

```swift
.target(
    name: "MyApp",
    dependencies: ["Trebuchet"]
)
```

### CLI Tool

The `trebuchet` CLI enables local development and cloud deployment for **System executables in Swift packages**. You can use it in three ways:

#### Swift Package Plugin (Recommended for Projects)

Add Trebuchet as a dependency in your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/briannadoubt/Trebuchet.git", from: "1.0.0")
]
```

Then use the plugin from the command line:

```bash
# Run locally
swift package plugin --allow-writing-to-package-directory trebuchet dev . --product MySystem

# Deploy to cloud
swift package plugin --allow-writing-to-package-directory --allow-network-connections all trebuchet deploy . --product MySystem --provider fly
```

Or in **Xcode**:
1. Add Trebuchet package dependency to your Xcode project
2. Right-click on your project in the navigator
3. Select **Trebuchet** from the plugin menu
4. Choose a subcommand (`dev`, `deploy`, `xcode`, `doctor`, etc.)

#### Mint (Recommended for Global Installation)

```bash
mint install briannadoubt/Trebuchet
trebuchet deploy . --product MySystem --provider aws
```

#### Build from Source

```bash
git clone https://github.com/briannadoubt/Trebuchet.git
cd Trebuchet
./scripts/build-cli.sh release
cp .build/release/trebuchet /usr/local/bin/trebuchet
```

`build-cli.sh` builds and signs the CLI binary with virtualization entitlements required by Compote.

## Quick Start

### Server

```swift
import Trebuchet

let server = TrebuchetServer(transport: .webSocket(port: 8080))
let room = GameRoom(actorSystem: server.actorSystem)
await server.expose(room, as: "main-room")
try await server.run()
```

### Client

```swift
import Trebuchet

let client = TrebuchetClient(transport: .webSocket(host: "localhost", port: 8080))
try await client.connect()

let room = try client.resolve(GameRoom.self, id: "main-room")
try await room.join(player: me)  // Looks local, works remotely!
```

## Local Development

Run your System executable locally:

```bash
# Start local development server
trebuchet dev ./Server --product AuraSystem --port 8080

# Customize host and port
trebuchet dev ./Server --product AuraSystem --host 0.0.0.0 --port 3000

# Enable verbose output
trebuchet dev ./Server --product AuraSystem --verbose
```

On macOS, if the CLI binary is missing virtualization entitlements, Trebuchet will automatically sign the binary and relaunch the command.

The `dev` command:
- Resolves your `@main ...: System` executable from a Swift package
- Runs topology-driven local development mode
- Starts optional dependency orchestration from compose manifests (`compote.yml` / `docker-compose.yml` / `compose.yml`)
- Uses Compote by default on macOS and Docker Compose on non-macOS

## WebAssembly (WASI / Browser)

Trebuchet supports WASI builds and browser WebSocket clients.

- `WebSocketTransport` works in WASI as a client (`connect` / `send` / receive via `incoming`)
- `listen(on:)` is not supported on WASI/browser runtimes
- TCP transport is compiled out on WASI (`#if !os(WASI)`)

Run the checked-in end-to-end WASM WebSocket probe:

```bash
./Tests/WasmE2E/run-wasm-websocket-e2e.sh
```

## Xcode Project Support

Trebuchet supports Xcode app projects with a **System package server** (commonly `./Server`):

```bash
cd /path/to/YourXcodeProject
trebuchet dev ./Server --product AuraSystem --verbose
```

### How It Works

The CLI automatically:
1. Uses your app project as the Xcode host
2. Starts/stops a dev session for your System package executable
3. Injects `TREBUCHET_HOST` / `TREBUCHET_PORT` into the managed scheme
4. Keeps server code in one source of truth (your System package)

### Features

✅ **Single source of truth** - System package remains canonical
✅ **No generated harnesses** - No `.trebuchet` source-copy server path
✅ **One workflow** - same `dev` / `deploy` contract locally and in CI
✅ **Managed Xcode run loop** - pre-run start, post-run stop

See **[Xcode Project Support](Sources/Trebuchet/Trebuchet.docc/XCODE_PROJECT_SUPPORT.md)** for detailed documentation.

### One-Click Xcode Run (App + Server)

Trebuchet can now wire an Xcode shared scheme that starts and stops the dev server automatically:

```bash
cd /path/to/YourXcodeProject
trebuchet xcode setup \
  --project-path . \
  --system-path ./Server \
  --product AuraSystem \
  --host localhost \
  --port 8080
```

This creates:
- A managed shared scheme: `<YourScheme>+Trebuchet`
- Pre-run action: starts or reuses a Trebuchet dev session
- Post-run action: stops the Trebuchet dev session
- Scripts in `.trebuchet-xcode/` managed by Trebuchet

Useful follow-ups:

```bash
trebuchet xcode status
trebuchet xcode teardown
```

### Auto Client Transport

Trebuchet clients can now use automatic endpoint resolution:

```swift
ContentView()
    .trebuchet(transport: .auto())
```

Resolution order:
1. `TREBUCHET_HOST` + `TREBUCHET_PORT` (when both are set)
2. fallback to `localhost:8080`

## Cloud Deployment

Deploy your System executable to the cloud with a single command:

```bash
# Preview deployment
trebuchet deploy ./Server --product AuraSystem --dry-run

# Deploy to AWS Lambda
trebuchet deploy ./Server --product AuraSystem --provider aws --region us-east-1

# Or deploy to Fly.io
trebuchet deploy ./Server --product AuraSystem --provider fly --region iad
```

### AWS Deployment (Untested)

The CLI discovers your `@Trebuchet` actors, generates Terraform, and deploys to:
- **AWS Lambda** for actor execution
- **DynamoDB** for state persistence
- **CloudMap** for service discovery

### Fly.io Deployment

For Fly.io deployments:
- **Fly Apps** for actor execution
- **PostgreSQL** for state persistence (optional)
- Auto-scaling with zero downtime

See the [Cloud Deployment Guide](https://briannadoubt.github.io/Trebuchet/documentation/trebuchet/clouddeploymentoverview) for details.

## Documentation

Full documentation is available at **[briannadoubt.github.io/Trebuchet](https://briannadoubt.github.io/Trebuchet/documentation/trebuchet/)**.

## Requirements

- Swift 6.2+
- macOS 14+ / iOS 17+ / tvOS 17+ / watchOS 10+

## License

MIT
