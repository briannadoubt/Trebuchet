# ``TrebucheCloud``

Cloud-native abstractions for deploying distributed actors to serverless environments.

## Overview

TrebucheCloud provides the protocols and abstractions needed to deploy Trebuche actors to cloud platforms like AWS Lambda, Google Cloud Functions, and Azure Functions.

The module defines three key protocols:
- **CloudProvider**: Abstracts cloud platform deployment and invocation
- **ServiceRegistry**: Enables actor discovery across cloud functions
- **ActorStateStore**: Provides external state storage for stateless compute

## Topics

### Essentials

- <doc:CloudDeploymentOverview>

### Gateway

- ``CloudGateway``
- ``LambdaContext``
- ``LambdaEventHandler``

### Cloud Providers

- ``CloudProvider``
- ``CloudProviderType``
- ``CloudDeployment``
- ``DeploymentStatus``
- ``FunctionConfiguration``

### Service Discovery

- ``ServiceRegistry``
- ``CloudEndpoint``
- ``EndpointScheme``
- ``RegistryEvent``
- ``InMemoryRegistry``

### State Storage

- ``ActorStateStore``
- ``StatefulActor``
- ``StateStoreOptions``
- ``ConsistencyLevel``
- ``StateSnapshot``
- ``InMemoryStateStore``

### Errors

- ``CloudError``
