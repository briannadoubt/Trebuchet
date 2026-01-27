# ``TrebuchetObservability``

Production-grade observability for distributed actors.

## Overview

TrebuchetObservability provides comprehensive observability features for Trebuchet distributed actors, enabling you to monitor, debug, and optimize your applications in production.

```swift
import TrebuchetObservability

// Structured logging
let logger = TrebuchetLogger(label: "my-actor")
await logger.info("Actor started", metadata: ["actorID": "user-123"])

// Metrics collection
let metrics = InMemoryMetricsCollector()
await metrics.incrementCounter("invocations", by: 1, tags: ["method": "join"])

// Distributed tracing
let tracer = TrebuchetTracer()
let span = tracer.startSpan("handleRequest", kind: .server)
defer { span.end() }
```

## Features

### Structured Logging

High-performance, structured logging with rich metadata:

- **Multiple Log Levels**: Debug, info, warning, error, critical
- **Structured Metadata**: Attach key-value pairs to log messages
- **Sensitive Data Redaction**: Automatically redact passwords, tokens, and secrets
- **Correlation IDs**: Track requests across distributed actors
- **Pluggable Formatters**: JSON for production, console for development

See <doc:Logging> for details.

### Metrics Collection

Track performance and behavior with standard metrics:

- **Counters**: Count events (invocations, errors, requests)
- **Gauges**: Track current values (active connections, queue depth)
- **Histograms**: Measure distributions (latency, payload size)
- **CloudWatch Integration**: Export metrics to AWS CloudWatch
- **Custom Tags**: Dimension metrics by actor, method, region, etc.

See <doc:Metrics> for details.

### Distributed Tracing

Track requests across actor boundaries:

- **Trace Context Propagation**: Automatic trace ID propagation
- **Span Management**: Record operations with timing and metadata
- **Nested Spans**: Track parent-child relationships
- **Span Events**: Annotate spans with notable events
- **Integration with Logs**: Correlate logs with trace IDs

See <doc:DistributedTracing> for details.

## Quick Start

### Complete Observability Setup

```swift
import TrebuchetObservability
import TrebuchetCloud

// Configure logging
let logger = TrebuchetLogger(
    label: "game-server",
    configuration: .init(
        level: .info,
        formatter: .json,
        redactedKeys: ["password", "token", "secret"]
    )
)

// Configure metrics
let metrics = InMemoryMetricsCollector()

// Configure tracing
let tracer = TrebuchetTracer()

// Inject into CloudGateway
let gateway = CloudGateway(configuration: .init(
    middleware: [
        TracingMiddleware(tracer: tracer)
    ],
    logger: logger,
    metrics: metrics,
    stateStore: stateStore,
    registry: registry
))

// All invocations are now logged, traced, and metered
```

### Actor Logging

```swift
distributed actor GameRoom {
    let logger = TrebuchetLogger(label: "GameRoom")

    distributed func join(player: Player) async throws {
        await logger.info("Player joining", metadata: [
            "playerID": player.id,
            "roomID": id.id
        ])

        // ... handle join ...

        await logger.info("Player joined successfully")
    }
}
```

### Recording Metrics

```swift
distributed actor GameRoom {
    let metrics: MetricsCollector

    distributed func join(player: Player) async throws {
        // Increment join counter
        await metrics.incrementCounter("game.joins", tags: [
            "room": id.id
        ])

        let startTime = Date()

        // ... handle join ...

        // Record join latency
        let duration = Date().timeIntervalSince(startTime)
        await metrics.recordHistogram("game.join_latency", value: duration)

        // Update active player count
        await metrics.recordGauge("game.active_players", value: Double(players.count))
    }
}
```

### Distributed Tracing

```swift
distributed actor GameRoom {
    let tracer: TrebuchetTracer

    distributed func join(player: Player) async throws {
        // Start span for this operation
        let span = tracer.startSpan("GameRoom.join", kind: .server)
        defer { span.end() }

        // Add span attributes
        span.setAttribute("player.id", value: player.id)
        span.setAttribute("room.id", value: id.id)

        do {
            // ... handle join ...

            span.addEvent("Player validated")

            // ... more work ...

            span.addEvent("Player added to room")
        } catch {
            span.recordError(error)
            throw error
        }
    }
}
```

## CloudGateway Integration

TrebuchetObservability integrates seamlessly with CloudGateway:

```swift
import TrebuchetCloud
import TrebuchetObservability

// Create observability components
let logger = TrebuchetLogger(label: "gateway")
let metrics = InMemoryMetricsCollector()
let tracer = TrebuchetTracer()

// Create tracing middleware
let tracingMiddleware = TracingMiddleware(tracer: tracer)

// Configure gateway
let gateway = CloudGateway(configuration: .init(
    middleware: [tracingMiddleware],
    logger: logger,
    metrics: metrics,
    stateStore: stateStore,
    registry: registry
))

// Gateway automatically:
// - Logs all invocations
// - Records invocation metrics
// - Propagates trace context
// - Measures latency
```

### Automatic Metrics

CloudGateway automatically records:

```swift
// Invocation counter
"invocations.total" { actor_type, method, result }

// Invocation latency histogram
"invocations.duration" { actor_type, method }

// Active invocation gauge
"invocations.active"

// Error counter
"invocations.errors" { actor_type, method, error_type }

// Payload size histogram
"invocations.payload_size" { direction }
```

