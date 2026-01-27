import Foundation

/// A filter that can be applied to streams to reduce bandwidth
public struct StreamFilter: Codable, Sendable {
    /// Filter type discriminator
    public enum FilterType: String, Codable, Sendable {
        case all           // No filtering (default)
        case predefined    // Use a predefined filter by name
        case custom        // Custom filter (not yet supported over wire)
    }

    public let type: FilterType
    public let name: String?     // For predefined filters
    public let parameters: [String: String]?  // Filter parameters

    public init(type: FilterType, name: String? = nil, parameters: [String: String]? = nil) {
        self.type = type
        self.name = name
        self.parameters = parameters
    }

    /// No filtering - pass through all updates
    public static var all: StreamFilter {
        StreamFilter(type: .all)
    }

    /// Create a predefined filter
    public static func predefined(_ name: String, parameters: [String: String] = [:]) -> StreamFilter {
        StreamFilter(type: .predefined, name: name, parameters: parameters)
    }

    /// Check if data passes this filter
    /// - Parameters:
    ///   - data: Encoded data to check
    ///   - previousData: Previous data value (for "changed" filter)
    ///   - decoded: Optional pre-decoded JSON value (performance optimization)
    /// - Returns: true if data should be sent, false if it should be filtered out
    ///
    /// ## Performance Optimization
    ///
    /// For high-frequency streams, you can avoid double deserialization by passing
    /// the already-decoded JSON value:
    ///
    /// ```swift
    /// let data = try JSONEncoder().encode(state)
    /// let decoded = try JSONSerialization.jsonObject(with: data)
    ///
    /// // Check filter with pre-decoded value (avoids re-deserializing)
    /// if filter.matches(data, decoded: decoded) {
    ///     // Send data...
    /// }
    /// ```
    ///
    /// This is especially beneficial at high update rates (100+ updates/sec) where
    /// the cost of JSON deserialization becomes significant.
    public func matches(_ data: Data, previousData: Data? = nil, decoded: Any? = nil) -> Bool {
        switch type {
        case .all:
            return true

        case .predefined:
            guard let filterName = name else {
                return true  // No filter name, pass through
            }

            return matchesPredefined(filterName, data: data, previousData: previousData, decoded: decoded)

        case .custom:
            // Custom filters cannot be sent over the wire
            return true
        }
    }

    /// Match against predefined filters
    private func matchesPredefined(_ filterName: String, data: Data, previousData: Data?, decoded: Any?) -> Bool {
        switch filterName {
        case PredefinedFilters.changed:
            // Only pass if data changed from previous
            guard let previous = previousData else {
                return true  // No previous data, pass through
            }
            return data != previous

        case PredefinedFilters.nonEmpty:
            // Try to decode as JSON and check if collection is non-empty
            return matchesNonEmpty(data: data, decoded: decoded)

        case PredefinedFilters.threshold:
            // Try to decode as numeric and compare to threshold
            return matchesThreshold(data: data, decoded: decoded)

        default:
            // Unknown filter, pass through
            return true
        }
    }

    /// Check if data represents a non-empty collection
    private func matchesNonEmpty(data: Data, decoded: Any?) -> Bool {
        // Use pre-decoded value if available (performance optimization)
        let json: Any
        if let decoded = decoded {
            json = decoded
        } else {
            do {
                json = try JSONSerialization.jsonObject(with: data)
            } catch {
                // If we can't decode, pass through
                return true
            }
        }

        // Check if it's an array
        if let array = json as? [Any] {
            return !array.isEmpty
        }

        // Check if it's a dictionary
        if let dict = json as? [String: Any] {
            return !dict.isEmpty
        }

        // Check if it's a string
        if let string = json as? String {
            return !string.isEmpty
        }

        // For other types, consider non-empty
        return true
    }

    /// Check if numeric value crosses threshold
    private func matchesThreshold(data: Data, decoded: Any?) -> Bool {
        guard let thresholdStr = parameters?["value"],
              let threshold = Double(thresholdStr) else {
            // No threshold parameter, pass through
            return true
        }

        // Use pre-decoded value if available (performance optimization)
        let json: Any
        if let decoded = decoded {
            json = decoded
        } else {
            do {
                json = try JSONSerialization.jsonObject(with: data)
            } catch {
                // If we can't decode, pass through
                return true
            }
        }

        // Try to extract numeric value
        let value: Double

        if let num = json as? Double {
            value = num
        } else if let num = json as? Int {
            value = Double(num)
        } else if let dict = json as? [String: Any],
                  let field = parameters?["field"],
                  let fieldValue = dict[field] {
            if let num = fieldValue as? Double {
                value = num
            } else if let num = fieldValue as? Int {
                value = Double(num)
            } else {
                return true  // Can't extract numeric value
            }
        } else {
            return true  // Can't extract numeric value
        }

        // Compare to threshold
        let comparison = parameters?["comparison"] ?? "gt"
        switch comparison {
        case "gt", ">":
            return value > threshold
        case "gte", ">=":
            return value >= threshold
        case "lt", "<":
            return value < threshold
        case "lte", "<=":
            return value <= threshold
        case "eq", "==":
            return value == threshold
        case "neq", "!=":
            return value != threshold
        default:
            return value > threshold  // Default to greater than
        }
    }
}

/// Protocol for types that support stream filtering
public protocol Filterable {
    /// Check if this value matches the given filter
    func matches(filter: StreamFilter) -> Bool
}

/// Common predefined filters
public enum PredefinedFilters {
    /// Filter IDs for well-known filters
    public static let changed = "changed"      // Only send when value changed
    public static let nonEmpty = "nonEmpty"    // Only send non-empty collections
    public static let threshold = "threshold"  // Only send when value crosses threshold
}

// MARK: - Stream Filter State

/// Tracks state for filters that require previous values (like "changed")
public actor StreamFilterState {
    private var previousValues: [UUID: Data] = [:]

    public init() {}

    /// Apply a filter with state tracking
    /// - Parameters:
    ///   - filter: The filter to apply
    ///   - data: Current data
    ///   - streamID: Stream identifier for tracking previous values
    /// - Returns: true if data should be sent, false if filtered out
    public func matches(_ filter: StreamFilter, data: Data, streamID: UUID) -> Bool {
        let previous = previousValues[streamID]
        let result = filter.matches(data, previousData: previous)

        // Update previous value for next comparison
        if result {
            previousValues[streamID] = data
        }

        return result
    }

    /// Clear state for a completed stream
    public func clearState(for streamID: UUID) {
        previousValues.removeValue(forKey: streamID)
    }

    /// Clear all state
    public func clearAllState() {
        previousValues.removeAll()
    }
}
