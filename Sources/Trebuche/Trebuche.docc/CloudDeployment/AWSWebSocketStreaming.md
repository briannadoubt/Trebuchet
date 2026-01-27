# AWS WebSocket Streaming

Deploy Trebuche actors with realtime WebSocket streaming on AWS Lambda and API Gateway.

## Overview

Trebuche supports production-grade realtime streaming on AWS using:
- **API Gateway WebSocket API** for persistent connections
- **AWS Lambda** for serverless actor execution
- **DynamoDB** for connection tracking and actor state
- **DynamoDB Streams** for multi-instance synchronization

This architecture provides automatic scaling, high availability, and pay-per-use pricing.

## Architecture

```
Client (WebSocket)
    ↓
API Gateway WebSocket API
    ↓
Lambda (WebSocket Handler)
    ├─→ DynamoDB (Connection Table)
    │   └─→ Track active connections and subscriptions
    └─→ Lambda (Actor Invocation)
        └─→ DynamoDB (Actor State Table)
            └─→ DynamoDB Stream
                └─→ Lambda (Stream Processor)
                    └─→ Broadcast updates to connected clients
```

## Prerequisites

- AWS account with appropriate permissions
- `trebuche` CLI installed
- AWS credentials configured
- Terraform installed (optional, CLI can generate Terraform)

## Configuration

Create a `trebuche.yaml` configuration file:

```yaml
name: my-streaming-app
version: "1"

defaults:
  provider: aws
  region: us-east-1
  memory: 512
  timeout: 30

actors:
  TodoList:
    memory: 1024
    stateful: true
  GameRoom:
    memory: 2048
    stateful: true

websocket:
  enabled: true
  stage: production
  routes:
    - $connect     # New connection handler
    - $disconnect  # Disconnection handler
    - $default     # Message router

state:
  type: dynamodb
  table: my-app-actor-state

connections:
  type: dynamodb
  table: my-app-connections
```

## Deployment

Deploy your streaming actors to AWS:

```bash
# Preview what will be deployed
trebuche deploy --dry-run --verbose

# Deploy to AWS
trebuche deploy --provider aws --region us-east-1

# Output:
# ✓ Lambda: arn:aws:lambda:us-east-1:123:function:my-app-websocket
# ✓ API Gateway: wss://abc123.execute-api.us-east-1.amazonaws.com/production
# ✓ DynamoDB: my-app-actor-state
# ✓ DynamoDB: my-app-connections
# ✓ DynamoDB Streams: Enabled
```

## Lambda Handler Implementation

The WebSocket Lambda handler manages connection lifecycle and message routing:

```swift
import AWSLambdaRuntime
import Trebuche
import TrebucheCloud
import TrebucheAWS

@main
struct WebSocketHandler: SimpleLambdaHandler {
    let handler: WebSocketLambdaHandler

    init(context: LambdaInitializationContext) async throws {
        // Configure state store
        let stateStore = DynamoDBStateStore(
            tableName: env("STATE_TABLE"),
            region: env("AWS_REGION") ?? "us-east-1"
        )

        // Configure connection storage (DynamoDB-backed)
        let connectionStorage = DynamoDBConnectionStorage(
            tableName: env("CONNECTION_TABLE"),
            region: env("AWS_REGION") ?? "us-east-1"
        )

        // Configure connection sender (API Gateway Management API)
        let connectionSender = APIGatewayConnectionSender(
            endpoint: env("WEBSOCKET_ENDPOINT"),
            region: env("AWS_REGION") ?? "us-east-1"
        )

        // Create connection manager
        let connectionManager = ConnectionManager(
            storage: connectionStorage,
            sender: connectionSender
        )

        // Create cloud gateway
        let gateway = CloudGateway(configuration: .init(
            stateStore: stateStore,
            registry: CloudMapRegistry(namespace: env("NAMESPACE"))
        ))

        // Register your actors
        let todoList = try await TodoList(
            actorSystem: gateway.system,
            stateStore: stateStore
        )
        try await gateway.expose(todoList, as: "todos")

        let gameRoom = try await GameRoom(
            actorSystem: gateway.system,
            stateStore: stateStore
        )
        try await gateway.expose(gameRoom, as: "game")

        // Create WebSocket handler
        handler = WebSocketLambdaHandler(
            gateway: gateway,
            connectionManager: connectionManager
        )
    }

    func handle(
        _ event: APIGatewayWebSocketEvent,
        context: LambdaContext
    ) async throws -> APIGatewayWebSocketResponse {
        try await handler.handle(event)
    }
}
```

