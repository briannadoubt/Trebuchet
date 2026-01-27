// TrebuchetSecurity.swift
// Production-grade security for Trebuchet distributed actors
//
// This module provides comprehensive security features including:
// - Authentication (JWT with HS256/ES256 signature validation, API keys)
// - Authorization (RBAC)
// - Rate limiting (token bucket, sliding window)
// - Request validation
//
// Example usage:
// ```swift
// // HS256 JWT authentication
// let auth = JWTAuthenticator(configuration: .init(
//     issuer: "https://auth.example.com",
//     audience: "my-app",
//     signingKey: .symmetric(secret: "your-256-bit-secret")
// ))
// let principal = try await auth.authenticate(credentials)
//
// // ES256 JWT authentication (with P-256 public key)
// import Crypto
// let publicKey = try P256.Signing.PublicKey(pemRepresentation: pemString)
// let auth = JWTAuthenticator(configuration: .init(
//     issuer: "https://auth.example.com",
//     signingKey: .asymmetric(publicKey: publicKey)
// ))
//
// // Authorization
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
/// - **Authentication**: JWT (HS256, ES256) and API key validation with full signature verification
/// - **Authorization**: Role-based access control (RBAC)
/// - **Rate Limiting**: Token bucket and sliding window algorithms
/// - **Validation**: Request size limits and malformed envelope detection
///
/// ## JWT Features
/// - HS256 (HMAC-SHA256) signature validation
/// - ES256 (ECDSA P-256) signature validation
/// - Issuer, audience, and expiration claim validation
/// - Not-before (nbf) claim validation
/// - JWT ID (jti) replay protection
/// - Configurable clock skew tolerance
///
/// ## Note on RS256
/// RS256 (RSA) signatures are not supported by swift-crypto.
/// For RS256 support, consider using JWTKit or Swift-JWT.
public enum TrebuchetSecurity {
    /// Current version of the security module
    public static let version = "1.2.0"
}
