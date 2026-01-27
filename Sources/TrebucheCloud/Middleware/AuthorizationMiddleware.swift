// AuthorizationMiddleware.swift
// Authorization middleware

import Foundation
import Trebuche
import TrebucheSecurity

/// Middleware that authorizes requests
public struct AuthorizationMiddleware: CloudMiddleware {
    private let policy: any AuthorizationPolicy
    private let actionExtractor: @Sendable (InvocationEnvelope) -> Action
    private let resourceExtractor: @Sendable (InvocationEnvelope) -> Resource

    /// Creates an authorization middleware
    /// - Parameters:
    ///   - policy: Authorization policy
    ///   - actionExtractor: Function to extract action from envelope
    ///   - resourceExtractor: Function to extract resource from envelope
    public init(
        policy: any AuthorizationPolicy,
        actionExtractor: @escaping @Sendable (InvocationEnvelope) -> Action = { envelope in
            Action(
                actorType: String(describing: type(of: envelope.actorID)),
                method: envelope.targetIdentifier
            )
        },
        resourceExtractor: @escaping @Sendable (InvocationEnvelope) -> Resource = { envelope in
            Resource(type: "actor", id: envelope.actorID.id)
        }
    ) {
        self.policy = policy
        self.actionExtractor = actionExtractor
        self.resourceExtractor = resourceExtractor
    }

    public func process(
        _ envelope: InvocationEnvelope,
        actor: any DistributedActor,
        context: MiddlewareContext,
        next: @Sendable (InvocationEnvelope, MiddlewareContext) async throws -> ResponseEnvelope
    ) async throws -> ResponseEnvelope {
        // Get principal from context
        guard let anyPrincipal = context.principal else {
            throw AuthorizationError.accessDenied
        }
        let principal = anyPrincipal.principal

        // Extract action and resource
        let action = actionExtractor(envelope)
        let resource = resourceExtractor(envelope)

        // Authorize
        let authorized = try await policy.authorize(principal, action: action, resource: resource)

        guard authorized else {
            throw AuthorizationError.accessDenied
        }

        // Add authorization metadata
        var newContext = context
        newContext.metadata["authorization.action"] = "\(action.actorType).\(action.method)"
        newContext.metadata["authorization.resource"] = resource.type

        return try await next(envelope, newContext)
    }
}

/// Optional authorization middleware (allows anonymous access if no principal)
public struct OptionalAuthorizationMiddleware: CloudMiddleware {
    private let policy: any AuthorizationPolicy
    private let actionExtractor: @Sendable (InvocationEnvelope) -> Action
    private let resourceExtractor: @Sendable (InvocationEnvelope) -> Resource
    private let allowAnonymous: Bool

    /// Creates an optional authorization middleware
    /// - Parameters:
    ///   - policy: Authorization policy
    ///   - actionExtractor: Function to extract action from envelope
    ///   - resourceExtractor: Function to extract resource from envelope
    ///   - allowAnonymous: Allow requests without a principal
    public init(
        policy: any AuthorizationPolicy,
        actionExtractor: @escaping @Sendable (InvocationEnvelope) -> Action = { envelope in
            Action(
                actorType: String(describing: type(of: envelope.actorID)),
                method: envelope.targetIdentifier
            )
        },
        resourceExtractor: @escaping @Sendable (InvocationEnvelope) -> Resource = { envelope in
            Resource(type: "actor", id: envelope.actorID.id)
        },
        allowAnonymous: Bool = true
    ) {
        self.policy = policy
        self.actionExtractor = actionExtractor
        self.resourceExtractor = resourceExtractor
        self.allowAnonymous = allowAnonymous
    }

    public func process(
        _ envelope: InvocationEnvelope,
        actor: any DistributedActor,
        context: MiddlewareContext,
        next: @Sendable (InvocationEnvelope, MiddlewareContext) async throws -> ResponseEnvelope
    ) async throws -> ResponseEnvelope {
        // Check if we have a principal
        if let anyPrincipal = context.principal {
            let principal = anyPrincipal.principal

            // Authorize if principal exists
            let action = actionExtractor(envelope)
            let resource = resourceExtractor(envelope)

            let authorized = try await policy.authorize(principal, action: action, resource: resource)

            guard authorized else {
                throw AuthorizationError.accessDenied
            }

            var newContext = context
            newContext.metadata["authorization.action"] = "\(action.actorType).\(action.method)"
            newContext.metadata["authorization.resource"] = resource.type

            return try await next(envelope, newContext)
        } else if allowAnonymous {
            // Allow anonymous access
            return try await next(envelope, context)
        } else {
            // No principal and anonymous not allowed
            throw AuthorizationError.accessDenied
        }
    }
}
