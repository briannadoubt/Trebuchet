# Authentication

Verify user and service identities with JWT and API key authentication.

## Overview

TrebuchetSecurity provides flexible authentication mechanisms for distributed actors:

- **API Keys**: Simple, secure authentication for services and scripts
- **JWT**: Standards-based token authentication with claims and expiration
- **Extensible**: Implement custom authentication providers

All authenticators implement the ``AuthenticationProvider`` protocol and return a ``Principal`` with roles and attributes for authorization.

## API Key Authentication

API keys are ideal for service-to-service communication and CLI tools.

### Basic Usage

```swift
import TrebuchetSecurity

// Configure API keys
let apiAuth = APIKeyAuthenticator(keys: [
    .init(
        key: "sk_live_abc123",
        principalId: "service-worker-1",
        roles: ["service", "worker"]
    ),
    .init(
        key: "sk_admin_xyz789",
        principalId: "admin-bot",
        roles: ["admin"],
        expiresAt: Date().addingTimeInterval(86400) // 24 hours
    )
])

// Authenticate a request
let credentials = Credentials.apiKey(key: "sk_live_abc123")
let principal = try await apiAuth.authenticate(credentials)

print(principal.id) // "service-worker-1"
print(principal.roles) // ["service", "worker"]
```

### Dynamic Key Management

```swift
// Create authenticator
let apiAuth = APIKeyAuthenticator()

// Register new keys at runtime
await apiAuth.register(.init(
    key: "sk_new_key",
    principalId: "new-service",
    roles: ["service"]
))

// Revoke compromised keys
await apiAuth.revoke("sk_old_key")
```

### Key Expiration

```swift
// Create key with expiration
let config = APIKeyAuthenticator.APIKeyConfig(
    key: "sk_temp_123",
    principalId: "temp-worker",
    roles: ["worker"],
    expiresAt: Date().addingTimeInterval(3600) // 1 hour
)

await apiAuth.register(config)

// Authentication will fail after expiration
do {
    try await apiAuth.authenticate(.apiKey(key: "sk_temp_123"))
} catch AuthenticationError.expired {
    print("Key has expired")
}
```

### Best Practices

- **Prefix keys**: Use prefixes like `sk_live_`, `sk_test_` to distinguish environments
- **Rotate regularly**: Implement key rotation for long-lived services
- **Scope roles**: Grant minimal necessary roles
- **Audit access**: Log all key usage for security monitoring

## JWT Authentication

JWT (JSON Web Token) is a standard for secure, stateless authentication with rich claims.

### Security Warning

⚠️ **The included JWT implementation does NOT validate cryptographic signatures** and is for testing only.

