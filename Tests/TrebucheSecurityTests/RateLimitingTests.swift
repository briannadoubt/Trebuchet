// RateLimitingTests.swift
// Tests for rate limiting

import Testing
import Foundation
@testable import TrebuchetSecurity

@Suite("Rate Limiting Tests")
struct RateLimitingTests {

    // MARK: - Token Bucket Tests

    @Test("TokenBucketLimiter allows burst")
    func testTokenBucketBurst() async throws {
        let limiter = TokenBucketLimiter(
            requestsPerSecond: 10,
            burstSize: 20
        )

        // Should allow burst of 20 requests immediately
        for i in 1...20 {
            let result = try await limiter.checkLimit(key: "user1")
            #expect(result.allowed, "Request \(i) should be allowed")
        }

        // 21st request should be denied
        let result21 = try await limiter.checkLimit(key: "user1")
        #expect(!result21.allowed)
    }

    @Test("TokenBucketLimiter refills tokens")
    func testTokenBucketRefill() async throws {
        let limiter = TokenBucketLimiter(
            requestsPerSecond: 10,
            burstSize: 10
        )

        // Consume all tokens
        for _ in 1...10 {
            _ = try await limiter.checkLimit(key: "user1")
        }

        // Next request should be denied
        let deniedResult = try await limiter.checkLimit(key: "user1")
        #expect(!deniedResult.allowed)

        // Wait 200ms (should refill 2 tokens at 10/sec)
        try await Task.sleep(for: .milliseconds(200))

        // Should allow 2 more requests
        let result1 = try await limiter.checkLimit(key: "user1")
        #expect(result1.allowed)

        let result2 = try await limiter.checkLimit(key: "user1")
        #expect(result2.allowed)

        // Third should be denied
        let result3 = try await limiter.checkLimit(key: "user1")
        #expect(!result3.allowed)
    }

    @Test("TokenBucketLimiter per-key isolation")
    func testTokenBucketPerKeyIsolation() async throws {
        let limiter = TokenBucketLimiter(
            requestsPerSecond: 5,
            burstSize: 5
        )

        // User1 consumes all tokens
        for _ in 1...5 {
            _ = try await limiter.checkLimit(key: "user1")
        }

        // User1 should be denied
        let user1Result = try await limiter.checkLimit(key: "user1")
        #expect(!user1Result.allowed)

        // User2 should still be allowed
        let user2Result = try await limiter.checkLimit(key: "user2")
        #expect(user2Result.allowed)
    }

    @Test("TokenBucketLimiter reset")
    func testTokenBucketReset() async throws {
        let limiter = TokenBucketLimiter(
            requestsPerSecond: 5,
            burstSize: 5
        )

        // Consume all tokens
        for _ in 1...5 {
            _ = try await limiter.checkLimit(key: "user1")
        }

        // Should be denied
        let deniedResult = try await limiter.checkLimit(key: "user1")
        #expect(!deniedResult.allowed)

        // Reset
        await limiter.reset(key: "user1")

        // Should be allowed again
        let allowedResult = try await limiter.checkLimit(key: "user1")
        #expect(allowedResult.allowed)
    }

    @Test("TokenBucketLimiter cost")
    func testTokenBucketCost() async throws {
        let limiter = TokenBucketLimiter(
            requestsPerSecond: 10,
            burstSize: 10
        )

        // Consume 5 tokens
        let result1 = try await limiter.checkLimit(key: "user1", cost: 5)
        #expect(result1.allowed)
        #expect(result1.remaining == 5)

        // Consume another 5 tokens
        let result2 = try await limiter.checkLimit(key: "user1", cost: 5)
        #expect(result2.allowed)
        #expect(result2.remaining == 0)

        // Trying to consume 1 more should fail
        let result3 = try await limiter.checkLimit(key: "user1", cost: 1)
        #expect(!result3.allowed)
    }

    @Test("TokenBucketLimiter tokens query")
    func testTokenBucketTokensQuery() async throws {
        let limiter = TokenBucketLimiter(
            requestsPerSecond: 10,
            burstSize: 10
        )

        // Initial tokens should be at capacity
        let initialTokens = await limiter.tokens(for: "user1")
        #expect(initialTokens == 10.0)

        // Consume 3 tokens
        _ = try await limiter.checkLimit(key: "user1", cost: 3)

        // Should have approximately 7 remaining (may refill slightly due to elapsed time)
        let remainingTokens = await limiter.tokens(for: "user1")
        #expect(remainingTokens >= 7.0 && remainingTokens <= 7.1)
    }

