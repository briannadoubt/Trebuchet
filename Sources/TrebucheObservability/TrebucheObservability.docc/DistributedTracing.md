# Distributed Tracing

Distributed tracing for tracking requests across Trebuchet actors.

## Overview

TrebuchetObservability provides distributed tracing capabilities to track requests as they flow through your distributed actor system. Traces help you:

- Understand request flow across actors
- Identify performance bottlenecks
- Debug complex distributed interactions
- Correlate logs and metrics for a single request

## Basic Usage

Create and propagate trace contexts:

```swift
import Trebuchet
import TrebuchetObservability

// Create a root trace context
let traceContext = TraceContext()

// Create a span for an operation
var span = Span(
    context: traceContext,
    name: "process_order",
    kind: .server
)

// Add attributes
span.setAttribute("order.id", value: "12345")
span.setAttribute("customer.id", value: "67890")

// Do work...

// End the span
span.end(status: .ok)
```

## Trace Context

TraceContext carries trace information across service boundaries:

```swift
// Root context (starts a new trace)
let rootContext = TraceContext()
print(rootContext.traceID)  // Unique for this entire trace
print(rootContext.spanID)   // Unique for this operation
print(rootContext.parentSpanID)  // nil (no parent)

// Child context (continues the trace)
let childContext = rootContext.createChild()
print(childContext.traceID)  // Same as root
print(childContext.spanID)   // Different span ID
print(childContext.parentSpanID)  // root.spanID
```

## Spans

Spans represent individual operations in a trace:

```swift
var span = Span(
    context: traceContext,
    name: "database_query",
    kind: .client
)

// Add contextual attributes
span.setAttribute("db.system", value: "postgresql")
span.setAttribute("db.statement", value: "SELECT * FROM users")

// Record events during the span
span.addEvent(SpanEvent(
    name: "cache_miss",
    attributes: ["key": "user:123"]
))

// End with status
span.end(status: .ok)

// Get duration
if let duration = span.duration {
    print("Query took \(duration)")
}
```

## Span Kinds

Different span kinds represent different roles in a distributed system:

```swift
// Server span: Handles incoming requests
Span(context: ctx, name: "handle_request", kind: .server)

// Client span: Makes outgoing requests
Span(context: ctx, name: "call_api", kind: .client)

// Internal span: Internal operations
Span(context: ctx, name: "process_data", kind: .internal)

// Producer span: Sends messages
Span(context: ctx, name: "publish_event", kind: .producer)

// Consumer span: Receives messages
Span(context: ctx, name: "consume_event", kind: .consumer)
```

## Span Status

Indicate the outcome of an operation:

```swift
var successSpan = Span(context: ctx, name: "operation")
successSpan.end(status: .ok)

var errorSpan = Span(context: ctx, name: "failed_operation")
errorSpan.end(status: .error)
```

## Span Events

Record significant moments during a span:

```swift
var span = Span(context: ctx, name: "checkout")

span.addEvent(SpanEvent(
    name: "inventory_checked",
    attributes: ["available": "true"]
))

span.addEvent(SpanEvent(
    name: "payment_processed",
    attributes: ["amount": "99.99"]
))

span.end()

// Events are timestamped automatically
for event in span.events {
    print("\(event.name) at \(event.timestamp)")
}
```

## InvocationEnvelope Integration

Trace contexts automatically propagate through actor invocations:

```swift
// Server side: Extract trace context from envelope
let envelope: InvocationEnvelope = // received from client

if let traceContext = envelope.traceContext {
    // Create a server span for this invocation
    var span = Span(
        context: traceContext,
        name: "actor_method",
        kind: .server
    )

    // Execute method...

    span.end(status: .ok)
}
```

## CloudGateway Automatic Tracing

CloudGateway automatically propagates trace contexts:

```swift
let gateway = CloudGateway(configuration: .init(
    loggingConfiguration: .default,
    metricsCollector: metrics
))

// All invocations now include trace context in logs
// Logs will include traceID and spanID for correlation
```

## Span Exporters

Export spans to tracing backends:

### In-Memory Exporter (Testing)

```swift
let exporter = InMemorySpanExporter()

var span = Span(context: TraceContext(), name: "test")
span.end()

try await exporter.export([span])

// Get exported spans for assertions
let spans = await exporter.getExportedSpans()
```

### Console Exporter (Development)

```swift
let exporter = ConsoleSpanExporter()

var span = Span(context: TraceContext(), name: "test-operation", kind: .server)
span.setAttribute("http.method", value: "GET")
span.end()

try await exporter.export([span])
// Prints: [TRACE] test-operation [server] trace=... span=... duration=... status=ok attrs=...
```

## Correlating with Logs

Use trace IDs as correlation IDs in logs:

```swift
let traceContext = TraceContext()
let logger = TrebuchetLogger(label: "app")

await logger.info(
    "Processing request",
    metadata: ["user_id": "123"],
    correlationID: traceContext.traceID
)

// Later, filter logs by trace ID to see all operations for this request
```

## Best Practices

### Span Naming

Use descriptive, low-cardinality names:

- ✅ Good: `"process_order"`, `"database_query"`, `"api_call"`
- ❌ Bad: `"process_order_12345"`, `"query_user_table_row_999"`

### Attributes vs Events

- **Attributes**: Static properties of the operation (method, status code, user ID)
- **Events**: Significant moments during the operation (cache hit, retry attempt)

### Span Granularity

- Create spans for significant operations (RPC calls, database queries, business logic)
- Don't create spans for trivial operations (field access, simple computations)
- Balance detail vs overhead

### Parent-Child Relationships

```swift
// Parent span
let parentContext = TraceContext()
var parentSpan = Span(context: parentContext, name: "checkout")

// Child span (same trace, new span)
let childContext = parentContext.createChild()
var childSpan = Span(context: childContext, name: "validate_payment")

childSpan.end(status: .ok)
parentSpan.end(status: .ok)

// Trace shows: checkout -> validate_payment
```

## Integration with Metrics

Combine tracing with metrics for full observability:

```swift
let traceContext = TraceContext()
var span = Span(context: traceContext, name: "api_call")

let startTime = Date()

// Do work...

span.end(status: .ok)

// Also record as metric
let duration = Date().timeIntervalSince(startTime)
await metrics.recordHistogramMilliseconds(
    "api_latency",
    milliseconds: duration * 1000,
    tags: ["endpoint": "/users"]
)
```

## See Also

- ``TraceContext``
- ``Span``
- ``SpanKind``
- ``SpanStatus``
- ``SpanEvent``
- ``SpanExporter``
- ``InMemorySpanExporter``
- ``ConsoleSpanExporter``
