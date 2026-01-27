# ``TrebuchetSecurity``

Production-grade security for distributed actors.

## Overview

TrebuchetSecurity provides comprehensive security features for Trebuchet distributed actors, protecting your applications from unauthorized access and abuse.

```swift
import TrebuchetSecurity

// Authenticate with API keys
let authenticator = APIKeyAuthenticator(keys: [
    .init(key: "sk_live_abc123", principalId: "service-1", roles: ["service"])
])

// Authorize with role-based policies
let policy = RoleBasedPolicy(rules: [
    .adminFullAccess,
    .userReadOnly
])

// Rate limit requests
let limiter = TokenBucketLimiter(
    requestsPerSecond: 100,
    burstSize: 200
)

// Validate requests
let validator = RequestValidator(configuration: .strict)
```

## Features

### Authentication

Verify user and service identities with flexible authentication providers:

- **API Keys**: Simple, secure authentication for services and scripts
- **JWT**: Standards-based token authentication with claims and expiration
- **Extensible**: Implement custom authentication providers

See <doc:Authentication> for details.

### Authorization

Control access to actors and methods with role-based access control:

- **Role-Based Access Control (RBAC)**: Map roles to permissions
- **Wildcard Patterns**: Match actor types and methods with `*`
- **Custom Policies**: Implement time-based, attribute-based, or composite policies

See <doc:Authorization> for details.

### Rate Limiting

Protect actors from abuse with flexible rate limiting algorithms:

- **Token Bucket**: Allow controlled bursts while maintaining average rate
- **Sliding Window**: Precise per-window limits with smooth transitions
- **Per-Key Isolation**: Rate limit by user, IP, or custom key

See <doc:RateLimiting> for details.

### Request Validation

Validate incoming requests to prevent malformed or malicious payloads:

- **Payload Size Limits**: Prevent memory exhaustion
- **Actor ID Validation**: Ensure valid actor identifiers
- **Method Name Restrictions**: Block dangerous method names
- **Null Byte Detection**: Prevent injection attacks

See <doc:RequestValidation> for details.

## Quick Start

### Secure CloudGateway

```swift
import TrebuchetCloud
import TrebuchetSecurity

// Create security components
let apiAuth = APIKeyAuthenticator(keys: [
    .init(key: "sk_live_abc123", principalId: "service-1", roles: ["service"])
])

let policy = RoleBasedPolicy(rules: [
    .init(role: "admin", actorType: "*", method: "*"),
    .init(role: "service", actorType: "GameRoom", method: "*"),
    .init(role: "user", actorType: "*", method: "get*")
])

let limiter = TokenBucketLimiter(
    requestsPerSecond: 100,
    burstSize: 200
)

let validator = RequestValidator(configuration: .strict)

// Create middleware stack
let authMiddleware = AuthenticationMiddleware(provider: apiAuth)
let authzMiddleware = AuthorizationMiddleware(policy: policy)
let rateLimitMiddleware = RateLimitingMiddleware(limiter: limiter)
let validationMiddleware = ValidationMiddleware(validator: validator)

// Configure gateway with full security
let gateway = CloudGateway(configuration: .init(
    middlewares: [
        validationMiddleware,   // Validate first
        authMiddleware,         // Authenticate
        authzMiddleware,        // Authorize
        rateLimitMiddleware     // Rate limit
    ],
    stateStore: stateStore,
    registry: registry
))
```

### Authentication Flow

```swift
// 1. Receive request with API key
let credentials = Credentials.apiKey(key: "sk_live_abc123")

// 2. Authenticate
let principal = try await authenticator.authenticate(credentials)
// Principal(id: "service-1", roles: ["service"])

// 3. Check authorization
let action = Action(actorType: "GameRoom", method: "join")
let resource = Resource(type: "game", id: "room-123")

let allowed = try await policy.authorize(principal, action: action, resource: resource)

if !allowed {
    throw AuthorizationError.accessDenied
}

// 4. Check rate limit
let limit = try await limiter.checkLimit(key: principal.id)

if !limit.allowed {
    throw RateLimitError.limitExceeded(retryAfter: limit.retryAfter!)
}

// 5. Validate request
try await validator.validate(invocation)

// 6. Process request
try await actor.invokeMethod()
```

