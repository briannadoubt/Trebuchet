# Observability

Configure distributed tracing, structured logging, and metrics for your Trebuchet system.

## Overview

Trebuchet integrates with Swift's observability ecosystem — [swift-log](https://github.com/apple/swift-log), [swift-metrics](https://github.com/apple/swift-metrics), and [swift-distributed-tracing](https://github.com/apple/swift-distributed-tracing) — through a declarative DSL on the ``System`` protocol.

Declare what you want in an `observability` property and Trebuchet bootstraps the underlying libraries at startup:

```swift
@main
struct MyGame: System {
    var topology: some Topology {
        GameRoom.self.expose(as: "room")
    }

    var observability: some ObservabilityConfiguration {
        Log(.info, format: .json)
        Trace(exportTo: .otlp(endpoint: "http://localhost:4318"))
        Metric(exportTo: .otlp(endpoint: "http://localhost:4318"))
    }
}
```

## Self-Hosted Collector

The `TrebuchetOTel` module provides a self-hosted OpenTelemetry backend. Adding a `Collector()` to your topology starts an OTLP/HTTP server alongside your actors, and **auto-wires** the tracing and logging exporters to point at it — no duplicate endpoint configuration needed:

```swift
import TrebuchetOTel

@main
struct MyGame: System {
    var topology: some Topology {
        Collector(port: 4318, authToken: "my-secret")

        GameRoom.self
            .expose(as: "room")
            .state(.sqlite())
    }

    var observability: some ObservabilityConfiguration {
        Log(.info)         // auto-wired to Collector
        Trace()            // auto-wired to Collector
    }
}
```

Open `http://localhost:4318` to view the embedded web dashboard with live traces, logs, and metrics.

See <doc:TrebuchetOTel> for the full API reference.

## Logging

Use ``Log`` to configure structured logging:

```swift
var observability: some ObservabilityConfiguration {
    // Console output (default)
    Log(.debug, format: .console)

    // JSON output to stderr
    Log(.info, format: .json)

    // Export to an OTLP endpoint
    Log(.warning, exportTo: "http://collector:4318", authToken: "token")
}
```

Supported log levels mirror `swift-log`: `.trace`, `.debug`, `.info`, `.notice`, `.warning`, `.error`, `.critical`.

## Tracing

Use ``Trace`` to enable distributed tracing:

```swift
var observability: some ObservabilityConfiguration {
    // Console output (useful in development)
    Trace(exportTo: .console)

    // Export to an OTLP/HTTP endpoint
    Trace(exportTo: .otlp(endpoint: "http://collector:4318", authToken: "token"))
}
```

Trebuchet automatically instruments every distributed actor invocation with a span. WebSocket client connections also attach trace context so end-to-end traces flow from browser to server.

## Metrics

Use ``Metric`` to configure metrics export:

```swift
var observability: some ObservabilityConfiguration {
    // In-memory only (default; useful for testing)
    Metric()

    // Export via OTLP
    Metric(exportTo: .otlp(endpoint: "http://collector:4318"))
}
```

## Graceful Shutdown

When the process receives SIGINT or SIGTERM, Trebuchet performs ordered teardown:

1. The Trebuchet server stops accepting new connections.
2. Any ``Collector`` instances drain in-flight requests and shut down.
3. ``ObservabilityBootstrap/shutdown()`` flushes buffered spans and logs to the OTLP endpoint.
4. The process exits cleanly.

This ensures no telemetry data is lost during deployment rollouts or restarts.

Types that participate in shutdown conform to ``GracefullyShutdownable``.

## Topics

### DSL Types

- ``Log``
- ``Metric``
- ``Trace``
- ``ObservabilityConfiguration``
- ``ObservabilityBuilder``

### Configuration

- ``ResolvedObservability``
- ``LoggingDeclaration``
- ``LoggingLevel``
- ``LogFormat``
- ``MetricsDeclaration``
- ``MetricsExporterType``
- ``TracingDeclaration``
- ``TracingExporterType``

### Lifecycle

- ``ObservabilityBootstrap``
- ``GracefullyShutdownable``
