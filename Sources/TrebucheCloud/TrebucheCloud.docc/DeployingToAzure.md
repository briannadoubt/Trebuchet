# Deploying to Microsoft Azure

Deploy your distributed actors to Azure Functions with Cosmos DB and Service Fabric.

## Overview

> Note: Azure support is planned for a future release. This document describes the intended architecture.

Trebuche will support deployment to Microsoft Azure using:
- **Azure Functions** for actor execution
- **Cosmos DB** for actor state persistence
- **Azure Service Fabric** or **Azure Service Bus** for actor discovery

## Planned Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                      Microsoft Azure                             │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │              Azure Functions                             │   │
│  │  ┌─────────────┐    ┌─────────────┐    ┌────────────┐  │   │
│  │  │ UserService │    │  GameRoom   │    │   Lobby    │  │   │
│  │  └─────────────┘    └─────────────┘    └────────────┘  │   │
│  └─────────────────────────────────────────────────────────┘   │
│                              ↓                                  │
│  ┌──────────────┐  ┌──────────────────┐  ┌────────────────┐   │
│  │  Cosmos DB   │  │  Service Fabric   │  │ API Management │   │
│  │ (actor state)│  │   (discovery)     │  │  (endpoint)    │   │
│  └──────────────┘  └──────────────────┘  └────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

## Planned Configuration

```yaml
name: my-game-server
version: "1"

defaults:
  provider: azure
  region: eastus
  memory: 512
  timeout: 30

actors:
  GameRoom:
    memory: 1024
    stateful: true

state:
  type: cosmosdb
  database: trebuche
  container: actor-state

discovery:
  type: service-fabric
  cluster: my-cluster
```

## Planned Usage

```bash
# Deploy to Azure
trebuche deploy --provider azure --region eastus

# Expected output
Discovering actors...
  ✓ GameRoom
  ✓ Lobby

Building for Azure Functions...
  ✓ Package built

Deploying to Azure...
  ✓ Function App: my-game-actors
  ✓ Function URL: https://my-game-actors.azurewebsites.net
  ✓ Cosmos DB: trebuche/actor-state
  ✓ Service Fabric: my-cluster/my-game

Ready!
```

## Azure-Specific Components

### CosmosDBStateStore (Planned)

```swift
// Future implementation
let stateStore = CosmosDBStateStore(
    endpoint: "https://my-cosmos.documents.azure.com",
    database: "trebuche",
    container: "actor-state"
)
```

### ServiceFabricRegistry (Planned)

```swift
// Future implementation
let registry = ServiceFabricRegistry(
    clusterEndpoint: "https://my-cluster.eastus.cloudapp.azure.com",
    applicationName: "my-game"
)
```

### AzureFunctionTransport (Planned)

```swift
// Future implementation
let transport = AzureFunctionTransport(
    functionUrl: "https://my-game-actors.azurewebsites.net/api/invoke"
)
```

## Authentication

Azure authentication will use Azure Identity:

```bash
# Local development
az login

# Service principal
export AZURE_CLIENT_ID=...
export AZURE_CLIENT_SECRET=...
export AZURE_TENANT_ID=...
```

## Cost Considerations

Azure Functions pricing (Consumption plan):
- **Executions**: $0.20 per million
- **Resource consumption**: $0.000016 per GB-second

Cosmos DB pricing (Serverless):
- **Request Units**: $0.25 per million RUs

## Alternative: Azure Container Apps

For longer-running actors, Azure Container Apps may be preferred:

```yaml
defaults:
  provider: azure
  runtime: container-apps  # Instead of functions
```

## Contributing

Azure support contributions are welcome! See the TrebucheCloud protocols:
- ``CloudProvider``
- ``ActorStateStore``
- ``ServiceRegistry``

## See Also

- <doc:CloudDeploymentOverview>
- <doc:DeployingToAWS>
- <doc:DeployingToGCP>
