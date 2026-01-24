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
    /// - Parameter data: Encoded data to check
    /// - Returns: true if data should be sent, false if it should be filtered out
    public func matches(_ data: Data) -> Bool {
        switch type {
        case .all:
            return true
        case .predefined:
            // TODO: Implement predefined filters (changed, nonEmpty, threshold)
            // For now, pass all data through
            // Full implementation requires decoding the data and tracking state
            return true
        case .custom:
            // Custom filters cannot be sent over the wire
            return true
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
