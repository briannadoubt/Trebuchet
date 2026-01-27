// LogContext.swift
// Structured context for log messages

import Foundation

/// Structured metadata context for log messages
public struct LogContext: Sendable, Codable {
    /// Key-value metadata attached to the log message
    public var metadata: [String: String]

    /// Timestamp when the log was created
    public let timestamp: Date

    /// Label identifying the source of the log (e.g., actor type, component name)
    public let label: String

    /// Optional correlation ID for tracking related log messages across distributed calls
    public var correlationID: UUID?

    /// Creates a new log context
    /// - Parameters:
    ///   - label: Identifier for the log source
    ///   - metadata: Key-value metadata
    ///   - correlationID: Optional correlation ID for distributed tracing
    public init(
        label: String,
        metadata: [String: String] = [:],
        correlationID: UUID? = nil
    ) {
        self.label = label
        self.metadata = metadata
        self.correlationID = correlationID
        self.timestamp = Date()
    }
}
