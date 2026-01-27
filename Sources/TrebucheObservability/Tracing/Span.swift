// Span.swift
// Span representing a single operation in a distributed trace

import Foundation
import Trebuche

/// Span representing a single operation in the trace
public struct Span: Sendable {
    /// Trace context for this span
    public let context: TraceContext

    /// Operation name (e.g., "invocation", "database_query")
    public let name: String

    /// Span kind (client, server, internal, etc.)
    public let kind: SpanKind

    /// Start time
    public let startTime: Date

    /// End time (nil if span is still active)
    public private(set) var endTime: Date?

    /// Status of the span
    public private(set) var status: SpanStatus

    /// Attributes attached to the span
    public private(set) var attributes: [String: String]

    /// Events recorded during the span
    public private(set) var events: [SpanEvent]

    /// Creates a new span
    /// - Parameters:
    ///   - context: Trace context
    ///   - name: Operation name
    ///   - kind: Span kind
    ///   - startTime: Start time (defaults to now)
    public init(
        context: TraceContext,
        name: String,
        kind: SpanKind = .internal,
        startTime: Date = Date()
    ) {
        self.context = context
        self.name = name
        self.kind = kind
        self.startTime = startTime
        self.endTime = nil
        self.status = .unset
        self.attributes = [:]
        self.events = []
    }

    /// Ends the span
    /// - Parameters:
    ///   - endTime: End time (defaults to now)
    ///   - status: Final status
    public mutating func end(endTime: Date = Date(), status: SpanStatus = .ok) {
        self.endTime = endTime
        self.status = status
    }

    /// Adds an attribute to the span
    /// - Parameters:
    ///   - key: Attribute key
    ///   - value: Attribute value
    public mutating func setAttribute(_ key: String, value: String) {
        attributes[key] = value
    }

    /// Records an event during the span
    /// - Parameter event: Event to record
    public mutating func addEvent(_ event: SpanEvent) {
        events.append(event)
    }

    /// Duration of the span
    public var duration: Duration? {
        guard let endTime else { return nil }
        let interval = endTime.timeIntervalSince(startTime)
        return .milliseconds(Int(interval * 1000))
    }
}

/// Kind of span
public enum SpanKind: String, Sendable, Codable {
    /// Internal operation
    case `internal`

    /// Client-side operation (outgoing request)
    case client

    /// Server-side operation (incoming request)
    case server

    /// Producer (message queue)
    case producer

    /// Consumer (message queue)
    case consumer
}

/// Status of a span
public enum SpanStatus: String, Sendable, Codable {
    /// Span status has not been set
    case unset

    /// Span completed successfully
    case ok

    /// Span encountered an error
    case error
}

/// Event recorded during a span
public struct SpanEvent: Sendable {
    /// Event name
    public let name: String

    /// Event timestamp
    public let timestamp: Date

    /// Event attributes
    public let attributes: [String: String]

    /// Creates a new span event
    /// - Parameters:
    ///   - name: Event name
    ///   - timestamp: Event timestamp (defaults to now)
    ///   - attributes: Event attributes
    public init(
        name: String,
        timestamp: Date = Date(),
        attributes: [String: String] = [:]
    ) {
        self.name = name
        self.timestamp = timestamp
        self.attributes = attributes
    }
}
