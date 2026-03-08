# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

# Critical Behavior

- Use as many subagents as you can in order to efficiently use your context window. Have them write code, run commands, all that.
- Whenever you plan a task, make sure that you take parallelizing the work into account and mark the plan as such so that you can easily parallelize the work effectively and identify bottlenecks in the implementation.
- When running subagents, only let one at a time run tests or builds so that these processes don't collide, but feel free to write documentation, identify bugs, analyze potential security risks, or other read-only sessions while building or testing. Just be sure to not let other sub agents corrupt the build or tests.
- Don't fire off a background task and sleep. Use the blocking task to watch it if you need to.
- When CI fails, fix it and use `gh run watch` to watch the logs of the CI to confirm that it was fixed. 

## Debugging CI Failures

**CRITICAL: Never guess when debugging CI failures.**

When CI tests fail:
1. **DO NOT guess** what the error might be
2. **DO NOT make speculative fixes** without seeing actual error logs
3. **ALWAYS ask the user** to provide the specific error message from the CI logs
4. **CHECK for actual error details** before proposing solutions using the `gh` CLI tool.

Example response to CI failure:
```
I see the CI failed. To fix this properly, I need to see the actual error from the logs.
```
‰
**Only after seeing the actual error** should you propose a fix based on the specific failure.

## Task Management and Monitoring

**CRITICAL: Use proper task management tools instead of sleep.**

When running and monitoring long-running processes (like dev servers):

### DO NOT:
- Use `sleep` commands to wait for processes
- Poll files repeatedly with tail commands
- Run commands in foreground and block execution

### DO:
- Use `run_in_background: true` parameter for Bash commands
- Use `TaskOutput` tool to check on background tasks without blocking
- Use Task tool to delegate work to specialized agents
- Monitor task progress through the task output files
- Let background tasks run while continuing other work

### Example Pattern:
```swift
// Start server in background
Bash(command: "start-server", run_in_background: true)
// Returns immediately with task_id

// Continue other work...

// Check on it later (non-blocking)
TaskOutput(task_id: "abc123", block: false)

// Or wait for completion when needed
TaskOutput(task_id: "abc123", block: true, timeout: 60000)
```

### Delegation with Task Tool:
- Use Task tool with appropriate subagent_type for complex workflows
- Agents can run in parallel when using multiple Task calls in one message
- Each agent has access to specific tools based on its role
- Use `run_in_background: true` for agents that take time

For detailed information on task management, subtasks, and agent delegation patterns, consult the claude-code-guide agent.

## Xcode Project Support

Trebuchet CLI supports Xcode app workflows that run a System executable from a Swift package.

### Automatic Detection
- Detects `.xcodeproj` or `.xcworkspace` files
- Generates managed pre/post Run scripts in `.trebuchet-xcode`
- Runs `xcode session start` with `--system-path` and `--product`

### Automatic Dependency Analysis
- Uses SwiftSyntax to analyze actor method signatures
- Extracts all parameter and return types
- Recursively discovers transitive dependencies
- Prevents cascade through unrelated types (symbol-scoped analysis)

### Documentation
- `XCODE_PROJECT_SUPPORT.md` - User guide and feature overview
- `DEPENDENCY_ANALYSIS.md` - How dependency analysis works
- `CASCADE_PREVENTION.md` - Cascade prevention strategy
- `COMPLEXITY_COMPARISON.md` - File-level vs symbol-level analysis
- `SYMBOL_LEVEL_EXTRACTION.md` - Future enhancement design

### Key Files
- `Sources/TrebuchetCLI/Utilities/ProjectDetector.swift` - Project detection
- `Sources/TrebuchetCLI/Discovery/DependencyAnalyzer.swift` - Dependency analysis

## Build Commands

```bash
# Build the package
swift build

# Build the CLI tool
swift build --product trebuchet

# Run tests
swift test

# Run a specific test
swift test --filter TrebuchetTests.testName

# Run CLI tests
swift test --filter TrebuchetCLITests

# Run AWS tests (unit tests only - use mocks)
swift test --filter TrebuchetAWSTests

# Run AWS integration tests with LocalStack
docker-compose -f docker-compose.localstack.yml up -d
swift test --filter TrebuchetAWSTests
docker-compose -f docker-compose.localstack.yml down -v

# Run SurrealDB tests
docker-compose -f docker-compose.surrealdb.yml up -d
swift test --filter TrebuchetSurrealDBTests
docker-compose -f docker-compose.surrealdb.yml down -v
```

## Running LocalStack Integration Tests

