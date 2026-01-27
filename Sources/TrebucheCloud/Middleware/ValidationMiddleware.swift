// ValidationMiddleware.swift
// Request validation middleware

import Foundation
import Trebuchet
import TrebuchetSecurity

/// Middleware that validates requests
public struct ValidationMiddleware: CloudMiddleware {
    private let validator: RequestValidator

    /// Creates a validation middleware
    /// - Parameter validator: Request validator
    public init(validator: RequestValidator = RequestValidator()) {
        self.validator = validator
    }

    /// Creates validation middleware with configuration
    /// - Parameter configuration: Validation configuration
    public init(configuration: ValidationConfiguration) {
        self.validator = RequestValidator(configuration: configuration)
    }

    public func process(
        _ envelope: InvocationEnvelope,
        actor: any DistributedActor,
        context: MiddlewareContext,
        next: @Sendable (InvocationEnvelope, MiddlewareContext) async throws -> ResponseEnvelope
    ) async throws -> ResponseEnvelope {
        // Validate envelope
        try validator.validateEnvelope(
            actorID: envelope.actorID.id,
            methodName: envelope.targetIdentifier,
            arguments: envelope.arguments
        )

        // Add validation metadata
        var newContext = context
        newContext.metadata["validation.passed"] = "true"

        return try await next(envelope, newContext)
    }
}

/// Preset validation middleware
public extension ValidationMiddleware {
    /// Default validation (balanced limits)
    static let `default` = ValidationMiddleware(configuration: .default)

    /// Permissive validation (larger limits)
    static let permissive = ValidationMiddleware(configuration: .permissive)

    /// Strict validation (smaller limits)
    static let strict = ValidationMiddleware(configuration: .strict)
}
