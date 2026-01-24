import Foundation

/// Protocol for types that support delta encoding
public protocol DeltaCodable: Codable {
    /// Compute the delta from a previous value to this value
    func delta(from previous: Self) -> Self?

    /// Apply a delta to produce a new value
    func applying(delta: Self) -> Self
}

/// A delta-encoded state update
public struct StateDelta<T: DeltaCodable>: Codable, Sendable where T: Sendable {
    /// Whether this is a full state or a delta
    public let isFull: Bool

    /// The encoded value (either full state or delta)
    public let data: Data

    public init(isFull: Bool, data: Data) {
        self.isFull = isFull
        self.data = data
    }

    /// Create a full state delta
    public static func full(_ value: T, encoder: JSONEncoder = JSONEncoder()) throws -> StateDelta<T> {
        let data = try encoder.encode(value)
        return StateDelta(isFull: true, data: data)
    }

    /// Create a delta update
    public static func delta(_ value: T, encoder: JSONEncoder = JSONEncoder()) throws -> StateDelta<T> {
        let data = try encoder.encode(value)
        return StateDelta(isFull: false, data: data)
    }

    /// Decode the value
    public func decode(decoder: JSONDecoder = JSONDecoder()) throws -> T {
        try decoder.decode(T.self, from: data)
    }
}

/// Helper for managing delta encoding in streams
public actor DeltaStreamManager<T: DeltaCodable> where T: Sendable {
    private var lastSentValue: T?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init() {
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    /// Encode a value as either full state or delta
    public func encode(_ value: T, forceFull: Bool = false) throws -> StateDelta<T> {
        defer { lastSentValue = value }

        // Send full state if forced or no previous value
        guard !forceFull, let previous = lastSentValue else {
            return try .full(value, encoder: encoder)
        }

        // Try to compute delta
        if let delta = value.delta(from: previous) {
            return try .delta(delta, encoder: encoder)
        } else {
            // Fall back to full state if delta computation fails
            return try .full(value, encoder: encoder)
        }
    }

    /// Reset the manager (e.g., on new subscription)
    public func reset() {
        lastSentValue = nil
    }
}

/// Client-side delta applier
public actor DeltaStreamApplier<T: DeltaCodable> where T: Sendable {
    private var currentValue: T?
    private let decoder: JSONDecoder

    public init() {
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    /// Apply a delta update to get the current value
    public func apply(_ delta: StateDelta<T>) throws -> T {
        let decoded = try delta.decode(decoder: decoder)

        if delta.isFull {
            // Full state - replace current
            currentValue = decoded
            return decoded
        } else {
            // Delta - apply to current
            guard let current = currentValue else {
                throw DeltaError.noBaseValue
            }
            let updated = current.applying(delta: decoded)
            currentValue = updated
            return updated
        }
    }

    /// Get the current value
    public func current() -> T? {
        currentValue
    }
}

/// Errors that can occur during delta operations
public enum DeltaError: Error {
    case noBaseValue
    case deltaComputationFailed
    case deltaApplicationFailed
}
