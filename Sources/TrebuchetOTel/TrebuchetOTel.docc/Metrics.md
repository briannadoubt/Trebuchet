# Metrics

Collect and query OpenTelemetry metrics from your actors.

## Overview

TrebuchetOTel accepts all five OTLP metric types via `POST /v1/metrics`. Metrics are stored as ``MetricRecord`` entries in the same SQLite database as traces and logs.

## Supported Metric Types

| Type | Description | Use Case |
|------|-------------|----------|
| **Gauge** | Point-in-time measurement | CPU usage, memory, queue depth |
| **Sum** | Cumulative or delta counter | Request count, bytes transferred |
| **Histogram** | Bucket-based distribution | Latency percentiles, payload sizes |
| **ExponentialHistogram** | Log-scale bucketed distribution | High-cardinality latency data |
| **Summary** | Pre-computed quantiles | Legacy Prometheus-style metrics |

## Ingestion

Send metrics to `POST /v1/metrics` with a standard OTLP JSON payload:

```json
{
  "resourceMetrics": [{
    "resource": {
      "attributes": [
        { "key": "service.name", "value": { "stringValue": "my-service" } }
      ]
    },
    "scopeMetrics": [{
      "metrics": [{
        "name": "http.request.duration",
        "histogram": {
          "dataPoints": [{
            "startTimeUnixNano": "1709000000000000000",
            "timeUnixNano": "1709000000060000000",
            "count": "42",
            "sum": 1.234,
            "bucketCounts": ["10", "20", "8", "4"],
            "explicitBounds": [0.005, 0.01, 0.025, 0.05]
          }]
        }
      }]
    }]
  }]
}
```

### Decoding

``OTLPDecoder/decodeMetrics(from:)`` determines the metric type from the presence of `gauge`, `sum`, `histogram`, `exponentialHistogram`, or `summary` fields. Each data point is stored as raw JSON to avoid complex type-specific parsing, making the decoder forward-compatible with new OTLP fields.

## Querying

### List Metrics

`GET /api/metrics` returns paginated ``MetricRecord`` entries:

| Parameter | Type | Description |
|-----------|------|-------------|
| `name` | String | Filter by metric name |
| `service` | String | Filter by service name |
| `limit` | Int | Page size (default: 50) |
| `cursor` | Int64 | Cursor for pagination |

### Metric Names

`GET /api/metric-names` returns a list of distinct metric names for building dashboards and filters.

## Retention

Metrics follow the same retention policy as traces and logs (default: 72 hours), managed by the ``RetentionSweeper``.
