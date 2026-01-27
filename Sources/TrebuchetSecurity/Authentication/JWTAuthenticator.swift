// JWTAuthenticator.swift
// JWT-based authentication with cryptographic signature validation

import Foundation
import Crypto
import _CryptoExtras

/// JWT authenticator with full cryptographic signature validation
///
/// This implementation validates JWT signatures using industry-standard algorithms
/// and provides comprehensive claim validation.
///
/// # Supported Algorithms
/// - **HS256**: HMAC with SHA-256 (symmetric key)
/// - **RS256**: RSA PKCS#1 v1.5 with SHA-256 (asymmetric key)
/// - **ES256**: ECDSA with P-256 curve and SHA-256 (asymmetric key)
///
/// # Security Features
/// - ✅ Cryptographic signature validation (HS256, RS256, ES256)
/// - ✅ Issuer (`iss`) claim validation
/// - ✅ Audience (`aud`) claim validation
/// - ✅ Expiration (`exp`) claim validation with clock skew tolerance
/// - ✅ Not Before (`nbf`) claim validation
/// - ✅ JWT ID (`jti`) replay protection
/// - ✅ Issued At (`iat`) claim validation
///
/// # Usage
/// ```swift
/// // HS256 with symmetric secret
/// let authenticator = JWTAuthenticator(configuration: .init(
///     issuer: "https://auth.example.com",
///     audience: "my-app",
///     signingKey: .hs256(secret: "your-256-bit-secret")
/// ))
///
/// // RS256 with RSA public key
/// let rsaKey = try _RSA.Signing.PublicKey(pemRepresentation: pemString)
/// let authenticator = JWTAuthenticator(configuration: .init(
///     issuer: "https://auth.example.com",
///     signingKey: .rs256(publicKey: rsaKey)
/// ))
///
/// // ES256 with P-256 public key
/// let ecKey = try P256.Signing.PublicKey(pemRepresentation: pemString)
/// let authenticator = JWTAuthenticator(configuration: .init(
///     issuer: "https://auth.example.com",
///     signingKey: .es256(publicKey: ecKey)
/// ))
/// ```
public struct JWTAuthenticator: AuthenticationProvider {
    /// Signing key types for JWT validation
    ///
    /// Note: Uses @unchecked Sendable because swift-crypto's P256 and RSA key types
    /// are immutable and thread-safe, but don't yet conform to Sendable.
    public enum SigningKey: @unchecked Sendable {
        /// Symmetric key for HS256 (HMAC-SHA256)
        case hs256(secret: String)

        /// RSA public key for RS256 (RSA PKCS#1 v1.5 with SHA-256)
        case rs256(publicKey: _RSA.Signing.PublicKey)

        /// P-256 public key for ES256 (ECDSA with SHA-256)
        case es256(publicKey: P256.Signing.PublicKey)

        /// No signature validation (for testing only)
        /// - Warning: Never use this in production!
        case none

        // MARK: - Deprecated compatibility aliases

        /// Deprecated: Use `.hs256(secret:)` instead
        @available(*, deprecated, renamed: "hs256(secret:)")
        public static func symmetric(secret: String) -> SigningKey {
            .hs256(secret: secret)
        }

        /// Deprecated: Use `.es256(publicKey:)` instead
        @available(*, deprecated, renamed: "es256(publicKey:)")
        public static func asymmetric(publicKey: P256.Signing.PublicKey) -> SigningKey {
            .es256(publicKey: publicKey)
        }
    }

    /// JWT configuration
    public struct Configuration: Sendable {
        /// Expected issuer
        public let issuer: String

        /// Expected audience (optional)
        public let audience: String?

        /// Signing key for signature validation
        public let signingKey: SigningKey

        /// Clock skew tolerance in seconds
        public let clockSkew: TimeInterval

        /// Maximum age for tokens (optional)
        public let maxAge: TimeInterval?

        /// Enable JWT ID (jti) replay protection
        public let enableReplayProtection: Bool

        /// Time-to-live for JTI cache entries (default: 1 hour)
        public let jtiCacheTTL: TimeInterval

