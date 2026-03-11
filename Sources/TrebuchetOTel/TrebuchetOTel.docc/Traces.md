# Traces

Collect and query distributed traces from your actors.

## Overview

TrebuchetOTel accepts OpenTelemetry traces via the standard OTLP/HTTP JSON protocol. Spans are batched by the ``SpanIngester``, stored in SQLite via ``SpanStore``, and queryable through both the REST API and the web dashboard.

## Ingestion

Send traces to `POST /v1/traces` with a standard OTLP JSON payload:

```json
{
  "resourceSpans": [{
    "resource": {
      "attributes": [
        { "key": "service.name", "value": { "stringValue": "my-service" } }
      ]
    },
    "scopeSpans": [{
      "spans": [{
        "traceId": "abc123...",
        "spanId": "def456...",
        "name": "GameRoom.join",
        "kind": 2,
        "startTimeUnixNano": "1709000000000000000",
        "endTimeUnixNano": "1709000000042000000",
        "status": { "code": 1 }
      }]
    }]
  }]
}
```

If authentication is enabled, include a `Bearer` token in the `Authorization` header.

### Batching

The ``SpanIngester`` batches incoming spans and flushes them to ``SpanStore`` periodically or when the batch reaches a configurable size. This reduces SQLite write pressure under high throughput.

## Querying

### List Traces

`GET /api/traces` returns paginated trace summaries:

| Parameter | Type | Description |
|-----------|------|-------------|
| `service` | String | Filter by service name |
| `status` | Int | Filter by span status code |
| `limit` | Int | Page size (default: 50) |
| `cursor` | Int64 | Cursor for pagination |

Response includes ``TraceSummary`` objects with trace ID, root operation, service name, span count, duration, and error status.

### Trace Detail

`GET /api/traces/:traceId` returns all ``SpanRecord`` objects for a given trace, ordered by start time.

### Search

`GET /api/search?q=keyword` performs full-text search across span operation names and attributes.

### Statistics

`GET /api/stats` returns ``SpanStats`` with:

- Total span count
- Error rate
- p50 and p95 latency (computed in SQL for efficiency)
- Throughput over recent time windows

### Services

`GET /api/services` returns a list of distinct service names seen in ingested spans.

## Auto-wiring

When a ``Collector`` is in your System topology, the tracing exporter automatically points at it:

```swift
var topology: some Topology {
    Collector(port: 4318)

    GameRoom.self.expose(as: "room")
}

var observability: some ObservabilityConfiguration {
    Tracing(.otlp)  // Automatically uses http://127.0.0.1:4318
}
```

You can still override with an explicit endpoint if needed.

## Retention

Traces older than the configured retention period (default: 72 hours) are automatically deleted by the ``RetentionSweeper``.
