# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# Build the package
swift build

# Build the CLI tool
swift build --product trebuche

# Run tests
swift test

# Run a specific test
swift test --filter TrebucheTests.testName

# Run CLI tests
swift test --filter TrebucheCLITests

# Run AWS tests
swift test --filter TrebucheAWSTests
```

## CLI Commands

```bash
# Initialize a new trebuche.yaml configuration
trebuche init --name my-project --provider aws

# Deploy actors to AWS Lambda
trebuche deploy --provider aws --region us-east-1

# Deploy with dry-run to preview changes
trebuche deploy --dry-run --verbose

# Check deployment status
trebuche status

# Remove deployed infrastructure
trebuche undeploy

# Run actors locally for development
trebuche dev --port 8080
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
│   ├── Serialization.swift         # Encoder/Decoder/ResultHandler for wire format
│   └── StreamRegistry.swift        # Client-side stream state management
├── Transport/
│   ├── Transport.swift             # Transport protocol, Endpoint, TransportMessage
│   └── WebSocket/
│       └── WebSocketTransport.swift # WebSocket implementation using swift-nio
├── Server/
│   └── TrebuchetServer.swift       # Server API for hosting actors, stream buffering
├── Client/
│   └── TrebuchetClient.swift       # Client API for resolving remote actors
└── SwiftUI/
    ├── ConnectionState.swift       # Connection state enum, ReconnectionPolicy
    ├── TrebuchetConnection.swift   # @Observable connection wrapper
    ├── TrebuchetConnectionManager.swift # Multi-server manager
    ├── TrebuchetEnvironment.swift  # SwiftUI environment integration
    ├── TrebuchetViewModifiers.swift # View modifiers
    ├── RemoteActorWrapper.swift    # @RemoteActor property wrapper
    └── ObservedActor.swift         # @ObservedActor for streaming state

Sources/TrebucheMacros/
└── TrebucheMacros.swift            # @Trebuchet and @StreamedState macros

Sources/TrebucheCloud/
├── TrebucheCloud.swift             # Module exports
├── Gateway/
│   ├── CloudGateway.swift          # HTTP gateway for cloud environments
│   └── HTTPTransport.swift         # HTTP-based transport
├── Providers/
│   ├── CloudProvider.swift         # CloudProvider protocol, CloudProviderType enum
│   └── LocalProvider.swift         # Local development provider
├── Discovery/
│   └── ServiceRegistry.swift       # ServiceRegistry protocol, CloudEndpoint
└── State/
    └── ActorStateStore.swift       # ActorStateStore protocol, StatefulActor

Sources/TrebucheAWS/
├── TrebucheAWS.swift               # Module exports and documentation
├── AWSProvider.swift               # CloudProvider implementation for AWS Lambda
├── DynamoDBStateStore.swift        # ActorStateStore using DynamoDB
├── CloudMapRegistry.swift          # ServiceRegistry using AWS Cloud Map
├── LambdaTransport.swift           # Transport for Lambda invocations
└── CloudClient.swift               # Client for actor-to-actor calls across Lambda

Sources/TrebucheCLI/
├── main.swift                      # CLI entry point
├── Commands/
│   ├── DeployCommand.swift         # Deploy actors to cloud
│   ├── StatusCommand.swift         # Check deployment status
│   ├── UndeployCommand.swift       # Remove infrastructure
│   ├── DevCommand.swift            # Local development server
│   └── InitCommand.swift           # Initialize configuration
├── Config/
│   ├── TrebucheConfig.swift        # Configuration model (trebuche.yaml)
│   └── ConfigLoader.swift          # YAML parsing and resolution
├── Discovery/
│   ├── ActorMetadata.swift         # Actor/method metadata types
│   └── ActorDiscovery.swift        # SwiftSyntax-based actor discovery
├── Build/
│   ├── DockerBuilder.swift         # Docker-based Lambda builds
│   └── BootstrapGenerator.swift    # Lambda bootstrap code generation
├── Terraform/
│   └── TerraformGenerator.swift    # AWS Terraform configuration generation
└── Utilities/
    └── Terminal.swift              # Terminal output styling
