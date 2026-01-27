# Rate Limiting

Protect your distributed actors from abuse with flexible rate limiting.

## Overview

TrebucheSecurity provides two rate limiting algorithms:

- **Token Bucket**: Allows controlled bursts while maintaining average rate
- **Sliding Window**: Precise per-window limits with smooth transitions

Both algorithms support:
- Per-key isolation (rate limit by user, IP, etc.)
- Custom cost per request
- Concurrent access safety
- Automatic cleanup of old data

## Token Bucket Algorithm

The token bucket algorithm is ideal for APIs that need to allow occasional bursts while maintaining a steady average rate.

### How It Works

1. A "bucket" starts full of tokens
2. Tokens are added at a steady rate (e.g., 10 per second)
3. Each request consumes tokens
4. If the bucket is empty, requests are denied
5. Bucket capacity limits maximum burst

### Basic Usage

```swift
import TrebucheSecurity

// Allow 100 requests/second with bursts up to 200
let limiter = TokenBucketLimiter(
    requestsPerSecond: 100,
    burstSize: 200
)

// Check if request is allowed
let result = try await limiter.checkLimit(key: "user-123")

if result.allowed {
    // Process request
    await handleRequest()
} else {
    // Deny with retry information
    throw RateLimitError.limitExceeded(retryAfter: result.retryAfter!)
}
```

### Configuration

```swift
// Manual configuration
let config = TokenBucketLimiter.Configuration(
    capacity: 100.0,      // Maximum tokens
    refillRate: 10.0      // Tokens added per second
)
let limiter = TokenBucketLimiter(configuration: config)

// From rate
let limiter = TokenBucketLimiter(
    requestsPerSecond: 50,
    burstSize: 100  // Defaults to 2x rate if not specified
)
```

### Weighted Requests

Some operations cost more than others:

```swift
// Normal request costs 1 token (default)
try await limiter.checkLimit(key: "user-123")

// Expensive operation costs 10 tokens
try await limiter.checkLimit(key: "user-123", cost: 10)

// Batch operation
try await limiter.checkLimit(key: "user-123", cost: batchSize)
```

## Sliding Window Algorithm

The sliding window algorithm provides precise limits within time windows and smoothly transitions between windows.

### How It Works

1. Track all requests with timestamps
2. Count requests within the sliding window
3. Old requests automatically expire
4. More accurate than fixed windows

### Basic Usage

```swift
import TrebucheSecurity

// Allow 1000 requests per minute
let limiter = SlidingWindowLimiter(
    configuration: .perMinute(1000)
)

let result = try await limiter.checkLimit(key: "user-123")

if !result.allowed {
    print("Rate limit exceeded. Try again at \(result.resetAt)")
}
```

### Configuration Options

```swift
// Per-second limit
let perSecond = SlidingWindowLimiter.Configuration.perSecond(100)

// Per-minute limit
let perMinute = SlidingWindowLimiter.Configuration.perMinute(1000)

// Per-hour limit
let perHour = SlidingWindowLimiter.Configuration.perHour(10_000)

// Custom window
let custom = SlidingWindowLimiter.Configuration(
    maxRequests: 5_000,
    windowDuration: .seconds(300)  // 5 minutes
)
```

## Choosing an Algorithm

| Feature | Token Bucket | Sliding Window |
|---------|-------------|----------------|
| **Bursts** | ✅ Excellent | ⚠️ Limited |
| **Precision** | ⚠️ Approximate | ✅ Exact |
| **Memory** | ✅ Low (per-key state) | ⚠️ Higher (stores requests) |
| **Use Case** | General APIs | Strict quotas |

**Use Token Bucket when:**
- You want to allow bursts
- Memory efficiency is important
- Approximate limits are acceptable

**Use Sliding Window when:**
- You need exact limits
- Strict quotas are required
- You want smooth rate transitions

## Per-Key Rate Limiting

Both algorithms support independent rate limits per key:

```swift
let limiter = TokenBucketLimiter(requestsPerSecond: 100)

// Different users have independent limits
try await limiter.checkLimit(key: "user-alice")  // Allowed
try await limiter.checkLimit(key: "user-bob")    // Allowed
```

