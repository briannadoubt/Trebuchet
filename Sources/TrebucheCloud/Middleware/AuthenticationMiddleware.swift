// AuthenticationMiddleware.swift
// Authentication middleware

import Foundation
import Trebuche
import TrebucheSecurity

/// Middleware that authenticates requests
public struct AuthenticationMiddleware: CloudMiddleware {
    private let provider: any AuthenticationProvider
    private let credentialsExtractor: @Sendable (InvocationEnvelope) -> Credentials?

    /// Creates an authentication middleware
    /// - Parameters:
    ///   - provider: Authentication provider
    ///   - credentialsExtractor: Function to extract credentials from envelope
    public init(
        provider: any AuthenticationProvider,
        credentialsExtractor: @escaping @Sendable (InvocationEnvelope) -> Credentials? = { _ in nil }
    ) {
        self.provider = provider
        self.credentialsExtractor = credentialsExtractor
    }

    public func process(
        _ envelope: InvocationEnvelope,
        actor: any DistributedActor,
        context: MiddlewareContext,
        next: @Sendable (InvocationEnvelope, MiddlewareContext) async throws -> ResponseEnvelope
    ) async throws -> ResponseEnvelope {
        // Extract credentials
        guard let credentials = credentialsExtractor(envelope) else {
            throw AuthenticationError.invalidCredentials
        }

        // Authenticate
        let principal = try await provider.authenticate(credentials)

        // Check expiration
        guard !principal.isExpired else {
            throw AuthenticationError.expired
        }

        // Store principal in context
        var newContext = context
        newContext.principal = AnyPrincipal(principal)
        newContext.metadata["principal.id"] = principal.id
        newContext.metadata["principal.type"] = principal.type.rawValue

        return try await next(envelope, newContext)
    }
}

/// Optional authentication middleware (doesn't fail if no credentials)
public struct OptionalAuthenticationMiddleware: CloudMiddleware {
    private let provider: any AuthenticationProvider
    private let credentialsExtractor: @Sendable (InvocationEnvelope) -> Credentials?

    /// Creates an optional authentication middleware
    /// - Parameters:
    ///   - provider: Authentication provider
    ///   - credentialsExtractor: Function to extract credentials from envelope
    public init(
        provider: any AuthenticationProvider,
        credentialsExtractor: @escaping @Sendable (InvocationEnvelope) -> Credentials? = { _ in nil }
    ) {
        self.provider = provider
        self.credentialsExtractor = credentialsExtractor
    }

    public func process(
        _ envelope: InvocationEnvelope,
        actor: any DistributedActor,
        context: MiddlewareContext,
        next: @Sendable (InvocationEnvelope, MiddlewareContext) async throws -> ResponseEnvelope
    ) async throws -> ResponseEnvelope {
        var newContext = context

        // Try to authenticate if credentials present
        if let credentials = credentialsExtractor(envelope) {
            do {
                let principal = try await provider.authenticate(credentials)
                if !principal.isExpired {
                    newContext.principal = AnyPrincipal(principal)
                    newContext.metadata["principal.id"] = principal.id
                    newContext.metadata["principal.type"] = principal.type.rawValue
                }
            } catch {
                // Ignore authentication errors in optional mode
            }
        }

        return try await next(envelope, newContext)
    }
}