    // MARK: - Sliding Window Tests

    @Test("SlidingWindowLimiter enforces limit")
    func testSlidingWindowLimit() async throws {
        let limiter = SlidingWindowLimiter(
            configuration: .perSecond(10)
        )

        // Should allow 10 requests
        for i in 1...10 {
            let result = try await limiter.checkLimit(key: "user1")
            #expect(result.allowed, "Request \(i) should be allowed")
        }

        // 11th request should be denied
        let result11 = try await limiter.checkLimit(key: "user1")
        #expect(!result11.allowed)
    }

    @Test("SlidingWindowLimiter window expiration")
    func testSlidingWindowExpiration() async throws {
        let limiter = SlidingWindowLimiter(
            configuration: .init(maxRequests: 5, windowDuration: .milliseconds(100))
        )

        // Consume all requests
        for _ in 1...5 {
            _ = try await limiter.checkLimit(key: "user1")
        }

        // Should be denied
        let deniedResult = try await limiter.checkLimit(key: "user1")
        #expect(!deniedResult.allowed)

        // Wait for window to expire
        try await Task.sleep(for: .milliseconds(150))

        // Should be allowed again
        let allowedResult = try await limiter.checkLimit(key: "user1")
        #expect(allowedResult.allowed)
    }

    @Test("SlidingWindowLimiter per-key isolation")
    func testSlidingWindowPerKeyIsolation() async throws {
        let limiter = SlidingWindowLimiter(requestsPerSecond: 5)

        // User1 consumes all requests
        for _ in 1...5 {
            _ = try await limiter.checkLimit(key: "user1")
        }

        // User1 should be denied
        let user1Result = try await limiter.checkLimit(key: "user1")
        #expect(!user1Result.allowed)

        // User2 should still be allowed
        let user2Result = try await limiter.checkLimit(key: "user2")
        #expect(user2Result.allowed)
    }

    @Test("SlidingWindowLimiter reset")
    func testSlidingWindowReset() async throws {
        let limiter = SlidingWindowLimiter(requestsPerSecond: 5)

        // Consume all requests
        for _ in 1...5 {
            _ = try await limiter.checkLimit(key: "user1")
        }

        // Should be denied
        let deniedResult = try await limiter.checkLimit(key: "user1")
        #expect(!deniedResult.allowed)

        // Reset
        await limiter.reset(key: "user1")

        // Should be allowed again
        let allowedResult = try await limiter.checkLimit(key: "user1")
        #expect(allowedResult.allowed)
    }

    @Test("SlidingWindowLimiter cost")
    func testSlidingWindowCost() async throws {
        let limiter = SlidingWindowLimiter(
            configuration: .perSecond(10)
        )

        // Consume 5 with cost
        let result1 = try await limiter.checkLimit(key: "user1", cost: 5)
        #expect(result1.allowed)

        // Consume another 5
        let result2 = try await limiter.checkLimit(key: "user1", cost: 5)
        #expect(result2.allowed)

        // Trying to consume 1 more should fail
        let result3 = try await limiter.checkLimit(key: "user1", cost: 1)
        #expect(!result3.allowed)
    }

    @Test("SlidingWindowLimiter request count query")
    func testSlidingWindowRequestCountQuery() async throws {
        let limiter = SlidingWindowLimiter(requestsPerSecond: 10)

        // Initial count should be 0
        let initialCount = await limiter.requestCount(for: "user1")
        #expect(initialCount == 0)

        // Make 3 requests
        for _ in 1...3 {
            _ = try await limiter.checkLimit(key: "user1")
        }

        // Count should be 3
        let count = await limiter.requestCount(for: "user1")
        #expect(count == 3)
    }

