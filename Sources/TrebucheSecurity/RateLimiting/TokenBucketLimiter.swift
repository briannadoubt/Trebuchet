// TokenBucketLimiter.swift
// Token bucket rate limiting algorithm

import Foundation

/// Token bucket rate limiter
///
/// The token bucket algorithm allows bursts of requests while maintaining
/// a steady average rate. Tokens are added to a bucket at a fixed rate,
/// and requests consume tokens. If the bucket is empty, requests are denied.
public actor TokenBucketLimiter: RateLimiter {
    /// Bucket state for a specific key
    private struct Bucket {
        var tokens: Double
        var lastRefill: Date

        mutating func refill(capacity: Double, refillRate: Double, now: Date) {
            let elapsed = now.timeIntervalSince(lastRefill)
            let newTokens = elapsed * refillRate
            tokens = min(capacity, tokens + newTokens)
            lastRefill = now
        }

        mutating func consume(cost: Int) -> Bool {
            if tokens >= Double(cost) {
                tokens -= Double(cost)
                return true
            }
            return false
        }
    }

    /// Configuration
    public struct Configuration: Sendable {
        /// Maximum bucket capacity (tokens)
        public let capacity: Double

        /// Token refill rate (tokens per second)
        public let refillRate: Double

        /// Creates a configuration
        /// - Parameters:
        ///   - capacity: Maximum tokens in bucket
        ///   - refillRate: Tokens added per second
        public init(capacity: Double, refillRate: Double) {
            self.capacity = capacity
            self.refillRate = refillRate
        }

        /// Create from requests per second
        /// - Parameters:
        ///   - requestsPerSecond: Target rate
        ///   - burstSize: Maximum burst (defaults to 2x rate)
        public static func fromRate(
            requestsPerSecond: Int,
            burstSize: Int? = nil
        ) -> Configuration {
            let burst = burstSize ?? (requestsPerSecond * 2)
            return Configuration(
                capacity: Double(burst),
                refillRate: Double(requestsPerSecond)
            )
        }
    }

    private let configuration: Configuration
    private var buckets: [String: Bucket] = [:]
    private var cleanupTask: Task<Void, Never>?

    /// Creates a token bucket limiter
    /// - Parameters:
    ///   - configuration: Bucket configuration
    ///   - autoCleanup: Enable automatic cleanup of old buckets (default: false)
    ///   - cleanupInterval: Interval between cleanup runs (default: 1 hour)
    ///
    /// Note: Auto-cleanup is disabled by default due to Swift concurrency limitations.
    /// Call `startAutoCleanup()` after initialization if you want automatic cleanup.
    public init(
        configuration: Configuration,
        autoCleanup: Bool = false,
        cleanupInterval: Duration = .seconds(3600)
    ) {
        self.configuration = configuration
        // Cannot start task in actor init due to isolation
        // Users should call startAutoCleanup() if needed
    }

    /// Convenience initializer from rate
    /// - Parameters:
    ///   - requestsPerSecond: Target rate
    ///   - burstSize: Maximum burst
    public init(
        requestsPerSecond: Int,
        burstSize: Int? = nil
    ) {
        self.configuration = .fromRate(
            requestsPerSecond: requestsPerSecond,
            burstSize: burstSize
        )
    }

    /// Starts automatic cleanup task
    /// - Parameter interval: Cleanup interval (default: 1 hour)
    public func startAutoCleanup(interval: Duration = .seconds(3600)) {
        cleanupTask?.cancel()
        cleanupTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                await self?.cleanup(olderThan: interval.timeIntervalValue)
            }
        }
    }

    /// Stops automatic cleanup task
    public func stopAutoCleanup() {
        cleanupTask?.cancel()
        cleanupTask = nil
    }

    deinit {
        cleanupTask?.cancel()
    }

    public func checkLimit(key: String, cost: Int) async throws -> RateLimitResult {
        let now = Date()

        // Get or create bucket
        var bucket = buckets[key] ?? Bucket(
            tokens: configuration.capacity,
            lastRefill: now
        )

        // Refill tokens based on elapsed time
        bucket.refill(
            capacity: configuration.capacity,
            refillRate: configuration.refillRate,
            now: now
        )

        // Try to consume tokens
        let allowed = bucket.consume(cost: cost)

        // Update bucket
        buckets[key] = bucket

        // Calculate reset time
        let tokensNeeded = allowed ? 0.0 : Double(cost) - bucket.tokens
        let resetDelay = tokensNeeded / configuration.refillRate
        let resetAt = now.addingTimeInterval(resetDelay)

        return RateLimitResult(
            allowed: allowed,
            remaining: Int(bucket.tokens),
            resetAt: resetAt
        )
    }

    public func reset(key: String) async {
        buckets.removeValue(forKey: key)
    }

    /// Clean up old buckets
    public func cleanup(olderThan: TimeInterval = 3600) async {
        let now = Date()
        let cutoff = now.addingTimeInterval(-olderThan)

        buckets = buckets.filter { _, bucket in
            bucket.lastRefill > cutoff
        }
    }

    /// Get current token count for a key
    /// - Parameter key: The key to check
    /// - Returns: Current token count
    public func tokens(for key: String) async -> Double {
        guard var bucket = buckets[key] else {
            return configuration.capacity
        }

        let now = Date()
        bucket.refill(
            capacity: configuration.capacity,
            refillRate: configuration.refillRate,
            now: now
        )

        return bucket.tokens
    }
}

extension Duration {
    fileprivate var timeIntervalValue: TimeInterval {
        let (seconds, attoseconds) = self.components
        return TimeInterval(seconds) + (TimeInterval(attoseconds) / 1e18)
    }
}