## CloudGateway Integration

TrebuchetSecurity is designed to integrate seamlessly with CloudGateway through middleware:

```swift
// Middleware executes in order:
let middlewares: [CloudMiddleware] = [
    ValidationMiddleware(validator: validator),     // 1. Validate request
    AuthenticationMiddleware(provider: apiAuth),    // 2. Authenticate
    AuthorizationMiddleware(policy: policy),        // 3. Authorize
    RateLimitingMiddleware(limiter: limiter),       // 4. Rate limit
    TracingMiddleware(tracer: tracer)              // 5. Trace (optional)
]

// Each middleware can:
// - Inspect the request
// - Transform the request
// - Reject with an error
// - Pass to next middleware
```

## Security Presets

### Development

Permissive settings for local development:

```swift
import TrebuchetCloud
import TrebuchetSecurity

// Development API key auth
let devAuth = APIKeyAuthenticator(keys: [
    .init(key: "dev_test", principalId: "dev", roles: ["admin"])
])

// Allow all access (dev only!)
let devPolicy = RoleBasedPolicy(rules: [
    .init(role: "admin", actorType: "*", method: "*")
], denyByDefault: false)

// Permissive rate limiting (1000 req/s)
let devLimiter = TokenBucketLimiter(
    requestsPerSecond: 1000,
    burstSize: 2000
)

// Lenient validation (10MB payload limit)
let devValidator = RequestValidator(configuration: .init(
    maxPayloadSize: 10 * 1024 * 1024,
    maxActorIDLength: 1000,
    maxMethodNameLength: 500,
    allowedMethodNamePattern: ".*"
))

// Configure gateway for development
let devGateway = CloudGateway(configuration: .init(
    middlewares: [
        ValidationMiddleware(validator: devValidator),
        AuthenticationMiddleware(provider: devAuth),
        AuthorizationMiddleware(policy: devPolicy),
        RateLimitingMiddleware(limiter: devLimiter)
    ],
    stateStore: stateStore,
    registry: registry
))
```

### Production

Strict settings for production deployment:

```swift
import TrebuchetCloud
import TrebuchetSecurity

// Production JWT authentication
let prodAuth = JWTAuthenticator(configuration: .init(
    issuer: "https://auth.example.com",
    audience: "https://api.example.com",
    clockSkew: 60
))

// Strict RBAC policy
let prodPolicy = RoleBasedPolicy(rules: [
    .adminFullAccess,
    .userReadOnly
])

// Strict rate limiting (10 req/s per user)
let prodLimiter = TokenBucketLimiter(
    requestsPerSecond: 10,
    burstSize: 20
)

// Strict validation (1MB payload limit)
let prodValidator = RequestValidator(configuration: .strict)

// Configure gateway for production
let prodGateway = CloudGateway(configuration: .init(
    middlewares: [
        ValidationMiddleware(validator: prodValidator),
        AuthenticationMiddleware(provider: prodAuth),
        AuthorizationMiddleware(policy: prodPolicy),
        RateLimitingMiddleware(limiter: prodLimiter)
    ],
    stateStore: stateStore,
    registry: registry
))
```

### Custom

Mix and match security components:

```swift
import TrebuchetCloud
import TrebuchetSecurity

// Custom API key auth with keys from vault
let customAuth = APIKeyAuthenticator(keys: loadKeysFromVault())

// Custom authorization policy
let customPolicy = MyCustomPolicy()

// Custom rate limiting (50 req/s with bursts)
let customLimiter = TokenBucketLimiter(
    requestsPerSecond: 50,
    burstSize: 100
)

// Custom validator
let customValidator = MyValidator()

// Configure gateway with custom components
let customGateway = CloudGateway(configuration: .init(
    middlewares: [
        ValidationMiddleware(validator: customValidator),
        AuthenticationMiddleware(provider: customAuth),
        AuthorizationMiddleware(policy: customPolicy),
        RateLimitingMiddleware(limiter: customLimiter)
    ],
    stateStore: stateStore,
    registry: registry
))
```