Common key strategies:

```swift
// Per-user limiting
let key = "user:\(principal.id)"

// Per-IP limiting
let key = "ip:\(request.remoteAddress)"

// Per-endpoint limiting
let key = "endpoint:\(request.path)"

// Combined limiting
let key = "user:\(principal.id):endpoint:\(request.path)"

// Global limiting
let key = "global"
```

## Rate Limit Results

All rate limiters return a ``RateLimitResult``:

```swift
public struct RateLimitResult {
    let allowed: Bool        // Whether request is allowed
    let remaining: Int       // Remaining quota
    let resetAt: Date       // When limit resets
    var retryAfter: Duration?  // How long to wait if denied
}
```

Example usage:

```swift
let result = try await limiter.checkLimit(key: userID)

// Add rate limit headers (HTTP API)
response.headers["X-RateLimit-Limit"] = "\(maxRequests)"
response.headers["X-RateLimit-Remaining"] = "\(result.remaining)"
response.headers["X-RateLimit-Reset"] = "\(Int(result.resetAt.timeIntervalSince1970))"

if !result.allowed {
    response.headers["Retry-After"] = "\(Int(result.retryAfter!.components.seconds))"
    throw HTTPError.tooManyRequests
}
```

## Cleanup

Rate limiters accumulate per-key state. Clean up old entries periodically:

```swift
// Token bucket cleanup
await limiter.cleanup(olderThan: 3600)  // Remove buckets idle for 1 hour

// Sliding window cleanup
await limiter.cleanup(olderThan: 3600)  // Remove windows with no recent requests
```

For long-running services, run cleanup periodically:

```swift
Task {
    while !Task.isCancelled {
        try await Task.sleep(for: .minutes(30))
        await limiter.cleanup(olderThan: 3600)
    }
}
```

## Preset Configurations

Use preset configurations for common scenarios:

```swift
// Standard: 100 req/s, 1000 req/min, 10000 req/hour
let config = RateLimitConfiguration.standard

// Permissive: 1000 req/s with large burst
let config = RateLimitConfiguration.permissive

// Strict: 10 req/s with small burst
let config = RateLimitConfiguration.strict
```

## Error Handling

Rate limiters can throw errors:

```swift
do {
    let result = try await limiter.checkLimit(key: userID)
    if !result.allowed {
        // Handle rate limit exceeded
    }
} catch let error as RateLimitError {
    switch error {
    case .limitExceeded(let retryAfter):
        // Tell client when to retry
        print("Rate limited. Retry after \(retryAfter)")
    case .invalidConfiguration(let reason):
        // Configuration error
        print("Invalid config: \(reason)")
    case .custom(let message):
        // Custom error
        print("Error: \(message)")
    }
}
```

## Integration with CloudGateway

Rate limiting will be integrated into CloudGateway middleware in Phase 1.5:

```swift
let gateway = CloudGateway(configuration: .init(
    security: .init(
        rateLimiting: .init(
            requestsPerSecond: 100,
            burstSize: 200,
            keyExtractor: { envelope in
                // Extract rate limit key from envelope
                envelope.actorID.id
            }
        )
    )
))
```

## Best Practices

1. **Choose appropriate keys**: Rate limit by the dimension that matters (user, IP, endpoint)
2. **Set reasonable limits**: Too strict frustrates users, too loose allows abuse
3. **Provide clear errors**: Tell clients exactly when they can retry
4. **Monitor usage**: Track how often limits are hit
5. **Clean up regularly**: Prevent memory leaks in long-running services
6. **Test under load**: Verify rate limiting works under concurrent access

## Topics

### Limiters

- ``RateLimiter``
- ``TokenBucketLimiter``
- ``SlidingWindowLimiter``

### Results and Errors

- ``RateLimitResult``
- ``RateLimitError``

### Configuration

- ``RateLimitConfiguration``
- ``TokenBucketLimiter/Configuration``
- ``SlidingWindowLimiter/Configuration``
