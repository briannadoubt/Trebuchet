// SlidingWindowLimiter.swift
// Sliding window rate limiting algorithm

import Foundation

/// Sliding window rate limiter
///
/// The sliding window algorithm tracks requests in a time window and
/// smoothly transitions between windows. More accurate than fixed windows
/// but requires more memory to track individual requests.
public actor SlidingWindowLimiter: RateLimiter {
    /// Request timestamp
    private struct RequestEntry {
        let timestamp: Date
        let cost: Int
    }

    /// Window state for a specific key
    private struct Window {
        var requests: [RequestEntry]

        mutating func cleanup(before: Date) {
            requests.removeAll { $0.timestamp < before }
        }

        func count(since: Date) -> Int {
            requests
                .filter { $0.timestamp >= since }
                .reduce(0) { $0 + $1.cost }
        }

        mutating func add(cost: Int, at timestamp: Date) {
            requests.append(RequestEntry(timestamp: timestamp, cost: cost))
        }
    }

    /// Configuration
    public struct Configuration: Sendable {
        /// Maximum requests allowed in window
        public let maxRequests: Int

        /// Window duration
        public let windowDuration: Duration

        /// Creates a configuration
        /// - Parameters:
        ///   - maxRequests: Maximum requests in window
        ///   - windowDuration: Duration of sliding window
        public init(maxRequests: Int, windowDuration: Duration) {
            self.maxRequests = maxRequests
            self.windowDuration = windowDuration
        }

        /// Per-second rate limit
        public static func perSecond(_ requests: Int) -> Configuration {
            Configuration(maxRequests: requests, windowDuration: .seconds(1))
        }

        /// Per-minute rate limit
        public static func perMinute(_ requests: Int) -> Configuration {
            Configuration(maxRequests: requests, windowDuration: .seconds(60))
        }

        /// Per-hour rate limit
        public static func perHour(_ requests: Int) -> Configuration {
            Configuration(maxRequests: requests, windowDuration: .seconds(3600))
        }
    }

    private let configuration: Configuration
    private var windows: [String: Window] = [:]
    private var cleanupTask: Task<Void, Never>?

    /// Creates a sliding window limiter
    /// - Parameters:
    ///   - configuration: Window configuration
    ///   - autoCleanup: Enable automatic cleanup (default: false)
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

    /// Convenience initializer for per-second limit
    /// - Parameters:
    ///   - requestsPerSecond: Requests allowed per second
    public init(requestsPerSecond: Int) {
        self.configuration = .perSecond(requestsPerSecond)
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
        let windowStart = now.addingTimeInterval(-configuration.windowDuration.timeIntervalValue)

        // Get or create window
        var window = windows[key] ?? Window(requests: [])

        // Clean up old requests
        window.cleanup(before: windowStart)

        // Count requests in current window
        let currentCount = window.count(since: windowStart)
        let remaining = configuration.maxRequests - currentCount

        // Check if request is allowed
        let allowed = (currentCount + cost) <= configuration.maxRequests

        // If allowed, add to window
        if allowed {
            window.add(cost: cost, at: now)
        }

        // Update window
        windows[key] = window

        // Calculate reset time
        let resetAt: Date
        if let oldestRequest = window.requests.first {
            resetAt = oldestRequest.timestamp.addingTimeInterval(
                configuration.windowDuration.timeIntervalValue
            )
        } else {
            resetAt = now.addingTimeInterval(configuration.windowDuration.timeIntervalValue)
        }

        return RateLimitResult(
            allowed: allowed,
            remaining: max(0, remaining - (allowed ? cost : 0)),
            resetAt: resetAt
        )
    }

    public func reset(key: String) async {
        windows.removeValue(forKey: key)
    }

    /// Clean up old windows
    public func cleanup(olderThan: TimeInterval = 3600) async {
        let now = Date()
        let cutoff = now.addingTimeInterval(-olderThan)

        for (key, var window) in windows {
            window.cleanup(before: cutoff)
            if window.requests.isEmpty {
                windows.removeValue(forKey: key)
            } else {
                windows[key] = window
            }
        }
    }

    /// Get current request count for a key
    /// - Parameter key: The key to check
    /// - Returns: Current request count in window
    public func requestCount(for key: String) async -> Int {
        let now = Date()
        let windowStart = now.addingTimeInterval(-configuration.windowDuration.timeIntervalValue)

        guard var window = windows[key] else {
            return 0
        }

        window.cleanup(before: windowStart)
        return window.count(since: windowStart)
    }
}

extension Duration {
    fileprivate var timeIntervalValue: TimeInterval {
        let (seconds, attoseconds) = self.components
        return TimeInterval(seconds) + (TimeInterval(attoseconds) / 1e18)
    }
}