        /// Creates a new JWT configuration
        /// - Parameters:
        ///   - issuer: Expected issuer claim value
        ///   - audience: Expected audience claim value (optional)
        ///   - signingKey: Key for signature validation
        ///   - clockSkew: Clock skew tolerance (default: 60 seconds)
        ///   - maxAge: Maximum token age from `iat` (optional)
        ///   - enableReplayProtection: Enable JTI tracking (default: true)
        ///   - jtiCacheTTL: JTI cache entry lifetime (default: 3600 seconds)
        public init(
            issuer: String,
            audience: String? = nil,
            signingKey: SigningKey = .none,
            clockSkew: TimeInterval = 60,
            maxAge: TimeInterval? = nil,
            enableReplayProtection: Bool = true,
            jtiCacheTTL: TimeInterval = 3600
        ) {
            self.issuer = issuer
            self.audience = audience
            self.signingKey = signingKey
            self.clockSkew = clockSkew
            self.maxAge = maxAge
            self.enableReplayProtection = enableReplayProtection
            self.jtiCacheTTL = jtiCacheTTL
        }
    }

    private let configuration: Configuration
    private let jtiCache: JTICache

    /// Creates a new JWT authenticator
    /// - Parameter configuration: JWT configuration
    public init(configuration: Configuration) {
        self.configuration = configuration
        self.jtiCache = JTICache(ttl: configuration.jtiCacheTTL)

        #if DEBUG
        if case .none = configuration.signingKey {
            print("""
            ⚠️  WARNING: JWTAuthenticator configured without signature validation!
            This is acceptable for testing but should NEVER be used in production.
            Configure a signing key using .hs256(), .rs256(), or .es256() for production use.
            """)
        }
        #endif
    }

    public func authenticate(_ credentials: Credentials) async throws -> Principal {
        guard case .bearer(let token) = credentials else {
            throw AuthenticationError.malformed(reason: "Expected bearer token")
        }

        // Parse and validate JWT
        let (header, claims) = try parseAndValidateJWT(token)

        // Validate signature
        try validateSignature(token: token, algorithm: header.algorithm)

        // Validate standard claims
        try validateClaims(claims)

        // Check JTI for replay protection
        if configuration.enableReplayProtection, let jti = claims.jwtID {
            let isNew = await jtiCache.checkAndStore(jti)
            if !isNew {
                throw AuthenticationError.custom(message: "Token has already been used (replay detected)")
            }
        }

        // Create principal from claims
        let now = Date()
        return Principal(
            id: claims.subject,
            type: .user,
            roles: claims.roles,
            attributes: claims.customClaims,
            authenticatedAt: claims.issuedAt ?? now,
            expiresAt: claims.expiresAt
        )
    }

    // MARK: - JWT Parsing

    private func parseAndValidateJWT(_ token: String) throws -> (JWTHeader, JWTClaims) {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else {
            throw AuthenticationError.malformed(reason: "Invalid JWT format: expected 3 parts separated by '.'")
        }

        // Decode header
        let headerData = try base64URLDecode(String(parts[0]))
        let header = try JSONDecoder().decode(JWTHeader.self, from: headerData)

        // Decode payload
        let payloadData = try base64URLDecode(String(parts[1]))
        let payload = try JSONDecoder().decode(JWTPayload.self, from: payloadData)

        let claims = JWTClaims(
            subject: payload.sub,
            issuer: payload.iss,
            audience: payload.aud,
            expiresAt: payload.exp.map { Date(timeIntervalSince1970: $0) },
            notBefore: payload.nbf.map { Date(timeIntervalSince1970: $0) },
            issuedAt: payload.iat.map { Date(timeIntervalSince1970: $0) },
            jwtID: payload.jti,
            roles: Set(payload.roles ?? []),
            customClaims: payload.customClaims ?? [:]
        )

        return (header, claims)
    }

    // MARK: - Signature Validation

