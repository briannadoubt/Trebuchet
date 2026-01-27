// JWTAuthenticator.swift
// JWT-based authentication

import Foundation

/// JWT authenticator
///
/// **⚠️ SECURITY WARNING**: This is a simplified JWT implementation for demonstration and testing.
/// This implementation does NOT validate JWT signatures and should NOT be used in production.
///
/// For production use, integrate a proper JWT library:
/// - [swift-jwt](https://github.com/Kitura/Swift-JWT) - IBM's JWT library
/// - [JWTKit](https://github.com/vapor/jwt-kit) - Vapor's JWT library
///
/// # What This Implementation Does
/// - ✅ Validates token structure (header.payload.signature format)
/// - ✅ Validates issuer claim (`iss`)
/// - ✅ Validates audience claim (`aud`)
/// - ✅ Validates expiration claim (`exp`) with clock skew tolerance
/// - ✅ Extracts roles and custom claims
///
/// # What This Implementation Does NOT Do
/// - ❌ Verify cryptographic signatures (HS256, RS256, etc.)
/// - ❌ Validate `nbf` (not before) claim
/// - ❌ Validate `jti` (JWT ID) for replay protection
/// - ❌ Support JWK (JSON Web Key) sets
/// - ❌ Support key rotation
///
/// # Security Implications
/// Without signature validation, tokens can be:
/// - Forged by attackers
/// - Modified to escalate privileges
/// - Reused after revocation
///
/// **Only use this for local development and testing.**
///
/// # TODO
/// - [ ] Add signature validation using CryptoKit or third-party library
/// - [ ] Add support for RS256, ES256 algorithms
/// - [ ] Add JWK set support for key rotation
/// - [ ] Add `nbf` and `jti` claim validation
public struct JWTAuthenticator: AuthenticationProvider {
    /// JWT configuration
    public struct Configuration: Sendable {
        /// Expected issuer
        public let issuer: String

        /// Expected audience (optional)
        public let audience: String?

        /// Secret key for HS256 (not recommended for production)
        public let secret: String?

        /// Clock skew tolerance in seconds
        public let clockSkew: TimeInterval

        /// Creates a new JWT configuration
        /// - Parameters:
        ///   - issuer: Expected issuer
        ///   - audience: Expected audience (optional)
        ///   - secret: Secret key for HS256 (optional)
        ///   - clockSkew: Clock skew tolerance (default: 60 seconds)
        public init(
            issuer: String,
            audience: String? = nil,
            secret: String? = nil,
            clockSkew: TimeInterval = 60
        ) {
            self.issuer = issuer
            self.audience = audience
            self.secret = secret
            self.clockSkew = clockSkew
        }
    }

    private let configuration: Configuration

    /// Creates a new JWT authenticator
    /// - Parameter configuration: JWT configuration
    public init(configuration: Configuration) {
        self.configuration = configuration

        #if DEBUG
        print("""
        ⚠️  WARNING: JWTAuthenticator does NOT validate signatures!
        This implementation is for testing only. Use a proper JWT library in production.
        See documentation for security implications.
        """)
        #endif
    }

    public func authenticate(_ credentials: Credentials) async throws -> Principal {
        guard case .bearer(let token) = credentials else {
            throw AuthenticationError.malformed(reason: "Expected bearer token")
        }

        // Parse JWT (simplified - in production use a proper JWT library)
        let claims = try parseJWT(token)

        // Verify issuer
        guard claims.issuer == configuration.issuer else {
            throw AuthenticationError.invalidCredentials
        }

        // Verify audience if configured
        if let expectedAudience = configuration.audience,
           claims.audience != expectedAudience {
            throw AuthenticationError.invalidCredentials
        }

        // Verify expiration
        let now = Date()
        if let exp = claims.expiresAt, now > exp.addingTimeInterval(configuration.clockSkew) {
            throw AuthenticationError.expired
        }

        // Create principal from claims
        return Principal(
            id: claims.subject,
            type: .user,
            roles: claims.roles,
            attributes: claims.customClaims,
            authenticatedAt: claims.issuedAt ?? now,
            expiresAt: claims.expiresAt
        )
    }

    private func parseJWT(_ token: String) throws -> JWTClaims {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else {
            throw AuthenticationError.malformed(reason: "Invalid JWT format")
        }

        // Decode payload (base64url)
        let payloadData = try base64URLDecode(String(parts[1]))
        let payload = try JSONDecoder().decode(JWTPayload.self, from: payloadData)

        return JWTClaims(
            subject: payload.sub,
            issuer: payload.iss,
            audience: payload.aud,
            expiresAt: payload.exp.map { Date(timeIntervalSince1970: $0) },
            issuedAt: payload.iat.map { Date(timeIntervalSince1970: $0) },
            roles: Set(payload.roles ?? []),
            customClaims: payload.customClaims ?? [:]
        )
    }

    private func base64URLDecode(_ string: String) throws -> Data {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        // Add padding if needed
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: base64) else {
            throw AuthenticationError.malformed(reason: "Invalid base64 encoding")
        }

        return data
    }
}

/// JWT claims
struct JWTClaims {
    let subject: String
    let issuer: String
    let audience: String?
    let expiresAt: Date?
    let issuedAt: Date?
    let roles: Set<String>
    let customClaims: [String: String]
}

/// JWT payload structure
private struct JWTPayload: Codable {
    let sub: String
    let iss: String
    let aud: String?
    let exp: TimeInterval?
    let iat: TimeInterval?
    let roles: [String]?
    let customClaims: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case sub, iss, aud, exp, iat, roles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sub = try container.decode(String.self, forKey: .sub)
        iss = try container.decode(String.self, forKey: .iss)
        aud = try container.decodeIfPresent(String.self, forKey: .aud)
        exp = try container.decodeIfPresent(TimeInterval.self, forKey: .exp)
        iat = try container.decodeIfPresent(TimeInterval.self, forKey: .iat)
        roles = try container.decodeIfPresent([String].self, forKey: .roles)

        // Decode custom claims (any keys not in standard claims)
        let allKeys = try decoder.container(keyedBy: AnyCodingKey.self)
        var custom: [String: String] = [:]
        for key in allKeys.allKeys {
            if !["sub", "iss", "aud", "exp", "iat", "roles"].contains(key.stringValue) {
                if let value = try? allKeys.decode(String.self, forKey: key) {
                    custom[key.stringValue] = value
                }
            }
        }
        customClaims = custom.isEmpty ? nil : custom
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sub, forKey: .sub)
        try container.encode(iss, forKey: .iss)
        try container.encodeIfPresent(aud, forKey: .aud)
        try container.encodeIfPresent(exp, forKey: .exp)
        try container.encodeIfPresent(iat, forKey: .iat)
        try container.encodeIfPresent(roles, forKey: .roles)
    }
}

/// Dynamic coding key for custom claims
private struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}
