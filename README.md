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

The `trebuchet` CLI enables cloud deployment and local development. You can use it in three ways:

#### Swift Package Plugin (Recommended for Projects)

Add Trebuchet as a dependency in your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/briannadoubt/Trebuchet.git", from: "1.0.0")
]
```

Then use the plugin from the command line:

```bash
# Initialize configuration
swift package plugin --allow-writing-to-package-directory trebuchet init

# Deploy to cloud
swift package plugin --allow-writing-to-package-directory --allow-network-connections all trebuchet deploy

# Run locally
swift package plugin --allow-writing-to-package-directory trebuchet dev
```

Or in **Xcode**:
1. Add Trebuchet package dependency to your Xcode project
2. Right-click on your project in the navigator
3. Select **Trebuchet** from the plugin menu
4. Choose a subcommand (init, deploy, dev, etc.)

#### Mint (Recommended for Global Installation)

```bash
mint install briannadoubt/Trebuchet
trebuchet deploy --provider aws
```

#### Build from Source

```bash
git clone https://github.com/briannadoubt/Trebuchet.git
cd Trebuchet
swift build -c release
cp .build/release/trebuchet /usr/local/bin/trebuchet
```

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

Run your actors locally with automatic discovery and hot reload:

```bash
# Start local development server
trebuchet dev --port 8080

# Customize host and port
trebuchet dev --host 0.0.0.0 --port 3000

# Enable verbose output
trebuchet dev --verbose
```

The `dev` command:
- Discovers all `@Trebuchet` actors in your project
- **Works with both Swift Package Manager and Xcode projects**
- Automatically analyzes and copies type dependencies
- Builds and runs a local HTTP server
- Exposes actors at `http://localhost:8080/invoke`
- Provides health check at `http://localhost:8080/health`

## Xcode Project Support

Trebuchet CLI now fully supports Xcode projects with **automatic dependency analysis**:

```bash
cd /path/to/YourXcodeProject
trebuchet dev --verbose

# Output:
# Detected Xcode project, will copy actor sources...
# Found actors:
#   • GameRoom
# Analyzing dependencies...
# Found 4 required file(s)
# ✓ Copied 4 source files (including dependencies)
# Starting server on localhost:8080...
```

### How It Works

The CLI automatically:
1. **Detects** `.xcodeproj` or `.xcworkspace` files
2. **Analyzes** actor method signatures to extract types
3. **Discovers** all type dependencies recursively
4. **Copies** only the files you need (no cascade to unrelated code)
5. **Generates** a standalone server package

### Features

✅ **Zero configuration** - Just run `trebuchet dev` in any Xcode project
✅ **Smart dependency tracking** - Finds all types your actors use
✅ **Cascade prevention** - Doesn't copy your entire app
✅ **Works everywhere** - `dev`, `generate server`, `deploy` commands

### Example

```swift
// Your Xcode project
@Trebuchet
distributed actor GameRoom {
    distributed func join(player: PlayerInfo) -> RoomState
}

// Automatically discovers and copies:
// - GameRoom.swift
// - PlayerInfo.swift (used in signature)
// - RoomState.swift (used in signature)
// - GameStatus.swift (used by RoomState)
// And nothing else!
```

See **[Xcode Project Support](Sources/Trebuchet/Trebuchet.docc/XCODE_PROJECT_SUPPORT.md)** for detailed documentation.

## Cloud Deployment

Deploy your actors to the cloud with a single command:

```bash
# Initialize configuration
trebuchet init --name my-game-server --provider aws

# Preview deployment
trebuchet deploy --dry-run

# Deploy to AWS Lambda
trebuchet deploy --provider aws --region us-east-1

# Or deploy to Fly.io
trebuchet deploy --provider fly --region iad
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