### Prerequisites
- Docker and Docker Compose
- LocalStack 3.0 (started via docker-compose)

### Start LocalStack
```bash
# Start LocalStack with all AWS services
docker-compose -f docker-compose.localstack.yml up -d

# Verify LocalStack is healthy
curl http://localhost:4566/_localstack/health

# Init scripts run automatically to create:
# - DynamoDB tables (trebuchet-test-state, trebuchet-test-connections)
# - Cloud Map namespace (trebuchet-test)
# - IAM roles (trebuchet-test-lambda-role)
```

### Run Integration Tests
```bash
# All AWS integration tests
swift test --filter TrebuchetAWSTests

# Specific integration suite
swift test --filter DynamoDBStateStoreIntegrationTests
swift test --filter CloudMapRegistryIntegrationTests
swift test --filter AWSIntegrationWorkflowTests
```

### Cleanup
```bash
docker-compose -f docker-compose.localstack.yml down -v
```

### Test Architecture
Integration tests use Swift Testing framework with:
- Graceful skipping when LocalStack unavailable (availability checks in test init)
- Automatic test isolation via unique actor IDs
- Cleanup in defer blocks to prevent resource leaks
- LocalStack service simulation for 6 AWS services:
  - Lambda - function deployment/invocation
  - DynamoDB - actor state persistence
  - DynamoDB Streams - real-time state broadcasting
  - Cloud Map - service discovery
  - IAM - role management
  - API Gateway WebSocket - connection management

For detailed troubleshooting and LocalStack limitations, see [Tests/TrebuchetAWSTests/README.md](Tests/TrebuchetAWSTests/README.md).

## Running SurrealDB Integration Tests

### Prerequisites
- Docker and Docker Compose
- SurrealDB (started via docker-compose)

### Start SurrealDB
```bash
# Start SurrealDB container
docker-compose -f docker-compose.surrealdb.yml up -d

# Verify SurrealDB is healthy
curl http://localhost:8000/health

# The container provides:
# - HTTP/WebSocket endpoint at localhost:8000
# - Root credentials (root/root)
# - Memory storage mode for tests
# - Trace logging enabled
```

### Run Integration Tests
```bash
# All SurrealDB integration tests
swift test --filter TrebuchetSurrealDBTests

# Specific integration suite
swift test --filter SurrealDBStateStoreTests
swift test --filter SurrealDBIntegrationTests
```

### Cleanup
```bash
docker-compose -f docker-compose.surrealdb.yml down -v
```

### Test Architecture
Integration tests use Swift Testing framework with:
- Graceful skipping when SurrealDB unavailable (availability checks in test init)
- Automatic test isolation via unique actor IDs
- Explicit async cleanup at end of tests (await ensures proper resource cleanup even on early exit)
- SurrealDB features tested:
  - ActorStateStore implementation
  - ORM patterns with SurrealModel
  - Schema auto-generation
  - Type-safe queries with KeyPath syntax
  - Graph relationships with EdgeModel
  - Concurrent operations and version conflict handling

## CLI Commands

```bash
# Run a System executable package locally
trebuchet dev ./Server --product AuraSystem

# Deploy to Fly.io
trebuchet deploy ./Server --product AuraSystem --provider fly --region iad

# Deploy with dry-run to preview changes
trebuchet deploy ./Server --product AuraSystem --dry-run --verbose

# Check deployment status
trebuchet status

# Remove deployed infrastructure
trebuchet undeploy

# Set up managed Xcode session scripts
trebuchet xcode setup --project-path /path/to/App --system-path /path/to/App/Server --product AuraSystem

# Diagnose legacy artifacts and migration state
trebuchet doctor
```

## Architecture

Trebuchet is a Swift 6.2 location-transparent distributed actor framework that makes RPC stupid simple.

### Core Components