## Connection Management

### Connection Storage and Sender Implementations

TrebucheAWS provides production-ready implementations for WebSocket connection management:

**Production Implementations** (included in TrebucheAWS):
```swift
import TrebucheAWS

// DynamoDB-backed connection storage
let storage = DynamoDBConnectionStorage(
    tableName: "my-app-connections",
    region: "us-east-1"
)

// API Gateway Management API sender
let sender = APIGatewayConnectionSender(
    endpoint: "https://abc123.execute-api.us-east-1.amazonaws.com/production",
    region: "us-east-1"
)

let connectionManager = ConnectionManager(
    storage: storage,
    sender: sender
)
```

**For Testing/Development**:
```swift
// Use in-memory implementations for local testing
let storage = InMemoryConnectionStorage()
let sender = InMemoryConnectionSender()
```

### DynamoDB Connection Storage

`DynamoDBConnectionStorage` uses DynamoDB to persist connection metadata:

**Features**:
- Automatic TTL cleanup (24-hour default)
- GSI for querying connections by actor
- Atomic updates for sequence tracking
- Built-in error handling

**Required Table Schema**:
```
Table: connections

Primary Key:
  - connectionId (String, Hash Key)

GSI: actorId-index
  - actorId (String, Hash Key)
  - streamId (String, Sort Key)

Attributes:
  - connectedAt (Number, timestamp)
  - lastSequence (Number)
  - ttl (Number, auto-cleanup)
```

### API Gateway Connection Sender

`APIGatewayConnectionSender` uses the API Gateway Management API to send messages:

**Features**:
- POST-to-connection for message delivery
- Automatic 410 Gone detection (disconnected clients)
- Connection health checks with `isAlive()`
- Force-disconnect with `disconnect()`

**Additional Methods**:
```swift
// Check if connection is still alive
let alive = await sender.isAlive(connectionID: "abc123")

// Force-disconnect a client
try await sender.disconnect(connectionID: "abc123")

// Get connection metadata
let info = try await sender.getConnectionInfo(connectionID: "abc123")
```

### DynamoDB Connections Table

The connections table tracks active WebSocket connections:

```
Table: my-app-connections

Primary Key:
  - connectionId (String, Hash Key)

GSI: actorId-index
  - actorId (String, Hash Key)
  - streamId (String, Sort Key)

Attributes:
  - connectedAt (Number, timestamp)
  - lastSequence (Number)
  - ttl (Number, auto-cleanup)
```

### Connection Lifecycle

#### $connect Route

Registers new WebSocket connections:

```swift
private func handleConnect(
    event: APIGatewayWebSocketEvent
) async throws -> APIGatewayWebSocketResponse {
    let connectionID = event.requestContext.connectionId
    try await connectionManager.register(connectionID: connectionID)
    return APIGatewayWebSocketResponse(statusCode: 200)
}
```

#### $disconnect Route

Cleans up disconnected clients:

```swift
private func handleDisconnect(
    event: APIGatewayWebSocketEvent
) async throws -> APIGatewayWebSocketResponse {
    let connectionID = event.requestContext.connectionId
    try await connectionManager.unregister(connectionID: connectionID)
    return APIGatewayWebSocketResponse(statusCode: 200)
}
```

#### $default Route

Routes messages to actors and handles streaming:

```swift
private func handleMessage(
    event: APIGatewayWebSocketEvent
) async throws -> APIGatewayWebSocketResponse {
    guard let body = event.body else {
        return APIGatewayWebSocketResponse(statusCode: 400)
    }

    let connectionID = event.requestContext.connectionId
    let envelope = try decoder.decode(TrebuchetEnvelope.self, from: Data(body.utf8))

    // Route to appropriate handler
    switch envelope {
    case .invocation(let inv):
        return try await handleInvocation(inv, connectionID: connectionID)
    case .streamResume(let resume):
        return try await handleStreamResume(resume, connectionID: connectionID)
    default:
        return APIGatewayWebSocketResponse(statusCode: 400)
    }
}
```

