// TraceContext.swift
// Lightweight trace context for distributed request tracking

import Foundation

/// Trace context for distributed request tracking
public struct TraceContext: Sendable, Codable, Hashable {
    /// Unique identifier for the entire trace
    public let traceID: UUID

    /// Unique identifier for this span
    public let spanID: UUID

    /// Parent span ID if this is a child span
    public let parentSpanID: UUID?

    /// Creates a new root trace context
    public init(traceID: UUID = UUID(), spanID: UUID = UUID()) {
        self.traceID = traceID
        self.spanID = spanID
        self.parentSpanID = nil
    }

    /// Creates a child trace context
    public init(parent: TraceContext, spanID: UUID = UUID()) {
        self.traceID = parent.traceID
        self.spanID = spanID
        self.parentSpanID = parent.spanID
    }

    /// Creates a child span from this context
    public func createChild(spanID: UUID = UUID()) -> TraceContext {
        TraceContext(parent: self, spanID: spanID)
    }
}
