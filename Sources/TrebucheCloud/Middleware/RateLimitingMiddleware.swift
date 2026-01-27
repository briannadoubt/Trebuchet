// RateLimitingMiddleware.swift
// Rate limiting middleware

import Foundation
import Trebuche
import TrebucheSecurity

/// Middleware that enforces rate limits
public struct RateLimitingMiddleware: CloudMiddleware {
    private let limiter: any RateLimiter
    private let keyExtractor: @Sendable (InvocationEnvelope, MiddlewareContext) -> String
    private let costExtractor: @Sendable (InvocationEnvelope) -> Int

    /// Creates a rate limiting middleware
    /// - Parameters:
    ///   - limiter: Rate limiter implementation
    ///   - keyExtractor: Function to extract rate limit key
    ///   - costExtractor: Function to calculate request cost
    public init(
        limiter: any RateLimiter,
        keyExtractor: @escaping @Sendable (InvocationEnvelope, MiddlewareContext) -> String = { envelope, context in
            // Default: rate limit by principal if available, otherwise use global anonymous key
            // Using a global key prevents bypass attacks where unauthenticated users
            // could use different actor IDs to evade rate limits
            if let principalID = context.metadata["principal.id"] {
                return "principal:\(principalID)"
            } else {
                return "anonymous:global"
            }
        },
        costExtractor: @escaping @Sendable (InvocationEnvelope) -> Int = { _ in 1 }
    ) {
        self.limiter = limiter
        self.keyExtractor = keyExtractor
        self.costExtractor = costExtractor
    }

    public func process(
        _ envelope: InvocationEnvelope,
        actor: any DistributedActor,
        context: MiddlewareContext,
        next: @Sendable (InvocationEnvelope, MiddlewareContext) async throws -> ResponseEnvelope
    ) async throws -> ResponseEnvelope {
        // Extract rate limit key and cost
        let key = keyExtractor(envelope, context)
        let cost = costExtractor(envelope)

        // Check rate limit
        let result = try await limiter.checkLimit(key: key, cost: cost)

        // Add rate limit metadata
        var newContext = context
        newContext.metadata["ratelimit.key"] = key
        newContext.metadata["ratelimit.remaining"] = String(result.remaining)
        newContext.metadata["ratelimit.reset"] = ISO8601DateFormatter().string(from: result.resetAt)

        // Enforce limit
        guard result.allowed else {
            throw RateLimitError.limitExceeded(retryAfter: result.retryAfter ?? .seconds(60))
        }

        return try await next(envelope, newContext)
    }
}

/// Per-principal rate limiting
public extension RateLimitingMiddleware {
    /// Create middleware that rate limits by principal ID
    static func perPrincipal(
        limiter: any RateLimiter,
        costExtractor: @escaping @Sendable (InvocationEnvelope) -> Int = { _ in 1 }
    ) -> RateLimitingMiddleware {
        RateLimitingMiddleware(
            limiter: limiter,
            keyExtractor: { _, context in
                context.metadata["principal.id"] ?? "anonymous"
            },
            costExtractor: costExtractor
        )
    }
}

/// Per-actor rate limiting
public extension RateLimitingMiddleware {
    /// Create middleware that rate limits by actor ID
    static func perActor(
        limiter: any RateLimiter,
        costExtractor: @escaping @Sendable (InvocationEnvelope) -> Int = { _ in 1 }
    ) -> RateLimitingMiddleware {
        RateLimitingMiddleware(
            limiter: limiter,
            keyExtractor: { envelope, _ in
                envelope.actorID.id
            },
            costExtractor: costExtractor
        )
    }
}

/// Global rate limiting
public extension RateLimitingMiddleware {
    /// Create middleware that rate limits globally
    static func global(
        limiter: any RateLimiter,
        costExtractor: @escaping @Sendable (InvocationEnvelope) -> Int = { _ in 1 }
    ) -> RateLimitingMiddleware {
        RateLimitingMiddleware(
            limiter: limiter,
            keyExtractor: { _, _ in "global" },
            costExtractor: costExtractor
        )
    }
}
