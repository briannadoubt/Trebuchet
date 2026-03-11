# ``TrebuchetOTel``

Self-hosted OpenTelemetry collector for Trebuchet distributed actors.

## Overview

TrebuchetOTel provides a lightweight, self-hosted OpenTelemetry backend that runs alongside your actors. It accepts OTLP/HTTP JSON telemetry (traces, logs, and metrics), stores data in a local SQLite database, and serves an embedded web dashboard — all with a single line in your topology.

```swift
@main
struct MyGame: System {
    var topology: some Topology {
        Collector(port: 4318)

        GameRoom.self
            .expose(as: "room")
    }
}
```

When a `Collector()` is present, tracing and logging exporters auto-wire to it — no duplicate endpoint configuration needed.

## Features

### Traces

Full distributed tracing with OTLP/HTTP JSON ingestion:

- **Span ingestion**: Accepts `POST /v1/traces` with OTLP JSON payloads
- **Trace listing**: Paginated trace summaries with service and status filters
- **Trace detail**: View all spans for a trace with timing and attributes
- **Service discovery**: Auto-detect services from ingested spans
- **Statistics**: p50/p95 latency, error rates, throughput

See <doc:Traces> for details.

### Logs

Structured log collection with the same OTLP/HTTP format:

- **Log ingestion**: Accepts `POST /v1/logs` with OTLP JSON payloads
- **Log querying**: Filter by service, severity, and full-text search
- **Correlation**: Logs include trace and span IDs for cross-referencing

See <doc:Logs> for details.

### Metrics

Metrics collection for all five OTLP metric types:

- **Gauge**: Point-in-time measurements (CPU usage, queue depth)
- **Sum**: Cumulative and delta counters (request count, bytes sent)
- **Histogram**: Distribution data with bucket boundaries
- **ExponentialHistogram**: Log-scale bucketed distributions
- **Summary**: Pre-computed quantiles

See <doc:Metrics> for details.

### Web Dashboard

An embedded web UI served at the collector's root URL:

- Live trace explorer with filtering and search
- Log viewer with severity coloring
- Service overview with health indicators
- Authentication with token-based login

### Security

Production-ready HTTP handler hardening:

- **Authentication**: Bearer token for OTLP ingestion, session cookies for dashboard
- **Hash-based auth**: SHA-256 hash comparison prevents timing attacks
- **Request limits**: 10MB body size limit (413), protobuf rejection (415)
- **CORS**: Configurable origin with proper preflight OPTIONS handling
- **Input sanitization**: Error responses never leak internal details

See <doc:Security> for details.

### Data Management

Automatic data lifecycle with configurable retention:

- **SQLite storage**: GRDB-backed persistence with WAL mode
- **Retention sweeper**: Background cleanup of expired traces, logs, and metrics
- **Configurable TTL**: Default 72-hour retention, adjustable per collector

## Quick Start

### Topology DSL (Recommended)

The simplest way to add observability — just add `Collector()` to your topology:

```swift
@main
struct MyGame: System {
    var topology: some Topology {
        Collector(port: 4318, authToken: "my-secret")

        GameRoom.self
            .expose(as: "room")
            .state(.sqlite())
    }

    var observability: some ObservabilityConfiguration {
        // Auto-wired! No need to repeat the collector endpoint.
        // Tracing and logging automatically point at the Collector.
        Trace()
        Log(.info)
    }
}
```

Run with `trebuchet dev` and open `http://localhost:4318` to see the dashboard.

### Standalone Server

For use outside the System DSL:

```swift
import TrebuchetOTel

let store = try SpanStore(path: "telemetry.sqlite")
let ingester = SpanIngester(store: store)
let server = try await OTelHTTPServer(
    host: "127.0.0.1",
    port: 4318,
    ingester: ingester,
    store: store,
    authToken: "my-secret"
)
try await server.run()
```

### Sending Telemetry

Configure any OTLP/HTTP JSON exporter to point at the collector:

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
export OTEL_EXPORTER_OTLP_PROTOCOL=http/json
```

Or use Trebuchet's built-in exporters which auto-wire when a `Collector()` is in the topology.

## Graceful Shutdown

When running inside a System, the collector participates in ordered shutdown:

1. **SIGINT/SIGTERM** triggers the shutdown coordinator
2. The Trebuchet server stops accepting new connections
3. Collectors shut down (drains in-flight requests)
4. OTLP exporters flush remaining buffered spans and logs
5. Process exits cleanly

This ensures no telemetry data is lost during deployment or restart.

## Deployment

The `Collector()` is included in the deployment plan and shown in dry-run output:

```bash
$ trebuchet deploy ./Server --product MyGame --dry-run

Collectors:
  Port: 4318
  Host: 0.0.0.0
  Auth: enabled
  Retention: 72h
  CORS: *
```

## API Reference

### Ingestion Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/v1/traces` | Ingest OTLP/HTTP JSON traces |
| `POST` | `/v1/logs` | Ingest OTLP/HTTP JSON logs |
| `POST` | `/v1/metrics` | Ingest OTLP/HTTP JSON metrics |

### Query Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/traces` | List traces (paginated) |
| `GET` | `/api/traces/:traceId` | Get spans for a trace |
| `GET` | `/api/logs` | List logs (paginated) |
| `GET` | `/api/services` | List known services |
| `GET` | `/api/stats` | Trace statistics |
| `GET` | `/api/metrics` | List metrics (paginated) |
| `GET` | `/api/metric-names` | List distinct metric names |
| `GET` | `/api/search` | Search spans by text |
| `GET` | `/health` | Health check (always public) |

### Dashboard

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/` | Web dashboard (redirects to login if auth enabled) |
| `GET` | `/login` | Login page |
| `POST` | `/login` | Submit login token |
| `POST` | `/logout` | Clear session cookie |

## Topics

### Essentials

- <doc:Traces>
- <doc:Logs>
- <doc:Metrics>
- <doc:Security>

### Topology DSL

- ``Collector(port:host:authToken:storagePath:retentionHours:corsOrigin:)``
- ``CollectorDescriptor``

### Server

- ``OTelHTTPServer``

### Storage

- ``SpanStore``
- ``SpanRecord``
- ``TraceSummary``
- ``TracePage``
- ``LogRecord``
- ``LogPage``
- ``MetricRecord``
- ``MetricPage``
- ``SpanStats``

### Ingestion

- ``SpanIngester``
- ``OTLPDecoder``

### Data Management

- ``RetentionSweeper``
