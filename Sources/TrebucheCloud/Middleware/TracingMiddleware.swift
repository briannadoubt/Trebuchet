// TracingMiddleware.swift
// Distributed tracing middleware

import Foundation
import Trebuchet
import TrebuchetObservability

/// Middleware that creates and exports spans for distributed tracing
public struct TracingMiddleware: CloudMiddleware {
    private let exporter: any SpanExporter
    private let logExportErrors: Bool

    /// Creates a tracing middleware
    /// - Parameters:
    ///   - exporter: Span exporter
    ///   - logExportErrors: Whether to log export errors to stderr (default: true)
    public init(exporter: any SpanExporter = InMemorySpanExporter(), logExportErrors: Bool = true) {
        self.exporter = exporter
        self.logExportErrors = logExportErrors
    }

    public func process(
        _ envelope: InvocationEnvelope,
        actor: any DistributedActor,
        context: MiddlewareContext,
        next: @Sendable (InvocationEnvelope, MiddlewareContext) async throws -> ResponseEnvelope
    ) async throws -> ResponseEnvelope {
        // Get or create trace context
        let traceContext = envelope.traceContext ?? TraceContext()

        // Create span for this invocation
        var span = Span(
            context: traceContext,
            name: "\(envelope.actorID.id).\(envelope.targetIdentifier)",
            kind: .server,
            startTime: Date()
        )

        // Add attributes
        span.setAttribute("actor.id", value: envelope.actorID.id)
        span.setAttribute("actor.target", value: envelope.targetIdentifier)
        span.setAttribute("call.id", value: envelope.callID.uuidString)

        do {
            // Execute with tracing
            let response = try await next(envelope, context)

            // Mark success
            span.end(status: .ok)
            await exportSpan(span)

            return response
        } catch {
            // Mark error
            span.setAttribute("error.type", value: String(describing: type(of: error)))
            span.setAttribute("error.message", value: String(describing: error))
            span.end(status: .error)
            await exportSpan(span)

            throw error
        }
    }

    /// Exports a span, logging errors without failing the request
    private func exportSpan(_ span: Span) async {
        do {
            try await exporter.export([span])
        } catch {
            if logExportErrors {
                let message = "⚠️  TracingMiddleware: Failed to export span '\(span.name)': \(error)\n"
                if let data = message.data(using: .utf8) {
                    try? FileHandle.standardError.write(contentsOf: data)
                }
            }
        }
    }
}