## Error Handling

All security components throw specific errors:

```swift
do {
    try await processSecureRequest()
} catch AuthenticationError.invalidCredentials {
    return .unauthorized("Invalid credentials")
} catch AuthenticationError.expired {
    return .unauthorized("Credentials expired")
} catch AuthorizationError.accessDenied {
    return .forbidden("Access denied")
} catch RateLimitError.limitExceeded(let retryAfter) {
    return .tooManyRequests(retryAfter: retryAfter)
} catch ValidationError.payloadTooLarge(let size, let limit) {
    return .requestTooLarge("Payload \(size) exceeds limit \(limit)")
}
```

## Observability

Security events integrate with TrebuchetObservability:

```swift
import TrebuchetObservability

// Log security events
logger.info("Authentication succeeded", metadata: [
    "principal": principal.id,
    "method": "api-key"
])

// Track metrics
metrics.counter("auth.success").increment()
metrics.counter("auth.failure").increment()
metrics.histogram("rate_limit.remaining").record(remaining)

// Trace security operations
let span = tracer.startSpan("authenticate", kind: .internal)
defer { span.end() }
```

## Best Practices

### Defense in Depth

Use multiple security layers:

```swift
// ✅ Multiple security checks
let middleware = [
    ValidationMiddleware(...),      // Validate inputs
    AuthenticationMiddleware(...),  // Verify identity
    AuthorizationMiddleware(...),   // Check permissions
    RateLimitingMiddleware(...)     // Prevent abuse
]

// ❌ Single security check
let middleware = [
    AuthenticationMiddleware(...)  // Only authentication
]
```

### Least Privilege

Grant minimum necessary permissions:

```swift
// ✅ Specific permissions
.init(role: "user", actorType: "GameRoom", method: "join")

// ❌ Overly broad permissions
.init(role: "user", actorType: "*", method: "*")
```

### Secure Defaults

Use strict settings by default, relax as needed:

```swift
// ✅ Start strict
let validator = RequestValidator(configuration: .strict)

// ❌ Start permissive
let validator = RequestValidator(configuration: .lenient)
```

### Audit Logging

Log all security decisions:

```swift
logger.info("Authorization decision", metadata: [
    "principal": principal.id,
    "action": "\(action.actorType).\(action.method)",
    "resource": resource.id,
    "allowed": "\(allowed)"
])
```

### Test Security

Write tests for security rules:

```swift
func testAdminCanDeleteRooms() async throws {
    let admin = Principal(id: "admin", roles: ["admin"])
    let action = Action(actorType: "GameRoom", method: "delete")

    let allowed = try await policy.authorize(admin, action: action, resource: resource)
    XCTAssertTrue(allowed)
}

func testUserCannotDeleteRooms() async throws {
    let user = Principal(id: "user", roles: ["user"])
    let action = Action(actorType: "GameRoom", method: "delete")

    let allowed = try await policy.authorize(user, action: action, resource: resource)
    XCTAssertFalse(allowed)
}
```

## Topics

### Authentication

- <doc:Authentication>
- ``AuthenticationProvider``
- ``APIKeyAuthenticator``
- ``JWTAuthenticator``
- ``Credentials``
- ``Principal``
- ``AuthenticationError``

### Authorization

- <doc:Authorization>
- ``AuthorizationPolicy``
- ``RoleBasedPolicy``
- ``Action``
- ``Resource``
- ``AuthorizationError``

### Rate Limiting

- <doc:RateLimiting>
- ``RateLimiter``
- ``TokenBucketLimiter``
- ``SlidingWindowLimiter``
- ``RateLimitResult``
- ``RateLimitError``

### Request Validation

- <doc:RequestValidation>
- ``RequestValidator``
- ``ValidationConfiguration``
- ``ValidationError``

### Middleware

- ``AuthenticationMiddleware``
- ``AuthorizationMiddleware``
- ``RateLimitingMiddleware``
- ``ValidationMiddleware``
