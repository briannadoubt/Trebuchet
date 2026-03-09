# Cloud Deployment Overview

Learn how Trebuchet enables serverless deployment of distributed actors.

## Overview

TrebuchetCloud provides the abstractions needed to deploy Swift distributed actors to serverless platforms. Instead of running a persistent server, your actors execute on-demand in response to invocations.

## Architecture

```
┌───────────────────────────────────────────────────────────────┐
│                      Cloud Environment                        │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │              CloudGateway                               │  │
│  │  ┌─────────────┐    ┌─────────────┐    ┌────────────┐   │  │
│  │  │ UserService │    │  GameRoom   │    │   Lobby    │   │  │
│  │  └─────────────┘    └─────────────┘    └────────────┘   │  │
│  └─────────────────────────────────────────────────────────┘  │
│                              ↓                                │
│  ┌──────────────┐  ┌──────────────┐  ┌───────────────────┐    │
│  │  StateStore  │  │   Registry   │  │   HTTP Endpoint   │    │
│  │  (SQLite*)   │  │  (CloudMap)  │  │  (API Gateway)    │    │
│  └──────────────┘  └──────────────┘  └───────────────────┘    │
└───────────────────────────────────────────────────────────────┘
```

## Key Components

### CloudGateway

The `CloudGateway` is the entry point for hosting actors in cloud environments. It handles:
- Actor registration and exposure
- Incoming invocation routing
- State persistence coordination
- Service registry integration

```swift
let gateway = CloudGateway(configuration: .init(
    host: "0.0.0.0",
    port: 8080,
    stateStore: myStateStore,
    registry: myRegistry
))

try await gateway.expose(myActor, as: "my-actor")
try await gateway.run()
```

### CloudProvider

The `CloudProvider` protocol abstracts cloud platform specifics:

```swift
public protocol CloudProvider: Sendable {
    associatedtype FunctionConfig: Sendable
    associatedtype DeploymentResult: CloudDeployment

    func deploy<A: DistributedActor>(
        _ actorType: A.Type,
        as actorID: String,
        config: FunctionConfig,
        factory: @Sendable (TrebuchetRuntime) -> A
    ) async throws -> DeploymentResult

    func transport(for deployment: DeploymentResult) async throws -> any TrebuchetTransport
}
```

### ServiceRegistry

The `ServiceRegistry` protocol enables actor discovery:

```swift
public protocol ServiceRegistry: Sendable {
    func register(actorID: String, endpoint: CloudEndpoint, metadata: [String: String], ttl: Duration?) async throws
    func resolve(actorID: String) async throws -> CloudEndpoint?
    func deregister(actorID: String) async throws
}
```

### ActorStateStore

The `ActorStateStore` protocol provides state persistence:

```swift
public protocol ActorStateStore: Sendable {
    func load<State: Codable & Sendable>(for actorID: String, as type: State.Type) async throws -> State?
    func save<State: Codable & Sendable>(_ state: State, for actorID: String) async throws
    func delete(for actorID: String) async throws
}
```

## State Store Options

SQLite is the recommended state store for most deployments. It requires no external services, works with persistent volumes on platforms like Fly.io, and provides full ACID guarantees:

```swift
import TrebuchetSQLite

let stateStore = try SQLiteStateStore(path: "/data/trebuchet.db")
let gateway = CloudGateway(configuration: .init(
    host: "0.0.0.0",
    port: 8080,
    stateStore: stateStore,
    registry: myRegistry
))
```

For deployments that need a shared external database (e.g., multi-instance with shared state), use DynamoDB or PostgreSQL instead.

*\* SQLite is the recommended default. DynamoDB and PostgreSQL are available as alternatives for specialized needs.*

## Local Development

For local development, use the in-memory implementations:

```swift
let gateway = CloudGateway.development(host: "localhost", port: 8080)
```

This creates a gateway with `InMemoryStateStore` and `InMemoryRegistry`.

## See Also

- <doc:DeployingToAWS>
- <doc:DeployingToGCP>
- <doc:DeployingToAzure>