    private func validateSignature(token: String, algorithm: JWTAlgorithm) throws {
        switch configuration.signingKey {
        case .none:
            // No validation - testing only
            return

        case .hs256(let secret):
            guard algorithm == .hs256 else {
                throw AuthenticationError.malformed(
                    reason: "Algorithm mismatch: token uses \(algorithm.rawValue) but HS256 key configured"
                )
            }
            try validateHS256Signature(token: token, secret: secret)

        case .rs256(let publicKey):
            guard algorithm == .rs256 else {
                throw AuthenticationError.malformed(
                    reason: "Algorithm mismatch: token uses \(algorithm.rawValue) but RS256 key configured"
                )
            }
            try validateRS256Signature(token: token, publicKey: publicKey)

        case .es256(let publicKey):
            guard algorithm == .es256 else {
                throw AuthenticationError.malformed(
                    reason: "Algorithm mismatch: token uses \(algorithm.rawValue) but ES256 key configured"
                )
            }
            try validateES256Signature(token: token, publicKey: publicKey)
        }
    }

    private func validateHS256Signature(token: String, secret: String) throws {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else {
            throw AuthenticationError.malformed(reason: "Invalid JWT format")
        }

        let signedPart = "\(parts[0]).\(parts[1])"
        let providedSignature = String(parts[2])

        // Compute expected signature
        guard let secretData = secret.data(using: .utf8),
              let signedData = signedPart.data(using: .utf8) else {
            throw AuthenticationError.malformed(reason: "Invalid encoding")
        }

        let key = SymmetricKey(data: secretData)
        let signature = HMAC<SHA256>.authenticationCode(for: signedData, using: key)
        let expectedSignature = base64URLEncode(Data(signature))

        // Constant-time comparison to prevent timing attacks
        guard constantTimeCompare(providedSignature, expectedSignature) else {
            throw AuthenticationError.invalidCredentials
        }
    }

    private func validateRS256Signature(token: String, publicKey: _RSA.Signing.PublicKey) throws {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else {
            throw AuthenticationError.malformed(reason: "Invalid JWT format")
        }

        let signedPart = "\(parts[0]).\(parts[1])"
        let signatureB64 = String(parts[2])

        guard let signedData = signedPart.data(using: .utf8) else {
            throw AuthenticationError.malformed(reason: "Invalid encoding")
        }

        // Decode the signature
        let signatureData = try base64URLDecode(signatureB64)

        // Create signature from raw representation
        let signature = _RSA.Signing.RSASignature(rawRepresentation: signatureData)

        // Verify the signature using PKCS#1 v1.5 padding (required for RS256)
        guard publicKey.isValidSignature(signature, for: SHA256.hash(data: signedData), padding: .insecurePKCS1v1_5) else {
            throw AuthenticationError.invalidCredentials
        }
    }

    private func validateES256Signature(token: String, publicKey: P256.Signing.PublicKey) throws {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else {
            throw AuthenticationError.malformed(reason: "Invalid JWT format")
        }

        let signedPart = "\(parts[0]).\(parts[1])"
        let signatureB64 = String(parts[2])

        guard let signedData = signedPart.data(using: .utf8) else {
            throw AuthenticationError.malformed(reason: "Invalid encoding")
        }

        // Decode the signature (JWT uses raw R||S format, 64 bytes for P-256)
        let signatureData = try base64URLDecode(signatureB64)

        // ES256 signatures in JWT are raw concatenated R||S values (64 bytes)
        guard signatureData.count == 64 else {
            throw AuthenticationError.malformed(
                reason: "Invalid ES256 signature length: expected 64 bytes, got \(signatureData.count)"
            )
        }

        // Create signature from raw representation
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureData)