### Automatic Logging

CloudGateway automatically logs:

```swift
// Invocation start
logger.info("Invocation started", metadata: [
    "trace_id": span.traceId,
    "actor_type": "GameRoom",
    "method": "join",
    "actor_id": "room-123"
])

// Invocation complete
logger.info("Invocation completed", metadata: [
    "trace_id": span.traceId,
    "duration_ms": 42.5,
    "result": "success"
])

// Invocation error
logger.error("Invocation failed", metadata: [
    "trace_id": span.traceId,
    "error": error.localizedDescription
])
```

## Log Formats

### JSON Format (Production)

```json
{
  "timestamp": "2026-01-26T23:45:12.123Z",
  "level": "INFO",
  "logger": "GameRoom",
  "message": "Player joined",
  "trace_id": "abc123...",
  "metadata": {
    "player_id": "user-456",
    "room_id": "room-123",
    "duration_ms": 42.5
  }
}
```

### Console Format (Development)

```
[2026-01-26 23:45:12.123] INFO  GameRoom: Player joined
  player_id: user-456
  room_id: room-123
  duration_ms: 42.5
  trace_id: abc123...
```

## CloudWatch Integration

Export metrics to AWS CloudWatch:

```swift
import TrebuchetObservability
import TrebuchetAWS

// Configure CloudWatch reporter
let cloudWatch = CloudWatchReporter(
    namespace: "Trebuchet/GameServer",
    region: "us-east-1"
)

// Record metrics
await cloudWatch.incrementCounter("Invocations", by: 1, dimensions: [
    "ActorType": "GameRoom",
    "Method": "join"
])

await cloudWatch.recordHistogram("Latency", value: 42.5, unit: .milliseconds, dimensions: [
    "ActorType": "GameRoom",
    "Method": "join"
])
```

Metrics appear in CloudWatch under the `Trebuchet/GameServer` namespace with custom dimensions.

## Sensitive Data Redaction

Automatically redact sensitive data:

```swift
let logger = TrebuchetLogger(
    label: "auth",
    configuration: .init(
        redactedKeys: [
            "password",
            "token",
            "secret",
            "api_key",
            "authorization"
        ]
    )
)

// This log will redact the password
await logger.info("User login", metadata: [
    "username": "alice",
    "password": "secret123"  // Becomes: "[REDACTED]"
])
```

## Context Propagation

Trace context automatically propagates across actor boundaries:

```swift
// Client actor
distributed actor GameClient {
    let lobby: Lobby

    func findGame() async throws {
        let span = tracer.startSpan("findGame")
        defer { span.end() }

        // Trace context propagates automatically
        let room = try await lobby.matchmake()

        // Trace continues in the lobby actor
        try await room.join()

        // All operations have the same trace_id
    }
}
```

The trace ID is automatically included in all logs and spans, allowing you to see the complete request flow.

## Best Practices

### Structured Metadata

Use consistent metadata keys:

```swift
// ✅ Consistent naming
await logger.info("Player action", metadata: [
    "player_id": player.id,
    "action_type": "join",
    "room_id": room.id
])

// ❌ Inconsistent naming
await logger.info("Player action", metadata: [
    "playerID": player.id,
    "actionType": "join",
    "room": room.id
])
```

### Log Levels

Use appropriate log levels:

```swift
// DEBUG: Detailed diagnostic information
await logger.debug("Processing player input", metadata: ["input": input])

// INFO: General informational messages
await logger.info("Player joined room")

// WARNING: Potentially problematic situations
await logger.warning("Room near capacity", metadata: ["count": count])

// ERROR: Error conditions that don't stop execution
await logger.error("Failed to save state", metadata: ["error": error])

// CRITICAL: Severe errors requiring immediate attention
await logger.critical("Database connection lost")
```

### Metric Naming

Use consistent naming conventions:

```swift
// ✅ Consistent dot notation
"game.joins"
"game.leaves"
"game.join_latency"

// ❌ Inconsistent naming
"gameJoins"
"game_leaves"
"JoinLatency"
```

### Trace Spans

Create spans for significant operations:

```swift
// ✅ Meaningful spans
let span = tracer.startSpan("GameRoom.join")       // Good
let span = tracer.startSpan("validatePlayer")      // Good
let span = tracer.startSpan("databaseQuery")       // Good

// ❌ Too granular
let span = tracer.startSpan("increment counter")   // Too detailed
let span = tracer.startSpan("if statement")        // Not useful
```

## Performance

TrebuchetObservability is designed for production performance:

- **Async Logging**: Non-blocking log writes
- **Efficient Metrics**: In-memory aggregation with batched exports
- **Minimal Overhead**: <1ms per operation
- **Backpressure Handling**: Drops logs under extreme load

## Topics

### Logging

- <doc:Logging>
- ``TrebuchetLogger``
- ``LogLevel``
- ``LogFormatter``
- ``LogContext``
- ``ConsoleFormatter``
- ``JSONFormatter``

### Metrics

- <doc:Metrics>
- ``MetricsCollector``
- ``InMemoryCollector``
- ``CloudWatchReporter``
- ``Counter``
- ``Histogram``

### Distributed Tracing

- <doc:DistributedTracing>
- ``TrebuchetTracer``
- ``TraceContext``
- ``Span``
- ``SpanExporter``

### Middleware

- ``TracingMiddleware``