For production use, integrate a proper JWT library:
- [swift-jwt](https://github.com/Kitura/Swift-JWT) - IBM's JWT library
- [JWTKit](https://github.com/vapor/jwt-kit) - Vapor's JWT library

### Basic Usage

```swift
import TrebuchetSecurity

// Configure JWT validator
let jwtAuth = JWTAuthenticator(configuration: .init(
    issuer: "https://auth.example.com",
    audience: "https://api.example.com",
    clockSkew: 60 // Allow 60 seconds clock drift
))

// Authenticate bearer token
let credentials = Credentials.bearer(token: jwtToken)
let principal = try await jwtAuth.authenticate(credentials)

print(principal.id) // Subject from JWT (sub claim)
print(principal.roles) // Roles from JWT claims
print(principal.expiresAt) // Expiration from exp claim
```

### JWT Claims

The authenticator validates and extracts standard JWT claims:

| Claim | Validation | Usage |
|-------|------------|-------|
| `sub` (subject) | Required | Sets `Principal.id` |
| `iss` (issuer) | Verified against config | Must match expected issuer |
| `aud` (audience) | Optional verification | Must match if configured |
| `exp` (expiration) | Verified with clock skew | Sets `Principal.expiresAt` |
| `iat` (issued at) | Extracted | Sets `Principal.authenticatedAt` |
| `roles` | Extracted | Sets `Principal.roles` |
| Custom claims | Extracted | Stored in `Principal.attributes` |

### Example JWT Payload

```json
{
  "sub": "user-12345",
  "iss": "https://auth.example.com",
  "aud": "https://api.example.com",
  "exp": 1735689600,
  "iat": 1735686000,
  "roles": ["user", "premium"],
  "email": "user@example.com",
  "organization": "acme-corp"
}
```

Results in:

```swift
Principal(
    id: "user-12345",
    type: .user,
    roles: ["user", "premium"],
    attributes: [
        "email": "user@example.com",
        "organization": "acme-corp"
    ],
    authenticatedAt: Date(timeIntervalSince1970: 1735686000),
    expiresAt: Date(timeIntervalSince1970: 1735689600)
)
```

### Clock Skew Tolerance

JWT expiration is validated with configurable clock skew tolerance:

```swift
let config = JWTAuthenticator.Configuration(
    issuer: "https://auth.example.com",
    clockSkew: 60 // Allow 60 seconds drift
)

// Token expired 30 seconds ago → Accepted (within skew)
// Token expired 90 seconds ago → Rejected (outside skew)
```

### Production Integration

For production, replace `JWTAuthenticator` with a secure implementation:

```swift
import JWTKit // or swift-jwt

actor ProductionJWTAuth: AuthenticationProvider {
    let signers: JWTSigners

    init() {
        signers = JWTSigners()
        // Add RS256 public key
        try signers.use(.rs256(key: .public(pem: publicKeyPEM)))
    }

    func authenticate(_ credentials: Credentials) async throws -> Principal {
        guard case .bearer(let token) = credentials else {
            throw AuthenticationError.malformed(reason: "Expected bearer token")
        }

        // Verify signature and parse claims
        let jwt = try signers.verify(token, as: MyClaims.self)

        // Convert to Principal
        return Principal(
            id: jwt.subject.value,
            type: .user,
            roles: jwt.roles,
            authenticatedAt: jwt.issuedAt.value,
            expiresAt: jwt.expiration.value
        )
    }
}
```

## Credentials Types

The ``Credentials`` enum supports multiple authentication methods:

```swift
// Bearer token (JWT)
let jwt = Credentials.bearer(token: "eyJhbGc...")

// API key
let apiKey = Credentials.apiKey(key: "sk_live_abc123")

// Basic authentication (username:password)
let basic = Credentials.basic(username: "admin", password: "secret")

// Custom authentication
let custom = Credentials.custom(type: "device-token", value: "dev_xyz")
```

## Principal

The ``Principal`` struct represents an authenticated identity:

```swift
public struct Principal: Sendable, Codable {
    public let id: String                    // Unique identifier
    public let type: PrincipalType           // user, service, system
    public let roles: Set<String>            // Assigned roles
    public let attributes: [String: String]  // Custom attributes
    public let authenticatedAt: Date         // Authentication time
    public let expiresAt: Date?              // Optional expiration
}
```

### Role Checking

```swift
// Single role check
if principal.hasRole("admin") {
    // Allow admin action
}

// Any of multiple roles
if principal.hasAnyRole(["admin", "moderator"]) {
    // Allow privileged action
}

// All roles required
if principal.hasAllRoles(["user", "verified"]) {
    // Require both roles
}

// Check expiration
if principal.isExpired {
    throw AuthenticationError.expired
}
```

## Custom Authentication Providers

Implement ``AuthenticationProvider`` for custom authentication:

```swift
import TrebuchetSecurity

actor CustomAuthenticator: AuthenticationProvider {
    func authenticate(_ credentials: Credentials) async throws -> Principal {
        // Extract credentials
        guard case .custom(let type, let value) = credentials,
              type == "device-token" else {
            throw AuthenticationError.malformed(reason: "Expected device token")
        }

        // Validate with external service
        let deviceInfo = try await validateDeviceToken(value)

        // Return principal
        return Principal(
            id: deviceInfo.deviceId,
            type: .system,
            roles: ["device", "iot"],
            attributes: [
                "model": deviceInfo.model,
                "firmware": deviceInfo.firmware
            ]
        )
    }

    private func validateDeviceToken(_ token: String) async throws -> DeviceInfo {
        // Validation logic here
    }
}
```

## Integration with CloudGateway

Use authentication middleware to protect your actors:

```swift
import TrebuchetCloud
import TrebuchetSecurity

// Create authenticator
let apiAuth = APIKeyAuthenticator(keys: [
    .init(key: "sk_live_abc123", principalId: "service-1", roles: ["service"])
])

// Create authentication middleware
let authMiddleware = AuthenticationMiddleware(provider: apiAuth)

// Configure gateway with middleware
let gateway = CloudGateway(configuration: .init(
    middleware: [authMiddleware],
    stateStore: stateStore,
    registry: registry
))

// Now all requests require valid API key
// The Principal is available in the invocation context
```

## Error Handling

Authentication can fail with specific errors:

```swift
do {
    let principal = try await authenticator.authenticate(credentials)
} catch AuthenticationError.invalidCredentials {
    // Wrong key or token
    return .unauthorized("Invalid credentials")
} catch AuthenticationError.expired {
    // Token or key has expired
    return .unauthorized("Credentials expired")
} catch AuthenticationError.malformed(let reason) {
    // Credentials format is invalid
    return .badRequest("Malformed credentials: \(reason)")
} catch AuthenticationError.unavailable {
    // Auth service is down
    return .serviceUnavailable("Authentication unavailable")
}
```

## See Also

- <doc:Authorization> - Control access with RBAC
- <doc:RateLimiting> - Prevent abuse
- <doc:RequestValidation> - Validate request payloads
