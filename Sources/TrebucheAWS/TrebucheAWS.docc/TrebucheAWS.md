# ``TrebucheAWS``

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

## Topics

### Essentials

- <doc:DeployingToAWS>
- <doc:AWSConfiguration>

### AWS Provider

- ``AWSProvider``
- ``AWSFunctionConfig``
- ``AWSDeployment``
- ``AWSCredentials``
- ``VPCConfig``

### State Storage

- ``DynamoDBStateStore``

### Service Discovery

- ``CloudMapRegistry``

### Lambda Integration

- ``LambdaInvokeTransport``
- ``LambdaEventAdapter``
- ``APIGatewayV2Request``
- ``APIGatewayV2Response``
- ``HTTPResponseStatus``

### Actor Communication

- ``TrebucheCloudClient``
- ``CloudLambdaContext``
