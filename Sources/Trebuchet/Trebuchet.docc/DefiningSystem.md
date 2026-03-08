# Defining a System

Learn how to declare a topology of distributed actors using the System DSL and deploy it with `trebuchet dev` or `trebuchet deploy`.

## Overview

A `System` is the top-level entry point for a Trebuchet server executable. It declares which actors to expose and how to deploy them. The CLI tools work exclusively with `System`-conforming executables, so every server package needs one.

```swift
import Trebuchet

@main
struct AuraSystem: System {
    var topology: some Topology {
        GameRoom.self
        Lobby.self
    }
}
```

Running this with `trebuchet dev ./Server --product AuraSystem` starts all declared actors locally on the default port.

## Defining the Topology

The `topology` property is annotated with `@TopologyBuilder`, so you can list actor types and attach metadata modifiers in a declarative style.

### Exposing an Actor Under a Custom Name

By default an actor is exposed using the type name. Use `.expose(as:)` to assign a different endpoint name:

```swift
var topology: some Topology {
    GameRoom.self.expose(as: "game-room")
    Lobby.self.expose(as: "lobby")
}
```

### Grouping Actors into Clusters

``Cluster`` lets you namespace a group of actors together. The cluster name appears in deployment descriptors and can be targeted by deployment overrides:

```swift
var topology: some Topology {
    Cluster("game") {
        GameRoom.self
        Lobby.self
    }
    Cluster("admin") {
        AdminDashboard.self
    }
}
```

### Attaching State, Network, and Secret Configuration

Modifiers on individual actor entries control how they are provisioned:

```swift
var topology: some Topology {
    GameRoom.self
        .state(.dynamodb(table: "game-rooms"))
        .network(.vpc(id: "vpc-abc123"))
        .secrets(["GAME_SECRET_KEY"])
}
```

## Customising Deployments

The optional `deployments` property provides a `@DeploymentsBuilder` block with provider-specific hints. Hints declared here are merged with inline `.deploy(_:)` modifiers on actor entries; inline hints take precedence on conflicts.

```swift
@main
struct AuraSystem: System {
    var topology: some Topology {
        GameRoom.self
        Lobby.self
    }

    var deployments: some Deployments {
        // Apply a memory setting to all actors when deploying to AWS
        All.deploy(.aws(lambda: .init(memory: 512)))

        // Override memory for GameRoom only
        Actor("GameRoom").deploy(.aws(lambda: .init(memory: 1024)))

        // Environment-specific overrides
        Environment("production") {
            All.deploy(.aws(region: "us-east-1"))
        }
    }
}
```

### Deployment Selectors

| Selector | Targets |
|---|---|
| `All` | Every actor in the system |
| `Actor("Name")` | The actor with matching type name or expose name |
| `ClusterSelector("Name")` | All actors inside the named cluster |

## Running Locally

```bash
trebuchet dev ./Server --product AuraSystem
```

`trebuchet dev` builds your System executable and starts it in development mode. It injects `TREBUCHET_HOST` and `TREBUCHET_PORT` into the process environment, allowing clients configured with `.auto()` transport to connect automatically.

## Deploying to the Cloud

```bash
trebuchet deploy ./Server --product AuraSystem --provider fly --region iad
```

The deploy command calls `System.deploymentPlan(provider:environment:)` at build time to determine per-actor resource requirements before provisioning infrastructure.

## Topics

### System Entry Point

- ``System``
- ``Topology``

### Topology Builders

- ``TopologyBuilder``
- ``AnyTopology``
- ``Cluster``

### Deployment DSL

- ``Deployments``
- ``DeploymentsBuilder``
- ``DeploymentEnvironment``
- ``DeploymentHint``
- ``DeploymentOverride``
- ``DeploymentRule``
- ``DeploymentSelector``
