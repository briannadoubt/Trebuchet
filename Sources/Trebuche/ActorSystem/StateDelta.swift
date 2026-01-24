import Foundation

/// Protocol for types that support delta encoding
///
/// ## Example Implementation
///
/// ```swift
/// struct Counter: DeltaCodable {
///     let count: Int
///
///     func delta(from previous: Counter) -> Counter? {
///         let diff = count - previous.count
///         return diff != 0 ? Counter(count: diff) : nil
///     }
///
///     func applying(delta: Counter) -> Counter {
///         Counter(count: count + delta.count)
///     }
/// }
/// ```
public protocol DeltaCodable: Codable {
    /// Compute the delta from a previous value to this value
    /// - Parameter previous: The previous value to compute delta from
    /// - Returns: A delta representing the change, or nil if no change
    func delta(from previous: Self) -> Self?

    /// Apply a delta to produce a new value
    /// - Parameter delta: The delta to apply
    /// - Returns: A new value with the delta applied
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

// MARK: - Stream Helpers

extension AsyncStream where Element: DeltaCodable & Sendable {
    /// Convert a regular state stream to a delta-encoded stream
    /// - Returns: A stream that sends full state first, then deltas
    public func withDeltaEncoding() -> AsyncStream<StateDelta<Element>> {
        AsyncStream<StateDelta<Element>> { continuation in
            Task {
                let manager = DeltaStreamManager<Element>()

                for await value in self {
                    do {
                        let delta = try await manager.encode(value)
                        continuation.yield(delta)
                    } catch {
                        // On error, send full state
                        if let fullDelta = try? StateDelta<Element>.full(value) {
                            continuation.yield(fullDelta)
                        }
                    }
                }

                continuation.finish()
            }
        }
    }
}

extension AsyncStream where Element: Codable & Sendable {
    /// Decode a delta-encoded stream back to regular state stream
    /// - Returns: A stream that applies deltas to produce full state values
    public func decodingDeltas<T: DeltaCodable & Sendable>() -> AsyncStream<T> where Element == StateDelta<T> {
        AsyncStream<T> { continuation in
            Task {
                let applier = DeltaStreamApplier<T>()

                for await delta in self {
                    do {
                        let value = try await applier.apply(delta)
                        continuation.yield(value)
                    } catch {
                        // On error, skip this update
                        continue
                    }
                }

                continuation.finish()
            }
        }
    }
}
