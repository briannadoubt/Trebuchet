// TrebuchetSecurity.swift
// Production-grade security for Trebuchet distributed actors
//
// This module provides comprehensive security features including:
// - Authentication (JWT, API keys)
// - Authorization (RBAC)
// - Rate limiting (token bucket, sliding window)
// - Request validation
//
// Example usage:
// ```swift
// let auth = JWTAuthenticator(issuer: "https://auth.example.com")
// let principal = try await auth.authenticate(credentials)
//
// let policy = RoleBasedPolicy(rules: [
//     .init(role: "admin", actorType: "*", method: "*")
// ])
// let allowed = try await policy.authorize(principal, action: action, resource: resource)
// ```

@_exported import struct Foundation.UUID
@_exported import struct Foundation.Date

/// TrebuchetSecurity provides production-grade security for distributed actors.
///
/// This module includes:
/// - **Authentication**: JWT and API key validation
/// - **Authorization**: Role-based access control (RBAC)
/// - **Rate Limiting**: Token bucket and sliding window algorithms
/// - **Validation**: Request size limits and malformed envelope detection
public enum TrebuchetSecurity {
    /// Current version of the security module
    public static let version = "1.1.0"
}
