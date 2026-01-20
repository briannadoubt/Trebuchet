# TrebucheAWS Module

Deploy Swift distributed actors to AWS Lambda with DynamoDB state and CloudMap discovery.

## Overview

TrebucheAWS provides AWS-specific implementations of the TrebucheCloud protocols, enabling seamless deployment of distributed actors to AWS Lambda.

```swift
import TrebucheAWS

// Configure state and discovery
let stateStore = DynamoDBStateStore(tableName: "my-actor-state")
let registry = CloudMapRegistry(namespace: "my-app")

// Create gateway
let gateway = CloudGateway(configuration: .init(
    stateStore: stateStore,
    registry: registry
))

// Register actors
try await gateway.expose(GameRoom(actorSystem: gateway.system), as: "game-room")
```

## AWS Provider

- `AWSProvider` - CloudProvider implementation for AWS
- `AWSFunctionConfig` - Lambda function configuration (memory, timeout, VPC)
- `AWSDeployment` - AWS-specific deployment result
- `AWSCredentials` - AWS credential management
- `VPCConfig` - VPC configuration for Lambda

## State Storage

- `DynamoDBStateStore` - ActorStateStore implementation using DynamoDB

## Service Discovery

- `CloudMapRegistry` - ServiceRegistry implementation using AWS Cloud Map

## Lambda Integration

- `LambdaInvokeTransport` - Transport for invoking Lambda functions
- `LambdaEventAdapter` - Converts between Lambda events and Trebuche format
- `APIGatewayV2Request` - API Gateway HTTP API request format
- `APIGatewayV2Response` - API Gateway HTTP API response format
- `HTTPResponseStatus` - HTTP status codes

## Actor Communication

- `TrebucheCloudClient` - Client for resolving actors across Lambda functions
- `CloudLambdaContext` - Context available to actors running in Lambda