```
Sources/Trebuchet/
├── Trebuchet.swift              # Main entry, @Trebuchet macro declaration
├── ActorSystem/
│   ├── TrebuchetActorSystem.swift  # DistributedActorSystem implementation
│   ├── TrebuchetActorID.swift      # Actor identification (local/remote)
│   ├── TrebuchetError.swift        # Error types
│   ├── Serialization.swift         # Encoder/Decoder/ResultHandler for wire format
│   └── StreamRegistry.swift        # Client-side stream state management
├── Transport/
│   ├── Transport.swift             # Transport protocol, Endpoint, TransportMessage
│   ├── WebSocket/
│   │   └── WebSocketTransport.swift # WebSocket implementation using swift-nio
│   └── TCP/
│       └── TCPTransport.swift      # TCP implementation with length-prefixed framing
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

Sources/TrebuchetMacros/
└── TrebuchetMacros.swift            # @Trebuchet and @StreamedState macros

Sources/TrebuchetCloud/
├── TrebuchetCloud.swift             # Module exports
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

Sources/TrebuchetAWS/
├── TrebuchetAWS.swift               # Module exports and documentation
├── AWSProvider.swift               # CloudProvider implementation for AWS Lambda
├── DynamoDBStateStore.swift        # ActorStateStore using DynamoDB
├── CloudMapRegistry.swift          # ServiceRegistry using AWS Cloud Map
├── LambdaTransport.swift           # Transport for Lambda invocations
└── CloudClient.swift               # Client for actor-to-actor calls across Lambda

Sources/TrebuchetCLI/
├── TrebuchetCLICore.swift          # CLI entry point (@main)
├── Commands/
│   ├── DeployCommand.swift         # Deploy System packages to cloud
│   ├── StatusCommand.swift         # Check deployment status
│   ├── UndeployCommand.swift       # Remove infrastructure
│   ├── DevCommand.swift            # Local System-package development server
│   ├── XcodeCommand.swift          # Xcode app + System-package integration
│   └── DoctorCommand.swift         # Migration diagnostics
├── Config/
│   ├── TrebuchetConfig.swift        # Legacy compatibility config model
│   └── ConfigLoader.swift          # Legacy config parsing helpers
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

Sources/TrebuchetSecurity/
├── TrebuchetSecurity.swift          # Module exports and documentation
├── Authentication/
│   ├── AuthenticationProvider.swift # Authentication protocol
│   ├── APIKeyAuthenticator.swift   # API key authentication
│   ├── JWTAuthenticator.swift      # JWT authentication (dev/test only)
│   └── Credentials.swift           # Credentials types, Principal
├── Authorization/
│   ├── AuthorizationPolicy.swift   # Authorization protocol
│   └── RoleBasedPolicy.swift       # RBAC implementation
├── RateLimiting/
│   ├── RateLimiter.swift           # Rate limiter protocol
│   ├── TokenBucketLimiter.swift    # Token bucket algorithm
│   └── SlidingWindowLimiter.swift  # Sliding window algorithm
└── Validation/
    └── RequestValidator.swift      # Request validation

Sources/TrebuchetObservability/
├── TrebuchetObservability.swift     # Module exports and documentation
├── Logging/
│   ├── TrebuchetLogger.swift       # Structured logger
│   ├── LogLevel.swift              # Log levels
│   ├── LogFormatter.swift          # Formatter protocol
│   ├── LogContext.swift            # Log context
│   └── Formatters/
│       ├── ConsoleFormatter.swift  # Console output formatter
│       └── JSONFormatter.swift     # JSON output formatter
├── Metrics/
│   ├── MetricsCollector.swift      # Metrics collector protocol
│   ├── InMemoryCollector.swift     # In-memory collector
│   ├── CloudWatchReporter.swift    # AWS CloudWatch reporter
│   ├── Counter.swift               # Counter metric
│   └── Histogram.swift             # Histogram metric
└── Tracing/
    ├── TraceContext.swift          # Trace context (re-export from Trebuchet)
    ├── Span.swift                  # Span types
    └── SpanExporter.swift          # Span exporter protocol

Sources/TrebuchetPostgreSQL/
├── TrebuchetPostgreSQL.swift        # Module exports and documentation
├── PostgreSQLStateStore.swift      # ActorStateStore using PostgreSQL
└── PostgreSQLStreamAdapter.swift   # LISTEN/NOTIFY for multi-instance sync

Sources/TrebuchetSurrealDB/
├── TrebuchetSurrealDB.swift         # Module exports and documentation
├── SurrealDBStateStore.swift        # ActorStateStore using SurrealDB with ORM
├── Configuration.swift              # Configuration types and environment loading
└── CloudGatewayExtensions.swift     # Gateway integration and connection pooling
```

### Key Types

- **TrebuchetActorSystem**: Core `DistributedActorSystem` conformance
- **TrebuchetActorID**: Identifies actors (local or remote with host:port)
- **TrebuchetServer/TrebuchetClient**: High-level API for exposing and resolving actors
- **TrebuchetTransport**: Protocol for pluggable network transports
  - **WebSocketTransport**: Browser-compatible, TLS support, production-ready
  - **TCPTransport**: High-performance server-to-server, length-prefixed framing, production-ready
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

