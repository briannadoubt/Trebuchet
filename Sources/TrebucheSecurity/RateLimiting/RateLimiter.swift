// RateLimiter.swift
// Rate limiting protocol and types

import Foundation

/// Result of a rate limit check
public struct RateLimitResult: Sendable {
    /// Whether the request is allowed
    public let allowed: Bool

    /// Remaining requests in current window
    public let remaining: Int

    /// When the rate limit resets
    public let resetAt: Date

    /// Optional retry-after duration if denied
    public var retryAfter: Duration? {
        guard !allowed else { return nil }
        return Duration.seconds(resetAt.timeIntervalSinceNow)
    }

    public init(allowed: Bool, remaining: Int, resetAt: Date) {
        self.allowed = allowed
        self.remaining = remaining
        self.resetAt = resetAt
    }
}

/// Rate limiting errors
public enum RateLimitError: Error, Sendable {
    /// Rate limit exceeded
    case limitExceeded(retryAfter: Duration)

    /// Invalid configuration
    case invalidConfiguration(reason: String)

    /// Custom error
    case custom(message: String)
}

extension RateLimitError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .limitExceeded(let retryAfter):
            return "Rate limit exceeded. Retry after \(retryAfter)"
        case .invalidConfiguration(let reason):
            return "Invalid rate limit configuration: \(reason)"
        case .custom(let message):
            return message
        }
    }
}

/// Protocol for rate limiting implementations
public protocol RateLimiter: Sendable {
    /// Check if a request is allowed under the rate limit
    /// - Parameters:
    ///   - key: Rate limit key (e.g., user ID, IP address)
    ///   - cost: Cost of this request (default: 1)
    /// - Returns: Result indicating if allowed and remaining quota
    func checkLimit(key: String, cost: Int) async throws -> RateLimitResult

    /// Reset rate limit for a specific key
    /// - Parameter key: The key to reset
    func reset(key: String) async
}

extension RateLimiter {
    /// Check limit with default cost of 1
    public func checkLimit(key: String) async throws -> RateLimitResult {
        try await checkLimit(key: key, cost: 1)
    }
}

/// Configuration for rate limiting
public struct RateLimitConfiguration: Sendable {
    /// Requests per second limit
    public var requestsPerSecond: Int?

    /// Requests per minute limit
    public var requestsPerMinute: Int?

    /// Requests per hour limit
    public var requestsPerHour: Int?

    /// Burst size (for token bucket)
    public var burstSize: Int?

    /// Key extractor function
    public var keyExtractor: @Sendable (String) -> String

    /// Creates a rate limit configuration
    /// - Parameters:
    ///   - requestsPerSecond: Per-second limit
    ///   - requestsPerMinute: Per-minute limit
    ///   - requestsPerHour: Per-hour limit
    ///   - burstSize: Maximum burst size
    ///   - keyExtractor: Function to extract rate limit key
    public init(
        requestsPerSecond: Int? = nil,
        requestsPerMinute: Int? = nil,
        requestsPerHour: Int? = nil,
        burstSize: Int? = nil,
        keyExtractor: @escaping @Sendable (String) -> String = { $0 }
    ) {
        self.requestsPerSecond = requestsPerSecond
        self.requestsPerMinute = requestsPerMinute
        self.requestsPerHour = requestsPerHour
        self.burstSize = burstSize
        self.keyExtractor = keyExtractor
    }

    /// Standard rate limit: 100 req/s, 1000 req/min, 10000 req/hour
    public static let standard = RateLimitConfiguration(
        requestsPerSecond: 100,
        requestsPerMinute: 1_000,
        requestsPerHour: 10_000,
        burstSize: 200
    )

    /// Permissive rate limit: 1000 req/s
    public static let permissive = RateLimitConfiguration(
        requestsPerSecond: 1_000,
        burstSize: 2_000
    )

    /// Strict rate limit: 10 req/s, 100 req/min
    public static let strict = RateLimitConfiguration(
        requestsPerSecond: 10,
        requestsPerMinute: 100,
        requestsPerHour: 1_000,
        burstSize: 20
    )
}
