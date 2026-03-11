# Logs

Collect and query structured logs from your actors.

## Overview

TrebuchetOTel accepts OpenTelemetry log records via OTLP/HTTP JSON. Logs are stored alongside traces in the same SQLite database, enabling cross-correlation via trace and span IDs.

## Ingestion

Send logs to `POST /v1/logs` with a standard OTLP JSON payload:

```json
{
  "resourceLogs": [{
    "resource": {
      "attributes": [
        { "key": "service.name", "value": { "stringValue": "my-service" } }
      ]
    },
    "scopeLogs": [{
      "logRecords": [{
        "timeUnixNano": "1709000000000000000",
        "severityNumber": 9,
        "severityText": "INFO",
        "body": { "stringValue": "Player joined the game" },
        "traceId": "abc123...",
        "spanId": "def456...",
        "attributes": [
          { "key": "player.id", "value": { "stringValue": "user-42" } }
        ]
      }]
    }]
  }]
}
```

If authentication is enabled, include a `Bearer` token in the `Authorization` header.

## Querying

`GET /api/logs` returns paginated ``LogRecord`` entries:

| Parameter | Type | Description |
|-----------|------|-------------|
| `service` | String | Filter by service name |
| `severity` | Int | Minimum severity number |
| `search` | String | Full-text search in log body |
| `limit` | Int | Page size (default: 50) |
| `cursor` | Int64 | Cursor for pagination |

### Cross-correlation

Each log record includes `traceId` and `spanId` fields. Use these to navigate between the trace view and related log entries in the dashboard.

## Auto-wiring

When a ``Collector(port:host:authToken:storagePath:retentionHours:corsOrigin:)`` is in your topology, the logging exporter auto-wires:

```swift
var observability: some ObservabilityConfiguration {
    Log(.info)  // Automatically exports to the Collector
}
```

The configured `serviceName` is passed through to the log exporter, ensuring logs are correctly attributed to your service.

## Retention

Logs follow the same retention policy as traces (default: 72 hours), managed by the ``RetentionSweeper``.
