// MetricsCollector.swift
// Protocol for collecting application metrics

import Foundation

/// Protocol for collecting and reporting application metrics
public protocol MetricsCollector: Sendable {
    /// Increments a counter metric
    /// - Parameters:
    ///   - name: Metric name
    ///   - value: Amount to increment by
    ///   - tags: Optional key-value tags for metric dimensions
    func incrementCounter(_ name: String, by value: Int, tags: [String: String]) async

    /// Records a gauge metric (point-in-time value)
    /// - Parameters:
    ///   - name: Metric name
    ///   - value: Gauge value
    ///   - tags: Optional key-value tags for metric dimensions
    func recordGauge(_ name: String, value: Double, tags: [String: String]) async

    /// Records a histogram metric (for latency/duration tracking)
    /// - Parameters:
    ///   - name: Metric name
    ///   - value: Duration value
    ///   - tags: Optional key-value tags for metric dimensions
    func recordHistogram(_ name: String, value: Duration, tags: [String: String]) async

    /// Flushes any buffered metrics to the backend
    func flush() async throws
}

extension MetricsCollector {
    /// Convenience method to increment a counter by 1
    public func incrementCounter(_ name: String, tags: [String: String] = [:]) async {
        await incrementCounter(name, by: 1, tags: tags)
    }

    /// Convenience method to record histogram in milliseconds
    public func recordHistogramMilliseconds(_ name: String, milliseconds: Double, tags: [String: String] = [:]) async {
        await recordHistogram(name, value: .milliseconds(milliseconds), tags: tags)
    }
}

/// Standard metric names for Trebuchet
public enum TrebuchetMetrics {
    // Invocation metrics
    public static let invocationsCount = "Trebuchet.invocations.count"
    public static let invocationsLatency = "Trebuchet.invocations.latency"
    public static let invocationsErrors = "Trebuchet.invocations.errors"

    // Connection metrics
    public static let connectionsActive = "Trebuchet.connections.active"
    public static let connectionsTotal = "Trebuchet.connections.total"

    // State metrics
    public static let stateOperationsCount = "Trebuchet.state.operations.count"
    public static let stateOperationsLatency = "Trebuchet.state.operations.latency"
    public static let stateSize = "Trebuchet.state.size"

    // System metrics
    public static let memoryUsed = "Trebuchet.memory.used"
    public static let actorsActive = "Trebuchet.actors.active"
}