#### Cloud Types (TrebuchetCloud)

- **CloudGateway**: HTTP gateway for hosting actors in cloud environments. Supports both HTTP transport (via handleMessage) and programmatic invocation (via process()) for actor-to-actor calls
- **CloudProvider**: Protocol for cloud provider implementations (AWS, GCP, Azure)
- **ServiceRegistry**: Protocol for actor discovery (CloudMap, etc.)
- **ActorStateStore**: Protocol for external state storage (DynamoDB, etc.)
- **CloudEndpoint**: Represents cloud-native endpoints (Lambda ARNs, etc.)
- **StatefulActor**: Protocol for actors with persistent state

#### AWS Types (TrebuchetAWS)

- **AWSProvider**: CloudProvider implementation for AWS Lambda
- **DynamoDBStateStore**: ActorStateStore using AWS DynamoDB
- **CloudMapRegistry**: ServiceRegistry using AWS Cloud Map
- **LambdaInvokeTransport**: Transport for direct Lambda invocations
- **TrebuchetCloudClient**: Client for actor-to-actor calls across Lambda
- **LambdaEventAdapter**: Converts API Gateway events to/from InvocationEnvelope

#### CLI Types (TrebuchetCLI)

- **TrebuchetConfig**: Legacy compatibility configuration model
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
// App setup with .trebuchet() modifier
@main
struct GameApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .trebuchet(transport: .webSocket(host: "game.example.com", port: 8080))
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

```bash
# Deploy to AWS
$ trebuchet deploy ./Server --product AuraSystem --provider aws --region us-east-1

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
// Auto-generated by trebuchet CLI
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
        let response = await gateway.process(envelope)
        return try LambdaEventAdapter.toAPIGatewayResponse(response)
    }
}
```

### Actor-to-Actor Calls (Cross-Lambda)

```swift
// From within an actor running in Lambda
let client = TrebuchetCloudClient.aws(region: "us-east-1", namespace: "my-game")
let lobby = try await client.resolve(Lobby.self, id: "lobby")
let players = try await lobby.getPlayers()  // Invokes another Lambda
```

### Dependencies

- **swift-nio**: Cross-platform networking
- **swift-nio-ssl**: TLS support
- **swift-nio-extras**: Length-prefixed frame codecs (TCP transport)
- **swift-nio-transport-services**: Network.framework integration
- **websocket-kit**: WebSocket support
- **swift-syntax**: Macro implementation and actor discovery
- **swift-argument-parser**: CLI argument parsing
- **Yams**: YAML configuration parsing
- **postgres-nio**: PostgreSQL client (TrebuchetPostgreSQL)
- **surrealdb-swift**: SurrealDB client with ORM support (TrebuchetSurrealDB)
- **swift-crypto**: Cryptographic operations (TrebuchetSecurity, TrebuchetAWS)
- **soto (AWS SDK)**: AWS service clients (Lambda, DynamoDB, IAM, CloudWatch, ServiceDiscovery, ApiGatewayManagementApi)
- **swift-macro-testing**: Macro testing utilities (TrebuchetMacrosTests)
- **swift-docc-plugin**: Documentation generation

### Tests

Tests use Swift Testing framework (`import Testing`). Run with `swift test`.

Test suites:
- `TrebuchetTests`: Core actor system, serialization, client-server
- `TrebuchetMacrosTests`: Macro expansion and code generation tests
- `TrebuchetCloudTests`: Cloud gateway, providers, state stores, registries
- `TrebuchetAWSTests`: AWS-specific implementations
- `TrebuchetCLITests`: CLI configuration, discovery, build system
- `TrebuchetSecurityTests`: Authentication, authorization, rate limiting, validation
- `TrebuchetObservabilityTests`: Logging, metrics, distributed tracing
- `TrebuchetPostgreSQLTests`: PostgreSQL state store and stream adapter
- `TrebuchetSurrealDBTests`: SurrealDB state store, ORM patterns, schema generation, graph relationships

## Release Process

This project uses semantic versioning WITHOUT the 'v' prefix.

### Creating a Release

```bash
# Tag format: MAJOR.MINOR.PATCH (no 'v' prefix)
git tag -a 0.2.3 -m "Release message here"
git push origin 0.2.3
```

### Version Pattern

- Use: `0.2.3`, `1.0.0`, `2.1.4`
- Don't use: `v0.2.3`, `v1.0.0`, `v2.1.4`

IMPORTANT: Always use semantic versioning without the 'v' prefix when creating tags.