    @Test("SlidingWindowLimiter per-minute configuration")
    func testSlidingWindowPerMinute() async throws {
        let limiter = SlidingWindowLimiter(
            configuration: .perMinute(60)
        )

        // Should allow 60 requests
        for i in 1...60 {
            let result = try await limiter.checkLimit(key: "user1")
            #expect(result.allowed, "Request \(i) should be allowed")
        }

        // 61st should be denied
        let result61 = try await limiter.checkLimit(key: "user1")
        #expect(!result61.allowed)
    }

    // MARK: - Concurrent Access Tests

    @Test("TokenBucketLimiter concurrent access")
    func testTokenBucketConcurrentAccess() async throws {
        let limiter = TokenBucketLimiter(
            requestsPerSecond: 100,
            burstSize: 100
        )

        // Make 100 concurrent requests
        let allowedCount = await withTaskGroup(of: RateLimitResult.self) { group in
            for _ in 1...100 {
                group.addTask {
                    try! await limiter.checkLimit(key: "user1")
                }
            }

            var count = 0
            for await result in group {
                if result.allowed {
                    count += 1
                }
            }
            return count
        }

        // Exactly 100 should be allowed
        #expect(allowedCount == 100)

        // Check that limit is enforced
        // Note: Due to token refill (100/sec), some time may have passed
        // so we just verify the system is tracking limits correctly
        let result = try await limiter.checkLimit(key: "user1")
        // Either denied, or remaining is very low (tokens may have refilled)
        if result.allowed {
            #expect(result.remaining <= 5)  // Allow up to 5 refilled tokens
        }
    }

    @Test("SlidingWindowLimiter concurrent access")
    func testSlidingWindowConcurrentAccess() async throws {
        let limiter = SlidingWindowLimiter(requestsPerSecond: 50)

        // Make 100 concurrent requests
        await withTaskGroup(of: RateLimitResult.self) { group in
            for _ in 1...100 {
                group.addTask {
                    try! await limiter.checkLimit(key: "user1")
                }
            }

            var allowedCount = 0
            for await result in group {
                if result.allowed {
                    allowedCount += 1
                }
            }

            // Exactly 50 should be allowed
            #expect(allowedCount == 50)
        }
    }

    // MARK: - Configuration Tests

    @Test("RateLimitConfiguration presets")
    func testRateLimitConfigurationPresets() {
        // Standard
        let standard = RateLimitConfiguration.standard
        #expect(standard.requestsPerSecond == 100)
        #expect(standard.requestsPerMinute == 1_000)
        #expect(standard.requestsPerHour == 10_000)
        #expect(standard.burstSize == 200)

        // Permissive
        let permissive = RateLimitConfiguration.permissive
        #expect(permissive.requestsPerSecond == 1_000)
        #expect(permissive.burstSize == 2_000)

        // Strict
        let strict = RateLimitConfiguration.strict
        #expect(strict.requestsPerSecond == 10)
        #expect(strict.requestsPerMinute == 100)
        #expect(strict.requestsPerHour == 1_000)
        #expect(strict.burstSize == 20)
    }

    // MARK: - Cleanup Tests

    @Test("TokenBucketLimiter cleanup")
    func testTokenBucketCleanup() async throws {
        let limiter = TokenBucketLimiter(requestsPerSecond: 10)

        // Make some requests
        _ = try await limiter.checkLimit(key: "user1")
        _ = try await limiter.checkLimit(key: "user2")
        _ = try await limiter.checkLimit(key: "user3")

        // Cleanup old buckets (0.1 second threshold)
        try await Task.sleep(for: .milliseconds(150))
        await limiter.cleanup(olderThan: 0.1)

        // All buckets should be cleaned up
        // New requests should have full capacity
        let tokens = await limiter.tokens(for: "user1")
        #expect(tokens == 20.0) // Default burst size is 2x rate
    }

    @Test("SlidingWindowLimiter cleanup")
    func testSlidingWindowCleanup() async throws {
        let limiter = SlidingWindowLimiter(requestsPerSecond: 10)

        // Make some requests
        _ = try await limiter.checkLimit(key: "user1")
        _ = try await limiter.checkLimit(key: "user2")

        // Cleanup old windows
        try await Task.sleep(for: .milliseconds(150))
        await limiter.cleanup(olderThan: 0.1)

        // Windows should be cleaned up
        let count = await limiter.requestCount(for: "user1")
        #expect(count == 0)
    }
}
