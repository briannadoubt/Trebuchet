// Histogram.swift
// Histogram metric type for tracking distributions

import Foundation

/// A histogram metric for tracking value distributions (e.g., latencies)
public actor Histogram {
    /// Metric name
    public let name: String

    /// Maximum samples to keep per tag combination (prevents unbounded memory growth)
    public let maxSamples: Int

    /// Recorded observations by tag combination
    private var observations: [TagKey: [Double]] = [:]

    /// Creates a new histogram
    /// - Parameters:
    ///   - name: Metric name
    ///   - maxSamples: Maximum samples to retain per tag combination (default: 1000)
    public init(name: String, maxSamples: Int = 1000) {
        self.name = name
        self.maxSamples = maxSamples
    }

    /// Records an observation
    /// - Parameters:
    ///   - value: Value to record (in milliseconds)
    ///   - tags: Tags identifying this histogram dimension
    public func record(_ value: Double, tags: [String: String] = [:]) {
        let key = TagKey(tags: tags)
        var values = observations[key, default: []]

        if values.count < maxSamples {
            // Still have room, just append
            values.append(value)
        } else {
            // Use reservoir sampling to randomly replace an existing value
            // This maintains statistical properties while bounding memory
            let randomIndex = Int.random(in: 0..<maxSamples)
            values[randomIndex] = value
        }

        observations[key] = values
    }

    /// Records a duration observation
    /// - Parameters:
    ///   - duration: Duration to record
    ///   - tags: Tags identifying this histogram dimension
    public func record(_ duration: Duration, tags: [String: String] = [:]) {
        let milliseconds = Double(duration.components.seconds) * 1000.0 +
                          Double(duration.components.attoseconds) / 1_000_000_000_000_000.0
        record(milliseconds, tags: tags)
    }

    /// Calculates statistics for the histogram
    /// - Parameter tags: Tags to query
    /// - Returns: Histogram statistics
    public func statistics(for tags: [String: String] = [:]) -> HistogramStatistics? {
        let key = TagKey(tags: tags)
        guard let values = observations[key], !values.isEmpty else {
            return nil
        }

        let sorted = values.sorted()
        let count = values.count
        let sum = values.reduce(0.0, +)
        let mean = sum / Double(count)

        return HistogramStatistics(
            count: count,
            sum: sum,
            mean: mean,
            min: sorted.first!,
            max: sorted.last!,
            p50: percentile(sorted, 0.50),
            p95: percentile(sorted, 0.95),
            p99: percentile(sorted, 0.99)
        )
    }

    /// Gets all observations with their tags
    /// - Returns: Array of (tags, observations) tuples
    public func allObservations() -> [(tags: [String: String], values: [Double])] {
        observations.map { (tags: $0.key.tags, values: $0.value) }
    }

    /// Resets the histogram
    public func reset() {
        observations.removeAll()
    }

    /// Calculates a percentile value
    private func percentile(_ sorted: [Double], _ p: Double) -> Double {
        let rank = p * Double(sorted.count - 1)
        let lowerIndex = Int(rank.rounded(.down))
        let upperIndex = Int(rank.rounded(.up))

        if lowerIndex == upperIndex {
            return sorted[lowerIndex]
        }

        // Linear interpolation between values
        let lowerValue = sorted[lowerIndex]
        let upperValue = sorted[upperIndex]
        let fraction = rank - Double(lowerIndex)
        return lowerValue + (upperValue - lowerValue) * fraction
    }
}

/// Statistics for a histogram
public struct HistogramStatistics: Sendable {
    /// Number of observations
    public let count: Int

    /// Sum of all observations
    public let sum: Double

    /// Mean value
    public let mean: Double

    /// Minimum value
    public let min: Double

    /// Maximum value
    public let max: Double

    /// 50th percentile (median)
    public let p50: Double

    /// 95th percentile
    public let p95: Double

    /// 99th percentile
    public let p99: Double
}