## Broadcasting Updates

### DynamoDB Stream Processor

The stream processor Lambda watches for state changes and broadcasts to clients:

```swift
import AWSLambdaRuntime
import TrebucheAWS

@main
struct StreamProcessor: SimpleLambdaHandler {
    let adapter: DynamoDBStreamAdapter
    let connectionManager: ConnectionManager

    init(context: LambdaInitializationContext) async throws {
        let region = env("AWS_REGION") ?? "us-east-1"

        let storage = DynamoDBConnectionStorage(
            tableName: env("CONNECTION_TABLE"),
            region: region
        )
        let sender = APIGatewayConnectionSender(
            endpoint: env("WEBSOCKET_ENDPOINT"),
            region: region
        )
        connectionManager = ConnectionManager(storage: storage, sender: sender)

        adapter = DynamoDBStreamAdapter(
            connectionManager: connectionManager
        )
    }

    func handle(
        _ event: DynamoDBStreamEvent,
        context: LambdaContext
    ) async throws {
        for record in event.records {
            // Extract actor state change
            guard let actorID = record.dynamodb.keys?["actorId"]?.stringValue,
                  let newState = record.dynamodb.newImage?["state"]?.binaryValue
            else { continue }

            // Broadcast to all connections subscribed to this actor
            try await adapter.handleStateChange(
                actorID: actorID,
                state: newState
            )
        }
    }
}
```

### Broadcast Implementation

```swift
extension DynamoDBStreamAdapter {
    func handleStateChange(actorID: String, state: Data) async throws {
        // Get all connections subscribed to this actor
        let connections = try await connectionManager.getConnections(for: actorID)

        // Create stream data envelope
        let envelope = StreamDataEnvelope(
            streamID: UUID(), // Per-connection stream ID
            sequenceNumber: generateSequence(),
            data: state,
            timestamp: Date()
        )

        // Broadcast to all subscribers
        for connection in connections {
            do {
                try await connectionManager.send(
                    data: encoder.encode(TrebuchetEnvelope.streamData(envelope)),
                    to: connection.connectionID
                )
            } catch {
                // Connection dead, unregister it
                try? await connectionManager.unregister(
                    connectionID: connection.connectionID
                )
            }
        }
    }
}
```

## Terraform Configuration

The CLI generates Terraform for your infrastructure:

```hcl
# API Gateway WebSocket API
resource "aws_apigatewayv2_api" "websocket" {
  name                       = "my-app-websocket"
  protocol_type              = "WEBSOCKET"
  route_selection_expression = "$request.body.action"
}

# WebSocket Routes
resource "aws_apigatewayv2_route" "connect" {
  api_id    = aws_apigatewayv2_api.websocket.id
  route_key = "$connect"
  target    = "integrations/${aws_apigatewayv2_integration.connect.id}"
}

resource "aws_apigatewayv2_route" "disconnect" {
  api_id    = aws_apigatewayv2_api.websocket.id
  route_key = "$disconnect"
  target    = "integrations/${aws_apigatewayv2_integration.disconnect.id}"
}

resource "aws_apigatewayv2_route" "default" {
  api_id    = aws_apigatewayv2_api.websocket.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.default.id}"
}

# Lambda Function
resource "aws_lambda_function" "websocket_handler" {
  filename      = "bootstrap.zip"
  function_name = "my-app-websocket"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "bootstrap"
  runtime       = "provided.al2023"
  architectures = ["arm64"]

  environment {
    variables = {
      STATE_TABLE       = aws_dynamodb_table.actor_state.name
      CONNECTION_TABLE  = aws_dynamodb_table.connections.name
      WEBSOCKET_ENDPOINT = aws_apigatewayv2_stage.production.invoke_url
    }
  }
}

# DynamoDB Tables
resource "aws_dynamodb_table" "connections" {
  name         = "my-app-connections"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "connectionId"

  attribute {
    name = "connectionId"
    type = "S"
  }

  attribute {
    name = "actorId"
    type = "S"
  }

  global_secondary_index {
    name            = "actorId-index"
    hash_key        = "actorId"
    projection_type = "ALL"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }
}

resource "aws_dynamodb_table" "actor_state" {
  name         = "my-app-actor-state"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "actorId"

  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  attribute {
    name = "actorId"
    type = "S"
  }
}

# DynamoDB Stream Trigger
resource "aws_lambda_event_source_mapping" "dynamodb_stream" {
  event_source_arn  = aws_dynamodb_table.actor_state.stream_arn
  function_name     = aws_lambda_function.stream_processor.arn
  starting_position = "LATEST"
}
```

