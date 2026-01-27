// TrebucheObservability.swift
// Production-grade observability for Trebuche distributed actors
//
// This module provides comprehensive observability features including:
// - Structured logging with multiple formatters
// - Metrics collection (counters, gauges, histograms)
// - Distributed tracing with context propagation
//
// Example usage:
// ```swift
// let logger = TrebucheLogger(label: "my-actor")
// logger.info("Actor started", metadata: ["actorID": "user-123"])
//
// let metrics = InMemoryMetricsCollector()
// metrics.incrementCounter("invocations", by: 1, tags: ["method": "join"])
// ```

@_exported import struct Foundation.UUID
@_exported import struct Foundation.Date

/// TrebucheObservability provides production-grade observability for distributed actors.
///
/// This module includes:
/// - **Logging**: Structured, leveled logging with metadata and formatters
/// - **Metrics**: Counters, gauges, and histograms for performance tracking
/// - **Tracing**: Distributed trace context propagation for request tracking
public enum TrebucheObservability {
    /// Current version of the observability module
    public static let version = "1.1.0"
}
