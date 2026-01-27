// SpanExporter.swift
// Protocol for exporting spans to tracing backends

import Foundation

/// Protocol for exporting spans to tracing backends
public protocol SpanExporter: Sendable {
    /// Exports a batch of spans
    /// - Parameter spans: Spans to export
    func export(_ spans: [Span]) async throws

    /// Shuts down the exporter
    func shutdown() async throws
}

/// In-memory span exporter for testing
public actor InMemorySpanExporter: SpanExporter {
    private var exportedSpans: [Span] = []

    /// Creates a new in-memory exporter
    public init() {}

    public func export(_ spans: [Span]) async throws {
        exportedSpans.append(contentsOf: spans)
    }

    public func shutdown() async throws {
        // Nothing to shut down
    }

    /// Gets all exported spans
    /// - Returns: Array of exported spans
    public func getExportedSpans() -> [Span] {
        exportedSpans
    }

    /// Resets the exporter
    public func reset() {
        exportedSpans.removeAll()
    }
}

/// Console span exporter (prints to stdout)
public struct ConsoleSpanExporter: SpanExporter {
    /// Creates a new console exporter
    public init() {}

    public func export(_ spans: [Span]) async throws {
        for span in spans {
            print("[TRACE] \(formatSpan(span))")
        }
    }

    public func shutdown() async throws {
        // Nothing to shut down
    }

    private func formatSpan(_ span: Span) -> String {
        let duration = span.duration.map { "\($0)" } ?? "active"
        let status = span.status.rawValue
        let attrs = span.attributes.isEmpty ? "" : " attrs=\(span.attributes)"

        return "\(span.name) [\(span.kind.rawValue)] trace=\(span.context.traceID) span=\(span.context.spanID) duration=\(duration) status=\(status)\(attrs)"
    }
}
