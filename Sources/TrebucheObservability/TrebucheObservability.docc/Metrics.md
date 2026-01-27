# Metrics

Production-grade metrics collection for Trebuche distributed actors.

## Overview

The TrebucheObservability module provides comprehensive metrics collection with support for:

- Counters (cumulative values that only increase)
- Gauges (point-in-time values that can go up or down)
- Histograms (distributions for latency/duration tracking)
- Pluggable collectors (in-memory, CloudWatch)
- Tag-based dimensions for multi-dimensional metrics
- Standard metrics for common operations

## Basic Usage

Create a metrics collector and start recording metrics:

```swift
import TrebucheObservability

let metrics = InMemoryMetricsCollector()

// Increment a counter
await metrics.incrementCounter("requests", by: 1, tags: ["method": "GET"])

// Record a gauge value
await metrics.recordGauge("memory_used", value: 512.0, tags: [:])

// Record a histogram (latency)
await metrics.recordHistogram("api_latency", value: .milliseconds(150), tags: ["endpoint": "/api/users"])
```

## Counters

Counters track cumulative values that only increase:

```swift
let collector = InMemoryMetricsCollector()

// Increment counter
await collector.incrementCounter("page_views", by: 1, tags: ["page": "home"])

// With dimensions
await collector.incrementCounter("requests", tags: [
    "method": "POST",
    "status": "200"
])

// Query counter value
let counter = await collector.counter("requests")
let value = await counter?.value(for: ["method": "POST", "status": "200"])
```

## Gauges

Gauges track point-in-time values that can go up or down:

```swift
let collector = InMemoryMetricsCollector()

// Set gauge value
await collector.recordGauge("active_connections", value: 42.0, tags: [:])

// Update over time
await collector.recordGauge("memory_usage", value: 512.0, tags: ["region": "us-east"])
await collector.recordGauge("memory_usage", value: 768.0, tags: ["region": "us-east"])
```

## Histograms

Histograms track distributions of values (typically latencies):

```swift
let collector = InMemoryMetricsCollector()

// Record latencies
await collector.recordHistogram("response_time", value: .milliseconds(100), tags: ["endpoint": "/api"])
await collector.recordHistogram("response_time", value: .milliseconds(150), tags: ["endpoint": "/api"])
await collector.recordHistogram("response_time", value: .milliseconds(200), tags: ["endpoint": "/api"])

// Get statistics
let histogram = await collector.histogram("response_time")
if let stats = await histogram?.statistics(for: ["endpoint": "/api"]) {
    print("Mean: \(stats.mean)ms")
    print("P50: \(stats.p50)ms")
    print("P95: \(stats.p95)ms")
    print("P99: \(stats.p99)ms")
}
```

## Standard Metrics

Trebuche defines standard metrics for common operations:

```swift
import TrebucheObservability

// Invocation metrics
TrebucheMetrics.invocationsCount     // "trebuche.invocations.count"
TrebucheMetrics.invocationsLatency   // "trebuche.invocations.latency"
TrebucheMetrics.invocationsErrors    // "trebuche.invocations.errors"

// Connection metrics
TrebucheMetrics.connectionsActive    // "trebuche.connections.active"
TrebucheMetrics.connectionsTotal     // "trebuche.connections.total"

// State metrics
TrebucheMetrics.stateOperationsCount   // "trebuche.state.operations.count"
TrebucheMetrics.stateOperationsLatency // "trebuche.state.operations.latency"

// System metrics
TrebucheMetrics.actorsActive         // "trebuche.actors.active"
TrebucheMetrics.memoryUsed           // "trebuche.memory.used"
```

## CloudGateway Integration

Automatically track metrics for all actor invocations:

```swift
import TrebucheCloud
import TrebucheObservability

let metrics = InMemoryMetricsCollector()

let gateway = CloudGateway(configuration: .init(
    metricsCollector: metrics
))

// Expose actors
try await gateway.expose(myActor, as: "my-actor")

// Gateway now automatically tracks:
// - trebuche.invocations.count (by actor_type, target, status)
// - trebuche.invocations.latency (by actor_type, target)
// - trebuche.invocations.errors (by reason)
// - trebuche.actors.active
```

## CloudWatch Reporter

Send metrics to AWS CloudWatch:

```swift
let cloudWatch = CloudWatchReporter(configuration: .init(
    namespace: "Trebuche/Production",
    region: "us-east-1",
    flushInterval: .seconds(60),
    maxBatchSize: 20
))

let gateway = CloudGateway(configuration: .init(
    metricsCollector: cloudWatch
))

// Metrics are automatically batched and sent to CloudWatch every 60 seconds
```

## In-Memory Collector (Development)

The in-memory collector is perfect for development and testing:

```swift
let metrics = InMemoryMetricsCollector()

// Record metrics...
await metrics.incrementCounter("test", tags: [:])

// Print summary
let summary = await metrics.summary()
print(summary)
// === Counters ===
//   test: 1
// === Gauges ===
// === Histograms ===

// Reset for next test
await metrics.reset()
```

## Multi-Dimensional Metrics

Use tags to add dimensions to your metrics:

```swift
// Track requests by multiple dimensions
await metrics.incrementCounter("http_requests", tags: [
    "method": "POST",
    "path": "/api/users",
    "status": "201",
    "region": "us-east-1"
])

// Query specific dimensions
let counter = await metrics.counter("http_requests")
let value = await counter?.value(for: [
    "method": "POST",
    "status": "201"
])
```

## Best Practices

### Counter vs Gauge

- **Use counters** for cumulative values: request counts, error counts, bytes sent
- **Use gauges** for current state: active connections, memory usage, queue depth

### Histogram Granularity

- Group related operations: `api_latency` with `endpoint` tag rather than `api_users_latency`, `api_posts_latency`
- Use histograms for any timing/duration metrics to get percentiles

### Tag Cardinality

⚠️ **Critical**: High-cardinality tags can cause severe performance and storage issues in metrics backends.

**Keep unique tag combinations under 1000** for optimal performance.

**Good tags** (low cardinality):
- `{method: "GET", status: "200"}` - ~10 methods × 10 status codes = 100 combinations
- `{actor_type: "GameRoom", operation: "join"}` - bounded by code
- `{region: "us-east-1", tier: "premium"}` - bounded configuration

**Bad tags** (high cardinality):
- ❌ `{request_id: "uuid-here"}` - unbounded (millions of values)
- ❌ `{user_id: "123"}` - unbounded (scales with users)
- ❌ `{timestamp: "2026-01-24T..."}` - unbounded (infinite values)
- ❌ `{actor_id: "room-12345"}` - unbounded (scales with actors)

**Impact of high cardinality**:
- CloudWatch: Increased costs, slower queries, dimension limit errors
- Memory: Each unique combination creates new time series
- Queries: Slower aggregations, timeout errors

**Alternative approaches**:
- Use logs for high-cardinality data (individual request IDs)
- Aggregate user metrics into buckets (`user_tier: "premium"` instead of `user_id`)
- Use separate metrics for different granularities

### Metric Naming

- Use dotted notation: `trebuche.invocations.latency`
- Include component: `trebuche.state.operations.count`
- End with unit when applicable: `_count`, `_latency`, `_bytes`

## See Also

- ``MetricsCollector``
- ``Counter``
- ``Gauge``
- ``Histogram``
- ``InMemoryMetricsCollector``
- ``CloudWatchReporter``
- ``TrebucheMetrics``
