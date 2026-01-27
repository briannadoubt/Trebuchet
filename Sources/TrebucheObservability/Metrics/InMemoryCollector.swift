// InMemoryCollector.swift
// In-memory metrics collector for testing and development

import Foundation

/// In-memory metrics collector for testing and development
public actor InMemoryMetricsCollector: MetricsCollector {
    private var counters: [String: Counter] = [:]
    private var gauges: [String: Gauge] = [:]
    private var histograms: [String: Histogram] = [:]

    /// Creates a new in-memory collector
    public init() {}

    public func incrementCounter(_ name: String, by value: Int, tags: [String: String]) {
        let counter = counters[name] ?? Counter(name: name)
        counters[name] = counter
        Task {
            await counter.increment(by: value, tags: tags)
        }
    }

    public func recordGauge(_ name: String, value: Double, tags: [String: String]) {
        let gauge = gauges[name] ?? Gauge(name: name)
        gauges[name] = gauge
        Task {
            await gauge.set(to: value, tags: tags)
        }
    }

    public func recordHistogram(_ name: String, value: Duration, tags: [String: String]) {
        let histogram = histograms[name] ?? Histogram(name: name)
        histograms[name] = histogram
        Task {
            await histogram.record(value, tags: tags)
        }
    }

    public func flush() async throws {
        // In-memory collector doesn't need to flush
    }

    // Testing utilities

    /// Gets the counter with the given name
    /// - Parameter name: Counter name
    /// - Returns: Counter if it exists
    public func counter(_ name: String) -> Counter? {
        counters[name]
    }

    /// Gets the gauge with the given name
    /// - Parameter name: Gauge name
    /// - Returns: Gauge if it exists
    public func gauge(_ name: String) -> Gauge? {
        gauges[name]
    }

    /// Gets the histogram with the given name
    /// - Parameter name: Histogram name
    /// - Returns: Histogram if it exists
    public func histogram(_ name: String) -> Histogram? {
        histograms[name]
    }

    /// Resets all metrics
    public func reset() async {
        for counter in counters.values {
            await counter.reset()
        }
        for gauge in gauges.values {
            await gauge.reset()
        }
        for histogram in histograms.values {
            await histogram.reset()
        }
        counters.removeAll()
        gauges.removeAll()
        histograms.removeAll()
    }

    /// Gets a summary of all metrics
    /// - Returns: Summary string
    public func summary() async -> String {
        var lines: [String] = []

        lines.append("=== Counters ===")
        for (name, counter) in counters.sorted(by: { $0.key < $1.key }) {
            let values = await counter.allValues()
            for (tags, value) in values {
                let tagStr = tags.isEmpty ? "" : " \(formatTags(tags))"
                lines.append("  \(name)\(tagStr): \(value)")
            }
        }

        lines.append("\n=== Gauges ===")
        for (name, gauge) in gauges.sorted(by: { $0.key < $1.key }) {
            let values = await gauge.allValues()
            for (tags, value) in values {
                let tagStr = tags.isEmpty ? "" : " \(formatTags(tags))"
                lines.append("  \(name)\(tagStr): \(value)")
            }
        }

        lines.append("\n=== Histograms ===")
        for (name, histogram) in histograms.sorted(by: { $0.key < $1.key }) {
            let observations = await histogram.allObservations()
            for (tags, _) in observations {
                if let stats = await histogram.statistics(for: tags) {
                    let tagStr = tags.isEmpty ? "" : " \(formatTags(tags))"
                    lines.append("  \(name)\(tagStr):")
                    lines.append("    count: \(stats.count), mean: \(String(format: "%.2f", stats.mean))ms")
                    lines.append("    min: \(String(format: "%.2f", stats.min))ms, max: \(String(format: "%.2f", stats.max))ms")
                    lines.append("    p50: \(String(format: "%.2f", stats.p50))ms, p95: \(String(format: "%.2f", stats.p95))ms, p99: \(String(format: "%.2f", stats.p99))ms")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    private func formatTags(_ tags: [String: String]) -> String {
        "{" + tags.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ") + "}"
    }
}