```

### Key Types

- **TrebuchetActorSystem**: Core `DistributedActorSystem` conformance
- **TrebuchetActorID**: Identifies actors (local or remote with host:port)
- **TrebuchetServer/TrebuchetClient**: High-level API for exposing and resolving actors
- **TrebuchetTransport**: Protocol for pluggable network transports
- **@Trebuchet macro**: Adds `typealias ActorSystem = TrebuchetActorSystem` to distributed actors

#### Streaming Types

- **@StreamedState macro**: Property wrapper that automatically notifies subscribers on changes
- **StreamRegistry**: Client-side actor managing incoming stream state and continuations
- **ServerStreamBuffer**: Server-side actor buffering outgoing stream data for resumption
- **StreamingMethod enum**: Auto-generated type-safe enum for streaming methods
- **Stream envelopes**: StreamStartEnvelope, StreamDataEnvelope, StreamEndEnvelope, StreamErrorEnvelope, StreamResumeEnvelope

#### SwiftUI Types

- **TrebuchetConnection**: Observable connection wrapper with auto-reconnection
- **TrebuchetConnectionManager**: Multi-server connection orchestrator
- **TrebuchetEnvironment**: SwiftUI environment container view
- **@RemoteActor**: Property wrapper for automatic actor resolution
- **@ObservedActor**: Property wrapper for streaming state with automatic view updates
- **ConnectionState**: Connection lifecycle state enum

#### Cloud Types (TrebucheCloud)

- **CloudGateway**: HTTP gateway for hosting actors in cloud environments
- **CloudProvider**: Protocol for cloud provider implementations (AWS, GCP, Azure)
- **ServiceRegistry**: Protocol for actor discovery (CloudMap, etc.)
- **ActorStateStore**: Protocol for external state storage (DynamoDB, etc.)
- **CloudEndpoint**: Represents cloud-native endpoints (Lambda ARNs, etc.)
- **StatefulActor**: Protocol for actors with persistent state

#### AWS Types (TrebucheAWS)

- **AWSProvider**: CloudProvider implementation for AWS Lambda
- **DynamoDBStateStore**: ActorStateStore using AWS DynamoDB
- **CloudMapRegistry**: ServiceRegistry using AWS Cloud Map
- **LambdaInvokeTransport**: Transport for direct Lambda invocations
- **TrebucheCloudClient**: Client for actor-to-actor calls across Lambda
- **LambdaEventAdapter**: Converts API Gateway events to/from InvocationEnvelope

#### CLI Types (TrebucheCLI)

- **TrebucheConfig**: Configuration model parsed from trebuche.yaml
- **ActorDiscovery**: SwiftSyntax-based scanner for @Trebuchet actors
- **ActorMetadata**: Metadata about discovered actors and their methods
- **DockerBuilder**: Builds Swift projects for Lambda (arm64)
- **TerraformGenerator**: Generates AWS infrastructure as Terraform

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

### SwiftUI Usage Pattern

```swift
// App setup with .trebuche() modifier
@main
struct GameApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .trebuche(transport: .webSocket(host: "game.example.com", port: 8080))
        }
    }
}

// Using @RemoteActor in views
struct LobbyView: View {
    @RemoteActor(id: "lobby") var lobby: GameLobby?

    var body: some View {
        switch $lobby.state {
        case .loading: ProgressView()
        case .resolved(let lobby): LobbyContent(lobby: lobby)
        case .failed(let error): ErrorView(error: error)
        case .disconnected: Text("Offline")
        }
    }
}
```

### Cloud Deployment Pattern

```yaml
# trebuche.yaml
name: my-game-server
version: "1"

defaults:
  provider: aws
  region: us-east-1
  memory: 512
  timeout: 30

actors:
  GameRoom:
    memory: 1024
    stateful: true
  Lobby:
    memory: 256

state:
  type: dynamodb

discovery:
  type: cloudmap
  namespace: my-game
```

```bash
# Deploy to AWS
$ trebuche deploy --provider aws

Discovering actors...
  ✓ GameRoom
  ✓ Lobby

Building for Lambda (arm64)...
  ✓ Package built (14.2 MB)

Deploying to AWS...
  ✓ Lambda: arn:aws:lambda:us-east-1:123:function:my-game-actors
  ✓ API Gateway: https://abc123.execute-api.us-east-1.amazonaws.com
  ✓ DynamoDB: my-game-actor-state
  ✓ CloudMap: my-game namespace

Ready! Actors can discover each other automatically.
```

### Lambda Bootstrap Pattern

```swift
// Auto-generated by trebuche CLI
@main
struct ActorLambdaHandler: LambdaHandler {
    let gateway: CloudGateway

    init(context: LambdaInitializationContext) async throws {
        let stateStore = DynamoDBStateStore(tableName: env("STATE_TABLE"))
        let registry = CloudMapRegistry(namespace: env("NAMESPACE"))

        gateway = CloudGateway(configuration: .init(
            stateStore: stateStore,
            registry: registry
        ))

        // Register actors
        try await gateway.expose(GameRoom(actorSystem: gateway.system), as: "game-room")
        try await gateway.expose(Lobby(actorSystem: gateway.system), as: "lobby")
    }

    func handle(_ event: APIGatewayV2Request, context: LambdaContext) async throws -> APIGatewayV2Response {
        let envelope = try LambdaEventAdapter.fromAPIGateway(event)
        let response = await gateway.handleInvocation(envelope)
        return try LambdaEventAdapter.toAPIGatewayResponse(response)
    }
}
```

### Actor-to-Actor Calls (Cross-Lambda)

```swift
// From within an actor running in Lambda
let client = TrebucheCloudClient.aws(region: "us-east-1", namespace: "my-game")
let lobby = try await client.resolve(Lobby.self, id: "lobby")
let players = try await lobby.getPlayers()  // Invokes another Lambda
```

### Dependencies

- **swift-nio**: Cross-platform networking
- **swift-nio-ssl**: TLS support
- **swift-nio-transport-services**: Network.framework integration
- **websocket-kit**: WebSocket support
- **swift-syntax**: Macro implementation and actor discovery
- **swift-argument-parser**: CLI argument parsing
- **Yams**: YAML configuration parsing

### Tests

Tests use Swift Testing framework (`import Testing`). Run with `swift test`.

Test suites:
- `TrebucheTests`: Core actor system, serialization, client-server
- `TrebucheCloudTests`: Cloud gateway, providers, state stores, registries
- `TrebucheAWSTests`: AWS-specific implementations
- `TrebucheCLITests`: CLI configuration, discovery, build system
