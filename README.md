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

Install the `trebuchet` CLI for cloud deployment:

```bash
# Using Mint (recommended)
mint install briannadoubt/Trebuchet

# Or build from source
git clone https://github.com/briannadoubt/Trebuchet.git
cd Trebuchet
swift build -c release
cp .build/release/trebuchet /usr/local/bin/
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
- Builds and runs a local HTTP server
- Exposes actors at `http://localhost:8080/invoke`
- Provides health check at `http://localhost:8080/health`

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

### AWS Deployment

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
