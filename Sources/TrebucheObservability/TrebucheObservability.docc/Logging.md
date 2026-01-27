# Logging

Structured logging for Trebuche distributed actors.

## Overview

The TrebucheObservability module provides production-grade structured logging with support for:

- Multiple log levels (debug, info, warning, error, critical)
- Structured metadata attachment
- Sensitive data redaction
- Correlation IDs for distributed tracing
- Pluggable formatters (JSON, console)
- Configurable output handlers

## Basic Usage

Create a logger and start logging:

```swift
import TrebucheObservability

let logger = TrebucheLogger(label: "my-component")

await logger.info("Server started", metadata: [
    "port": "8080",
    "environment": "production"
])
```

## Log Levels

Logs are filtered by severity level:

```swift
let config = LoggingConfiguration(level: .warning)
let logger = TrebucheLogger(label: "app", configuration: config)

await logger.debug("Debug message")    // Filtered out
await logger.info("Info message")      // Filtered out
await logger.warning("Warning!")       // Logged
await logger.error("Error occurred")   // Logged
```

## Structured Metadata

Attach key-value metadata to log messages:

```swift
await logger.info("User login", metadata: [
    "user_id": "12345",
    "ip_address": "192.168.1.1",
    "method": "oauth"
])
```

## Sensitive Data Redaction

Automatically redact sensitive fields:

```swift
let config = LoggingConfiguration(redactSensitiveData: true)
let logger = TrebucheLogger(label: "auth", configuration: config)

await logger.info("Authentication", metadata: [
    "username": "alice",
    "password": "secret123",  // Will be [REDACTED]
    "token": "abc123"         // Will be [REDACTED]
])
```

## Correlation IDs

Track related log messages across distributed calls:

```swift
let correlationID = UUID()

await logger.info("Request received", correlationID: correlationID)
await logger.info("Processing request", correlationID: correlationID)
await logger.info("Request completed", correlationID: correlationID)
```

## Formatters

### JSON Formatter

Structured JSON output for log aggregation systems:

```swift
let logger = TrebucheLogger(
    label: "api",
    formatter: JSONFormatter(prettyPrint: true)
)

await logger.info("API call", metadata: ["endpoint": "/users"])
// Output: {"timestamp":"2026-01-24T19:00:00.000Z","level":"info","label":"api","message":"API call","metadata":{"endpoint":"/users"}}
```

### Console Formatter

Human-readable output for development:

```swift
let logger = TrebucheLogger(
    label: "app",
    formatter: ConsoleFormatter(colorEnabled: true)
)

await logger.info("Server running", metadata: ["port": "8080"])
// Output: 2026-01-24T19:00:00.000Z [INFO] [app] Server running | port=8080
```

## Configuration Presets

### Development

Debug logging with no redaction:

```swift
let logger = TrebucheLogger(
    label: "app",
    configuration: .development
)
```

### Production

Info-level logging with sensitive data redaction:

```swift
let logger = TrebucheLogger(
    label: "app",
    configuration: .default
)
```

## Custom Output Handlers

Direct logs to custom destinations:

```swift
let logger = TrebucheLogger(
    label: "app",
    output: { logMessage in
        // Write to file, send to logging service, etc.
        myLoggingService.send(logMessage)
    }
)
```

## See Also

- ``TrebucheLogger``
- ``LoggingConfiguration``
- ``LogLevel``
- ``LogFormatter``
- ``ConsoleFormatter``
- ``JSONFormatter``
