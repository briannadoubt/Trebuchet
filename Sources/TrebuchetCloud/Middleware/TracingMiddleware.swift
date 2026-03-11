// TracingMiddleware.swift
// Distributed tracing middleware using swift-distributed-tracing

#if !os(WASI)
import Foundation
import Trebuchet
import Tracing

/// Middleware that creates server spans for distributed tracing.
///
/// Traces flow through the globally-bootstrapped `InstrumentationSystem`,
/// so no exporter configuration is needed on the middleware itself.
/// If the incoming envelope carries a `traceContext`, its trace and span IDs
/// are propagated into the `ServiceContext` for distributed correlation.
public final class TracingMiddleware: CloudMiddleware, Sendable {
    public init() {}

    public func process(
        _ envelope: InvocationEnvelope,
        actor: any DistributedActor,
        context: MiddlewareContext,
        next: @Sendable (InvocationEnvelope, MiddlewareContext) async throws -> ResponseEnvelope
    ) async throws -> ResponseEnvelope {
        var serviceContext = ServiceContext.current ?? .topLevel

        // Propagate trace context from the envelope if present
        if let tc = envelope.traceContext {
            serviceContext.trebuchetTraceID = tc.traceID.uuidString
            serviceContext.trebuchetSpanID = tc.spanID.uuidString
        }

        return try await withSpan(
            "\(envelope.actorID.id)/\(envelope.targetIdentifier)",
            context: serviceContext,
            ofKind: .server
        ) { span in
            span.attributes["rpc.system"] = "trebuchet"
            span.attributes["rpc.method"] = envelope.targetIdentifier
            span.attributes["trebuchet.actor_id"] = envelope.actorID.id
            span.attributes["trebuchet.call_id"] = envelope.callID.uuidString

            do {
                let response = try await next(envelope, context)
                return response
            } catch {
                span.recordError(error)
                throw error
            }
        }
    }
}
#endif