## Client Integration

Connect to your deployed WebSocket API:

```swift
import Trebuche

// Production endpoint from deployment
let endpoint = "wss://abc123.execute-api.us-east-1.amazonaws.com/production"

let client = TrebuchetClient(transport: .webSocket(url: endpoint))
try await client.connect()

// Resolve and subscribe to actor
let todoList = try client.resolve(TodoList.self, id: "todos")
let stream = await todoList.observeState()

for await state in stream {
    print("Todos updated: \(state.todos.count)")
}
```

## SwiftUI Integration

```swift
@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .trebuche(transport: .webSocket(
                    url: "wss://abc123.execute-api.us-east-1.amazonaws.com/production"
                ))
        }
    }
}

struct ContentView: View {
    @ObservedActor("todos", observe: \TodoList.observeState)
    var state

    var body: some View {
        if let currentState = state {
            List(currentState.todos) { todo in
                Text(todo.title)
            }
        }
    }
}
```

## Monitoring & Observability

### CloudWatch Metrics

Monitor your WebSocket deployment:

```
AWS/ApiGateway:
  - ConnectCount: New connections per minute
  - MessageCount: Messages sent/received
  - IntegrationLatency: Lambda execution time

AWS/Lambda:
  - Invocations: Function invocations
  - Duration: Execution time
  - Errors: Failed invocations
  - ConcurrentExecutions: Active instances

AWS/DynamoDB:
  - ConsumedReadCapacityUnits: Read throughput
  - ConsumedWriteCapacityUnits: Write throughput
  - UserErrors: Throttling events
```

### CloudWatch Logs

Lambda functions automatically log to CloudWatch:

```
WebSocket Handler logs:
/aws/lambda/my-app-websocket

Stream Processor logs:
/aws/lambda/my-app-stream-processor
```

### Alarms

Set up CloudWatch alarms for production:

```hcl
resource "aws_cloudwatch_metric_alarm" "websocket_errors" {
  alarm_name          = "my-app-websocket-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = "300"
  statistic           = "Sum"
  threshold           = "10"

  dimensions = {
    FunctionName = aws_lambda_function.websocket_handler.function_name
  }
}
```

## Cost Optimization

See <doc:AWSCosts> for detailed cost analysis. Key optimizations:

1. **Use Provisioned DynamoDB** for predictable workloads (50-70% savings)
2. **Compress messages** using gzip (60-80% bandwidth reduction)
3. **Batch DynamoDB operations** (20-30% request reduction)
4. **Use ARM64 Lambda** (20% compute cost reduction)
5. **Implement idle timeouts** to close inactive connections

Typical production cost: **$0.15-$0.25 per user per month**

## Troubleshooting

### Connections Not Persisting

**Problem**: WebSocket connects but immediately disconnects

**Solutions**:
- Check Lambda execution role has DynamoDB permissions
- Verify CONNECTION_TABLE environment variable is set
- Check CloudWatch logs for errors in $connect handler

### Messages Not Broadcasting

**Problem**: State changes don't reach clients

**Solutions**:
- Verify DynamoDB Streams is enabled on actor state table
- Check stream processor Lambda has EventSourceMapping
- Ensure API Gateway Management API permissions are granted
- Check connection storage has correct actorId index

### High Latency

**Problem**: Updates take seconds to reach clients

**Solutions**:
- Enable Lambda Provisioned Concurrency to eliminate cold starts
- Use DynamoDB Provisioned Capacity for consistent performance
- Check API Gateway POST-to-connection latency in metrics
- Consider regional deployment closer to users

## See Also

- <doc:DeployingToAWS> - General AWS deployment guide
- <doc:AWSConfiguration> - AWS configuration reference
- <doc:AWSCosts> - Detailed cost analysis and optimization
- <doc:AdvancedStreaming> - Advanced streaming features