        // Verify the signature
        guard publicKey.isValidSignature(signature, for: SHA256.hash(data: signedData)) else {
            throw AuthenticationError.invalidCredentials
        }
    }

    // MARK: - Claims Validation

    private func validateClaims(_ claims: JWTClaims) throws {
        let now = Date()

        // Validate issuer
        guard claims.issuer == configuration.issuer else {
            throw AuthenticationError.invalidCredentials
        }

        // Validate audience if configured
        if let expectedAudience = configuration.audience {
            guard claims.audience == expectedAudience else {
                throw AuthenticationError.invalidCredentials
            }
        }

        // Validate expiration (exp)
        if let exp = claims.expiresAt {
            let adjustedExp = exp.addingTimeInterval(configuration.clockSkew)
            if now > adjustedExp {
                throw AuthenticationError.expired
            }
        }

        // Validate not before (nbf)
        if let nbf = claims.notBefore {
            let adjustedNbf = nbf.addingTimeInterval(-configuration.clockSkew)
            if now < adjustedNbf {
                throw AuthenticationError.custom(message: "Token is not yet valid (nbf claim)")
            }
        }

        // Validate max age from issued at (iat)
        if let maxAge = configuration.maxAge, let iat = claims.issuedAt {
            let maxValidTime = iat.addingTimeInterval(maxAge + configuration.clockSkew)
            if now > maxValidTime {
                throw AuthenticationError.expired
            }
        }
    }

    // MARK: - Utility Functions

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
            throw AuthenticationError.malformed(reason: "Invalid base64url encoding")
        }

        return data
    }

    private func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Constant-time string comparison to prevent timing attacks
    private func constantTimeCompare(_ a: String, _ b: String) -> Bool {
        guard a.count == b.count else { return false }

        var result: UInt8 = 0
        for (charA, charB) in zip(a.utf8, b.utf8) {
            result |= charA ^ charB
        }
        return result == 0
    }
}

// MARK: - JWT Types

/// JWT header
struct JWTHeader: Codable {
    let alg: String
    let typ: String?

    var algorithm: JWTAlgorithm {
        JWTAlgorithm(rawValue: alg.uppercased()) ?? .unknown
    }
}

/// Supported JWT algorithms
enum JWTAlgorithm: String {
    case hs256 = "HS256"
    case rs256 = "RS256"
    case es256 = "ES256"
    case unknown
}

/// JWT claims
struct JWTClaims {
    let subject: String
    let issuer: String
    let audience: String?
    let expiresAt: Date?
    let notBefore: Date?
    let issuedAt: Date?
    let jwtID: String?
    let roles: Set<String>
    let customClaims: [String: String]
}

/// JWT payload structure
private struct JWTPayload: Codable {
    let sub: String
    let iss: String
    let aud: String?
    let exp: TimeInterval?
    let nbf: TimeInterval?
    let iat: TimeInterval?
    let jti: String?
    let roles: [String]?
    let customClaims: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case sub, iss, aud, exp, nbf, iat, jti, roles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sub = try container.decode(String.self, forKey: .sub)
        iss = try container.decode(String.self, forKey: .iss)
        aud = try container.decodeIfPresent(String.self, forKey: .aud)
        exp = try container.decodeIfPresent(TimeInterval.self, forKey: .exp)
        nbf = try container.decodeIfPresent(TimeInterval.self, forKey: .nbf)
        iat = try container.decodeIfPresent(TimeInterval.self, forKey: .iat)
        jti = try container.decodeIfPresent(String.self, forKey: .jti)
        roles = try container.decodeIfPresent([String].self, forKey: .roles)

