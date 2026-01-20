# TrebucheCloud Module

Cloud-native abstractions for deploying distributed actors to serverless environments.

## Overview

TrebucheCloud provides the protocols and abstractions needed to deploy Trebuche actors to cloud platforms like AWS Lambda, Google Cloud Functions, and Azure Functions.

The module defines three key protocols:
- **CloudProvider**: Abstracts cloud platform deployment and invocation
- **ServiceRegistry**: Enables actor discovery across cloud functions
- **ActorStateStore**: Provides external state storage for stateless compute

## Gateway

- `CloudGateway` - Entry point for hosting actors in cloud environments
- `LambdaContext` - Context for Lambda function execution
- `LambdaEventHandler` - Handler for Lambda events

## Cloud Providers

- `CloudProvider` - Protocol for cloud platform abstraction
- `CloudProviderType` - Enum of supported cloud providers (AWS, GCP, Azure)
- `CloudDeployment` - Deployment result information
- `DeploymentStatus` - Status of a deployment
- `FunctionConfiguration` - Configuration for serverless functions

## Service Discovery

- `ServiceRegistry` - Protocol for actor discovery
- `CloudEndpoint` - Endpoint information for cloud services
- `EndpointScheme` - URL scheme (http, https)
- `RegistryEvent` - Events from the registry
- `InMemoryRegistry` - In-memory implementation for testing

## State Storage

- `ActorStateStore` - Protocol for state persistence
- `StatefulActor` - Protocol for actors with persistent state
- `StateStoreOptions` - Options for state operations
- `ConsistencyLevel` - Consistency guarantees (eventual, strong)
- `StateSnapshot` - Point-in-time state snapshot
- `InMemoryStateStore` - In-memory implementation for testing

## Errors

- `CloudError` - Errors from cloud operations
