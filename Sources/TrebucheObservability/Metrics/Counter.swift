// Counter.swift
// Counter metric type for tracking cumulative values

import Foundation

/// A counter metric that only increases
public actor Counter {
    /// Metric name
    public let name: String

    /// Current counter value by tag combination
    private var values: [TagKey: Int] = [:]

    /// Creates a new counter
    /// - Parameter name: Metric name
    public init(name: String) {
        self.name = name
    }

    /// Increments the counter
    /// - Parameters:
    ///   - value: Amount to increment by (must be >= 0)
    ///   - tags: Tags identifying this counter dimension
    public func increment(by value: Int = 1, tags: [String: String] = [:]) {
        guard value >= 0 else {
            assertionFailure("Counter can only be incremented by non-negative values")
            return
        }

        let key = TagKey(tags: tags)
        values[key, default: 0] += value
    }

    /// Gets the current counter value
    /// - Parameter tags: Tags to query
    /// - Returns: Current counter value
    public func value(for tags: [String: String] = [:]) -> Int {
        let key = TagKey(tags: tags)
        return values[key, default: 0]
    }

    /// Gets all counter values with their tags
    /// - Returns: Dictionary of tag combinations to values
    public func allValues() -> [(tags: [String: String], value: Int)] {
        values.map { (tags: $0.key.tags, value: $0.value) }
    }

    /// Resets the counter to zero
    public func reset() {
        values.removeAll()
    }
}

/// A gauge metric that can go up or down
public actor Gauge {
    /// Metric name
    public let name: String

    /// Current gauge value by tag combination
    private var values: [TagKey: Double] = [:]

    /// Creates a new gauge
    /// - Parameter name: Metric name
    public init(name: String) {
        self.name = name
    }

    /// Sets the gauge to a specific value
    /// - Parameters:
    ///   - value: New gauge value
    ///   - tags: Tags identifying this gauge dimension
    public func set(to value: Double, tags: [String: String] = [:]) {
        let key = TagKey(tags: tags)
        values[key] = value
    }

    /// Increments the gauge
    /// - Parameters:
    ///   - value: Amount to increment by
    ///   - tags: Tags identifying this gauge dimension
    public func increment(by value: Double = 1.0, tags: [String: String] = [:]) {
        let key = TagKey(tags: tags)
        values[key, default: 0.0] += value
    }

    /// Decrements the gauge
    /// - Parameters:
    ///   - value: Amount to decrement by
    ///   - tags: Tags identifying this gauge dimension
    public func decrement(by value: Double = 1.0, tags: [String: String] = [:]) {
        let key = TagKey(tags: tags)
        values[key, default: 0.0] -= value
    }

    /// Gets the current gauge value
    /// - Parameter tags: Tags to query
    /// - Returns: Current gauge value
    public func value(for tags: [String: String] = [:]) -> Double {
        let key = TagKey(tags: tags)
        return values[key, default: 0.0]
    }

    /// Gets all gauge values with their tags
    /// - Returns: Dictionary of tag combinations to values
    public func allValues() -> [(tags: [String: String], value: Double)] {
        values.map { (tags: $0.key.tags, value: $0.value) }
    }

    /// Resets the gauge to zero
    public func reset() {
        values.removeAll()
    }
}

/// Internal helper for using tags as dictionary keys
struct TagKey: Hashable, Sendable {
    let tags: [String: String]

    func hash(into hasher: inout Hasher) {
        // Sort keys for consistent hashing
        for (key, value) in tags.sorted(by: { $0.key < $1.key }) {
            hasher.combine(key)
            hasher.combine(value)
        }
    }

    static func == (lhs: TagKey, rhs: TagKey) -> Bool {
        lhs.tags == rhs.tags
    }
}