        // Decode custom claims (any keys not in standard claims)
        let allKeys = try decoder.container(keyedBy: AnyCodingKey.self)
        var custom: [String: String] = [:]
        let standardKeys = ["sub", "iss", "aud", "exp", "nbf", "iat", "jti", "roles"]
        for key in allKeys.allKeys {
            if !standardKeys.contains(key.stringValue) {
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
        try container.encodeIfPresent(nbf, forKey: .nbf)
        try container.encodeIfPresent(iat, forKey: .iat)
        try container.encodeIfPresent(jti, forKey: .jti)
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

// MARK: - JTI Cache for Replay Protection

/// Thread-safe cache for tracking used JWT IDs
actor JTICache {
    private var cache: [String: Date] = [:]
    private let ttl: TimeInterval
    private var lastCleanup: Date = Date()
    private let cleanupInterval: TimeInterval = 300 // Clean every 5 minutes

    init(ttl: TimeInterval) {
        self.ttl = ttl
    }

    /// Check if JTI exists and store it if not
    /// - Returns: `true` if this is a new JTI, `false` if already seen
    func checkAndStore(_ jti: String) -> Bool {
        // Periodic cleanup
        let now = Date()
        if now.timeIntervalSince(lastCleanup) > cleanupInterval {
            cleanup()
            lastCleanup = now
        }

        // Check if JTI already exists
        if let storedTime = cache[jti] {
            // Check if it's still within TTL
            if now.timeIntervalSince(storedTime) < ttl {
                return false // Already seen and still valid
            }
        }

        // Store the new JTI
        cache[jti] = now
        return true
    }

    /// Remove expired entries
    private func cleanup() {
        let now = Date()
        cache = cache.filter { _, storedTime in
            now.timeIntervalSince(storedTime) < ttl
        }
    }

    /// Clear all cached JTIs (for testing)
    func clear() {
        cache.removeAll()
    }
}

// MARK: - JWT Creation Helpers (for testing)

/// Helper for creating signed JWTs (primarily for testing)
public enum JWTHelper {
    /// Creates an HS256-signed JWT
    /// - Parameters:
    ///   - subject: Subject claim (sub)
    ///   - issuer: Issuer claim (iss)
    ///   - audience: Audience claim (aud)
    ///   - expiresIn: Time until expiration in seconds
    ///   - notBefore: Not before date (nbf)
    ///   - jwtID: JWT ID for replay protection (jti)
    ///   - roles: User roles
    ///   - customClaims: Additional custom claims
    ///   - secret: HMAC secret
    /// - Returns: Signed JWT string
    public static func createHS256Token(
        subject: String,
        issuer: String,
        audience: String? = nil,
        expiresIn: TimeInterval = 3600,
        notBefore: Date? = nil,
        jwtID: String? = nil,
        roles: [String]? = nil,
        customClaims: [String: String]? = nil,
        secret: String
    ) -> String {
        let now = Date()

        // Build header
        let header = #"{"alg":"HS256","typ":"JWT"}"#

        // Build payload
        var payloadDict: [String: Any] = [
            "sub": subject,
            "iss": issuer,
            "exp": now.addingTimeInterval(expiresIn).timeIntervalSince1970,
            "iat": now.timeIntervalSince1970
        ]

        if let audience = audience {
            payloadDict["aud"] = audience
        }
        if let nbf = notBefore {
            payloadDict["nbf"] = nbf.timeIntervalSince1970
        }
        if let jti = jwtID {
            payloadDict["jti"] = jti
        }
        if let roles = roles {
            payloadDict["roles"] = roles
        }
        if let custom = customClaims {
            for (key, value) in custom {
                payloadDict[key] = value
            }
        }

        let payloadData = try! JSONSerialization.data(withJSONObject: payloadDict)

        // Encode parts
        let headerB64 = base64URLEncode(header.data(using: .utf8)!)
        let payloadB64 = base64URLEncode(payloadData)

        // Sign
        let signedPart = "\(headerB64).\(payloadB64)"
        let key = SymmetricKey(data: secret.data(using: .utf8)!)
        let signature = HMAC<SHA256>.authenticationCode(for: signedPart.data(using: .utf8)!, using: key)
        let signatureB64 = base64URLEncode(Data(signature))

        return "\(signedPart).\(signatureB64)"
    }

    /// Creates an RS256-signed JWT
    /// - Parameters:
    ///   - subject: Subject claim (sub)
    ///   - issuer: Issuer claim (iss)
    ///   - audience: Audience claim (aud)
    ///   - expiresIn: Time until expiration in seconds
    ///   - notBefore: Not before date (nbf)
    ///   - jwtID: JWT ID for replay protection (jti)
    ///   - roles: User roles
    ///   - customClaims: Additional custom claims
    ///   - privateKey: RSA private key for signing
    /// - Returns: Signed JWT string
    public static func createRS256Token(
        subject: String,
        issuer: String,
        audience: String? = nil,
        expiresIn: TimeInterval = 3600,
        notBefore: Date? = nil,
        jwtID: String? = nil,
        roles: [String]? = nil,
        customClaims: [String: String]? = nil,
        privateKey: _RSA.Signing.PrivateKey
    ) throws -> String {
        let now = Date()

        // Build header
        let header = #"{"alg":"RS256","typ":"JWT"}"#

        // Build payload
        var payloadDict: [String: Any] = [
            "sub": subject,
            "iss": issuer,
            "exp": now.addingTimeInterval(expiresIn).timeIntervalSince1970,
            "iat": now.timeIntervalSince1970
        ]

        if let audience = audience {
            payloadDict["aud"] = audience
        }
        if let nbf = notBefore {
            payloadDict["nbf"] = nbf.timeIntervalSince1970
        }
        if let jti = jwtID {
            payloadDict["jti"] = jti
        }
        if let roles = roles {
            payloadDict["roles"] = roles
        }
        if let custom = customClaims {
            for (key, value) in custom {
                payloadDict[key] = value
            }
        }

        let payloadData = try JSONSerialization.data(withJSONObject: payloadDict)

        // Encode parts
        let headerB64 = base64URLEncode(header.data(using: .utf8)!)
        let payloadB64 = base64URLEncode(payloadData)

        // Sign using PKCS#1 v1.5 (required for RS256)
        let signedPart = "\(headerB64).\(payloadB64)"
        let signature = try privateKey.signature(for: SHA256.hash(data: signedPart.data(using: .utf8)!), padding: .insecurePKCS1v1_5)
        let signatureB64 = base64URLEncode(signature.rawRepresentation)

        return "\(signedPart).\(signatureB64)"
    }

    /// Creates an ES256-signed JWT
    /// - Parameters:
    ///   - subject: Subject claim (sub)
    ///   - issuer: Issuer claim (iss)
    ///   - audience: Audience claim (aud)
    ///   - expiresIn: Time until expiration in seconds
    ///   - notBefore: Not before date (nbf)
    ///   - jwtID: JWT ID for replay protection (jti)
    ///   - roles: User roles
    ///   - customClaims: Additional custom claims
    ///   - privateKey: P-256 private key for signing
    /// - Returns: Signed JWT string
    public static func createES256Token(
        subject: String,
        issuer: String,
        audience: String? = nil,
        expiresIn: TimeInterval = 3600,
        notBefore: Date? = nil,
        jwtID: String? = nil,
        roles: [String]? = nil,
        customClaims: [String: String]? = nil,
        privateKey: P256.Signing.PrivateKey
    ) throws -> String {
        let now = Date()

        // Build header
        let header = #"{"alg":"ES256","typ":"JWT"}"#

        // Build payload
        var payloadDict: [String: Any] = [
            "sub": subject,
            "iss": issuer,
            "exp": now.addingTimeInterval(expiresIn).timeIntervalSince1970,
            "iat": now.timeIntervalSince1970
        ]

        if let audience = audience {
            payloadDict["aud"] = audience
        }
        if let nbf = notBefore {
            payloadDict["nbf"] = nbf.timeIntervalSince1970
        }
        if let jti = jwtID {
            payloadDict["jti"] = jti
        }
        if let roles = roles {
            payloadDict["roles"] = roles
        }
        if let custom = customClaims {
            for (key, value) in custom {
                payloadDict[key] = value
            }
        }

        let payloadData = try JSONSerialization.data(withJSONObject: payloadDict)

        // Encode parts
        let headerB64 = base64URLEncode(header.data(using: .utf8)!)
        let payloadB64 = base64URLEncode(payloadData)

        // Sign
        let signedPart = "\(headerB64).\(payloadB64)"
        let signature = try privateKey.signature(for: SHA256.hash(data: signedPart.data(using: .utf8)!))
        let signatureB64 = base64URLEncode(signature.rawRepresentation)

        return "\(signedPart).\(signatureB64)"
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
