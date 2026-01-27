// CloudMiddleware.swift
// Middleware protocol for CloudGateway

import Foundation
import Trebuchet
import TrebuchetSecurity

/// Type-erased principal wrapper
public struct AnyPrincipal: Sendable {
    private let storage: any Sendable

    /// The underlying principal
    public var principal: Principal {
        storage as! Principal
    }

    /// Creates a type-erased principal
    public init(_ principal: Principal) {
        self.storage = principal
    }
}

/// Context passed through middleware chain
public struct MiddlewareContext: Sendable {
    /// Metadata accumulated during middleware processing
    public var metadata: [String: String]

    /// Correlation ID for tracing
    public var correlationID: UUID

    /// Request timestamp
    public var timestamp: Date

    /// Authenticated principal (if any)
    public var principal: AnyPrincipal?

    /// Creates a new middleware context
    public init(
        metadata: [String: String] = [:],
        correlationID: UUID = UUID(),
        timestamp: Date = Date(),
        principal: AnyPrincipal? = nil
    ) {
        self.metadata = metadata
        self.correlationID = correlationID
        self.timestamp = timestamp
        self.principal = principal
    }
}

/// Middleware for processing actor invocations
///
/// Middleware runs in a chain, allowing each to:
/// - Inspect/modify the request
/// - Add metadata to the context
/// - Short-circuit processing (e.g., auth failure)
/// - Wrap the response (e.g., add timing)
///
/// Example middleware:
/// ```swift
/// struct LoggingMiddleware: CloudMiddleware {
///     func process(
///         _ envelope: InvocationEnvelope,
///         actor: any DistributedActor,
///         context: MiddlewareContext,
///         next: @Sendable (InvocationEnvelope, MiddlewareContext) async throws -> ResponseEnvelope
///     ) async throws -> ResponseEnvelope {
///         print("Processing: \(envelope.targetIdentifier)")
///         let response = try await next(envelope, context)
///         print("Completed: \(envelope.targetIdentifier)")
///         return response
///     }
/// }
/// ```
public protocol CloudMiddleware: Sendable {
    /// Process an invocation
    /// - Parameters:
    ///   - envelope: The invocation envelope
    ///   - actor: The target actor
    ///   - context: Middleware context
    ///   - next: Call to proceed to next middleware/handler
    /// - Returns: Response envelope
    func process(
        _ envelope: InvocationEnvelope,
        actor: any DistributedActor,
        context: MiddlewareContext,
        next: @Sendable (InvocationEnvelope, MiddlewareContext) async throws -> ResponseEnvelope
    ) async throws -> ResponseEnvelope
}

/// Middleware chain executor
public struct MiddlewareChain: Sendable {
    private let middlewares: [any CloudMiddleware]

    /// Creates a middleware chain
    /// - Parameter middlewares: Middlewares in execution order
    public init(middlewares: [any CloudMiddleware]) {
        self.middlewares = middlewares
    }

    /// Execute the middleware chain
    /// - Parameters:
    ///   - envelope: Invocation envelope
    ///   - actor: Target actor
    ///   - context: Initial context
    ///   - handler: Final handler after all middleware
    /// - Returns: Response envelope
    public func execute(
        _ envelope: InvocationEnvelope,
        actor: any DistributedActor,
        context: MiddlewareContext,
        handler: @escaping @Sendable (InvocationEnvelope, MiddlewareContext) async throws -> ResponseEnvelope
    ) async throws -> ResponseEnvelope {
        // Build chain from bottom up
        var current = handler

        // Wrap each middleware around the handler
        for middleware in middlewares.reversed() {
            let next = current
            current = { envelope, context in
                try await middleware.process(envelope, actor: actor, context: context, next: next)
            }
        }

        // Execute the chain
        return try await current(envelope, context)
    }
}
