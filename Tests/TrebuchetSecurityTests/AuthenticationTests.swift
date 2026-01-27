// AuthenticationTests.swift
// Tests for authentication providers

import Testing
import Foundation
import Crypto
@testable import TrebuchetSecurity

@Suite("Authentication Tests")
struct AuthenticationTests {

    // MARK: - Principal Tests

    @Test("Principal creation")
    func testPrincipalCreation() {
        let principal = Principal(
            id: "user-123",
            type: .user,
            roles: ["admin", "user"]
        )

        #expect(principal.id == "user-123")
        #expect(principal.type == .user)
        #expect(principal.roles.count == 2)
        #expect(principal.hasRole("admin"))
        #expect(principal.hasRole("user"))
        #expect(!principal.hasRole("guest"))
    }

    @Test("Principal role checks")
    func testPrincipalRoleChecks() {
        let principal = Principal(
            id: "test",
            roles: ["admin", "editor", "viewer"]
        )

        // hasRole
        #expect(principal.hasRole("admin"))
        #expect(!principal.hasRole("superadmin"))

        // hasAnyRole
        #expect(principal.hasAnyRole(["admin", "owner"]))
        #expect(!principal.hasAnyRole(["owner", "guest"]))

        // hasAllRoles
        #expect(principal.hasAllRoles(["admin", "editor"]))
        #expect(!principal.hasAllRoles(["admin", "owner"]))
    }

    @Test("Principal expiration")
    func testPrincipalExpiration() {
        let futureExpiry = Date().addingTimeInterval(3600)
        let pastExpiry = Date().addingTimeInterval(-3600)

        let validPrincipal = Principal(id: "valid", expiresAt: futureExpiry)
        #expect(!validPrincipal.isExpired)

        let expiredPrincipal = Principal(id: "expired", expiresAt: pastExpiry)
        #expect(expiredPrincipal.isExpired)

        let neverExpires = Principal(id: "never", expiresAt: nil)
        #expect(!neverExpires.isExpired)
    }

    // MARK: - API Key Authenticator Tests

    @Test("APIKeyAuthenticator with valid key")
    func testAPIKeyAuthenticatorValidKey() async throws {
        let authenticator = APIKeyAuthenticator(keys: [
            .init(
                key: "test-api-key-123",
                principalId: "service-1",
                roles: ["service", "read"]
            )
        ])

        let credentials = Credentials.apiKey(key: "test-api-key-123")
        let principal = try await authenticator.authenticate(credentials)

        #expect(principal.id == "service-1")
        #expect(principal.type == .service)
        #expect(principal.hasRole("service"))
        #expect(principal.hasRole("read"))
    }

    @Test("APIKeyAuthenticator with invalid key")
    func testAPIKeyAuthenticatorInvalidKey() async {
        let authenticator = APIKeyAuthenticator(keys: [
            .init(key: "valid-key", principalId: "test")
        ])

        let credentials = Credentials.apiKey(key: "invalid-key")

        do {
            _ = try await authenticator.authenticate(credentials)
            #expect(Bool(false), "Should have thrown AuthenticationError")
        } catch let error as AuthenticationError {
            if case .invalidCredentials = error {
                // Expected
            } else {
                #expect(Bool(false), "Expected invalidCredentials error")
            }
        } catch {
            #expect(Bool(false), "Expected AuthenticationError")
        }
    }

    @Test("APIKeyAuthenticator bearer token format")
    func testAPIKeyAuthenticatorBearerFormat() async throws {
        let authenticator = APIKeyAuthenticator(keys: [
            .init(key: "bearer-key-123", principalId: "test")
        ])

        // API keys can be passed as bearer tokens
        let credentials = Credentials.bearer(token: "bearer-key-123")
        let principal = try await authenticator.authenticate(credentials)

        #expect(principal.id == "test")
    }

    @Test("APIKeyAuthenticator expiration")
    func testAPIKeyAuthenticatorExpiration() async {
        let pastExpiry = Date().addingTimeInterval(-3600)

        let authenticator = APIKeyAuthenticator(keys: [
            .init(
                key: "expired-key",
                principalId: "test",
                expiresAt: pastExpiry
            )
        ])

        let credentials = Credentials.apiKey(key: "expired-key")

        do {
            _ = try await authenticator.authenticate(credentials)
            #expect(Bool(false), "Should have thrown AuthenticationError")
        } catch let error as AuthenticationError {
            if case .expired = error {
                // Expected
            } else {
                #expect(Bool(false), "Expected expired error")
            }
        } catch {
            #expect(Bool(false), "Expected AuthenticationError")
        }
    }

    @Test("APIKeyAuthenticator register and revoke")
    func testAPIKeyAuthenticatorRegisterRevoke() async throws {
        let authenticator = APIKeyAuthenticator()

        // Register a key
        await authenticator.register(.init(
            key: "new-key",
            principalId: "test"
        ))

        // Should authenticate successfully
        let credentials = Credentials.apiKey(key: "new-key")
        let principal = try await authenticator.authenticate(credentials)
        #expect(principal.id == "test")

        // Revoke the key
        await authenticator.revoke("new-key")

        // Should fail now
        do {
            _ = try await authenticator.authenticate(credentials)
            #expect(Bool(false), "Should have thrown after revocation")
        } catch is AuthenticationError {
            // Expected
        } catch {
            #expect(Bool(false), "Expected AuthenticationError")
        }
    }

    // MARK: - JWT Authenticator Tests (HS256)

    static let testSecret = "super-secret-key-for-testing-256-bits!"

    @Test("JWTAuthenticator HS256 valid token")
    func testJWTAuthenticatorHS256ValidToken() async throws {
        let authenticator = JWTAuthenticator(configuration: .init(
            issuer: "https://auth.example.com",
            audience: "my-app",
            signingKey: .symmetric(secret: Self.testSecret),
            enableReplayProtection: false
        ))

        let jwt = JWTHelper.createHS256Token(
            subject: "user-123",
            issuer: "https://auth.example.com",
            audience: "my-app",
            roles: ["admin", "user"],
            secret: Self.testSecret
        )

        let credentials = Credentials.bearer(token: jwt)
        let principal = try await authenticator.authenticate(credentials)

        #expect(principal.id == "user-123")
        #expect(principal.hasRole("admin"))
        #expect(principal.hasRole("user"))
    }

    @Test("JWTAuthenticator HS256 invalid signature")
    func testJWTAuthenticatorHS256InvalidSignature() async {
        let authenticator = JWTAuthenticator(configuration: .init(
            issuer: "https://auth.example.com",
            signingKey: .symmetric(secret: Self.testSecret),
            enableReplayProtection: false
        ))

        // Create token with different secret
        let jwt = JWTHelper.createHS256Token(
            subject: "user-123",
            issuer: "https://auth.example.com",
            secret: "wrong-secret-key"
        )

        let credentials = Credentials.bearer(token: jwt)

        do {
            _ = try await authenticator.authenticate(credentials)
            #expect(Bool(false), "Should have thrown for invalid signature")
        } catch let error as AuthenticationError {
            if case .invalidCredentials = error {
                // Expected
            } else {
                #expect(Bool(false), "Expected invalidCredentials error, got \(error)")
            }
        } catch {
            #expect(Bool(false), "Expected AuthenticationError")
        }
    }

    @Test("JWTAuthenticator HS256 wrong issuer")
    func testJWTAuthenticatorHS256WrongIssuer() async {
        let authenticator = JWTAuthenticator(configuration: .init(
            issuer: "https://auth.example.com",
            signingKey: .symmetric(secret: Self.testSecret),
            enableReplayProtection: false
        ))

        let jwt = JWTHelper.createHS256Token(
            subject: "user-123",
            issuer: "https://wrong-issuer.com",
            secret: Self.testSecret
        )

        let credentials = Credentials.bearer(token: jwt)

        do {
            _ = try await authenticator.authenticate(credentials)
            #expect(Bool(false), "Should have thrown for wrong issuer")
        } catch is AuthenticationError {
            // Expected
        } catch {
            #expect(Bool(false), "Expected AuthenticationError")
        }
    }

    @Test("JWTAuthenticator HS256 expired token")
    func testJWTAuthenticatorHS256ExpiredToken() async {
        let authenticator = JWTAuthenticator(configuration: .init(
            issuer: "https://auth.example.com",
            signingKey: .symmetric(secret: Self.testSecret),
            clockSkew: 0,
            enableReplayProtection: false
        ))

        let jwt = JWTHelper.createHS256Token(
            subject: "user-123",
            issuer: "https://auth.example.com",
            expiresIn: -3600, // Expired 1 hour ago
            secret: Self.testSecret
        )

        let credentials = Credentials.bearer(token: jwt)

        do {
            _ = try await authenticator.authenticate(credentials)
            #expect(Bool(false), "Should have thrown for expired token")
        } catch let error as AuthenticationError {
            if case .expired = error {
                // Expected
            } else {
                #expect(Bool(false), "Expected expired error, got \(error)")
            }
        } catch {
            #expect(Bool(false), "Expected AuthenticationError")
        }
    }

    // MARK: - JWT Authenticator Tests (ES256)

    @Test("JWTAuthenticator ES256 valid token")
    func testJWTAuthenticatorES256ValidToken() async throws {
        let privateKey = P256.Signing.PrivateKey()
        let publicKey = privateKey.publicKey

        let authenticator = JWTAuthenticator(configuration: .init(
            issuer: "https://auth.example.com",
            audience: "my-app",
            signingKey: .asymmetric(publicKey: publicKey),
            enableReplayProtection: false
        ))

        let jwt = try JWTHelper.createES256Token(
            subject: "user-456",
            issuer: "https://auth.example.com",
            audience: "my-app",
            roles: ["reader"],
            privateKey: privateKey
        )

        let credentials = Credentials.bearer(token: jwt)
        let principal = try await authenticator.authenticate(credentials)

        #expect(principal.id == "user-456")
        #expect(principal.hasRole("reader"))
    }

    @Test("JWTAuthenticator ES256 invalid signature")
    func testJWTAuthenticatorES256InvalidSignature() async throws {
        let privateKey1 = P256.Signing.PrivateKey()
        let privateKey2 = P256.Signing.PrivateKey() // Different key
        let publicKey1 = privateKey1.publicKey

        let authenticator = JWTAuthenticator(configuration: .init(
            issuer: "https://auth.example.com",
            signingKey: .asymmetric(publicKey: publicKey1),
            enableReplayProtection: false
        ))

        // Sign with privateKey2 but verify with publicKey1
        let jwt = try JWTHelper.createES256Token(
            subject: "user-123",
            issuer: "https://auth.example.com",
            privateKey: privateKey2
        )

        let credentials = Credentials.bearer(token: jwt)

        do {
            _ = try await authenticator.authenticate(credentials)
            #expect(Bool(false), "Should have thrown for invalid signature")
        } catch let error as AuthenticationError {
            if case .invalidCredentials = error {
                // Expected
            } else {
                #expect(Bool(false), "Expected invalidCredentials error, got \(error)")
            }
        } catch {
            #expect(Bool(false), "Expected AuthenticationError")
        }
    }

    // MARK: - JWT Not Before (nbf) Tests

    @Test("JWTAuthenticator nbf claim - token not yet valid")
    func testJWTAuthenticatorNbfNotYetValid() async {
        let authenticator = JWTAuthenticator(configuration: .init(
            issuer: "https://auth.example.com",
            signingKey: .symmetric(secret: Self.testSecret),
            clockSkew: 0,
            enableReplayProtection: false
        ))

        let jwt = JWTHelper.createHS256Token(
            subject: "user-123",
            issuer: "https://auth.example.com",
            notBefore: Date().addingTimeInterval(3600), // Valid 1 hour from now
            secret: Self.testSecret
        )

        let credentials = Credentials.bearer(token: jwt)

        do {
            _ = try await authenticator.authenticate(credentials)
            #expect(Bool(false), "Should have thrown for token not yet valid")
        } catch let error as AuthenticationError {
            if case .custom(let message) = error {
                #expect(message.contains("not yet valid"))
            } else {
                #expect(Bool(false), "Expected custom error about nbf, got \(error)")
            }
        } catch {
            #expect(Bool(false), "Expected AuthenticationError")
        }
    }

    @Test("JWTAuthenticator nbf claim - token valid with clock skew")
    func testJWTAuthenticatorNbfValidWithClockSkew() async throws {
        let authenticator = JWTAuthenticator(configuration: .init(
            issuer: "https://auth.example.com",
            signingKey: .symmetric(secret: Self.testSecret),
            clockSkew: 120, // 2 minute tolerance
            enableReplayProtection: false
        ))

        let jwt = JWTHelper.createHS256Token(
            subject: "user-123",
            issuer: "https://auth.example.com",
            notBefore: Date().addingTimeInterval(60), // Valid 1 minute from now
            secret: Self.testSecret
        )

        let credentials = Credentials.bearer(token: jwt)
        // Should succeed because clock skew covers the 1 minute
        let principal = try await authenticator.authenticate(credentials)
        #expect(principal.id == "user-123")
    }

    // MARK: - JWT ID (jti) Replay Protection Tests

    @Test("JWTAuthenticator jti replay protection")
    func testJWTAuthenticatorJtiReplayProtection() async throws {
        let authenticator = JWTAuthenticator(configuration: .init(
            issuer: "https://auth.example.com",
            signingKey: .symmetric(secret: Self.testSecret),
            enableReplayProtection: true
        ))

        let jwt = JWTHelper.createHS256Token(
            subject: "user-123",
            issuer: "https://auth.example.com",
            jwtID: "unique-token-id-123",
            secret: Self.testSecret
        )

        let credentials = Credentials.bearer(token: jwt)

        // First use should succeed
        let principal = try await authenticator.authenticate(credentials)
        #expect(principal.id == "user-123")

        // Second use should fail (replay detected)
        do {
            _ = try await authenticator.authenticate(credentials)
            #expect(Bool(false), "Should have thrown for replay attack")
        } catch let error as AuthenticationError {
            if case .custom(let message) = error {
                #expect(message.contains("replay"))
            } else {
                #expect(Bool(false), "Expected custom error about replay, got \(error)")
            }
        } catch {
            #expect(Bool(false), "Expected AuthenticationError")
        }
    }

    @Test("JWTAuthenticator jti disabled allows replay")
    func testJWTAuthenticatorJtiDisabledAllowsReplay() async throws {
        let authenticator = JWTAuthenticator(configuration: .init(
            issuer: "https://auth.example.com",
            signingKey: .symmetric(secret: Self.testSecret),
            enableReplayProtection: false
        ))

        let jwt = JWTHelper.createHS256Token(
            subject: "user-123",
            issuer: "https://auth.example.com",
            jwtID: "unique-token-id-456",
            secret: Self.testSecret
        )

        let credentials = Credentials.bearer(token: jwt)

        // First use
        let principal1 = try await authenticator.authenticate(credentials)
        #expect(principal1.id == "user-123")

        // Second use should also succeed (replay protection disabled)
        let principal2 = try await authenticator.authenticate(credentials)
        #expect(principal2.id == "user-123")
    }

    // MARK: - JWT Max Age Tests

    @Test("JWTAuthenticator max age validation")
    func testJWTAuthenticatorMaxAge() async {
        let authenticator = JWTAuthenticator(configuration: .init(
            issuer: "https://auth.example.com",
            signingKey: .symmetric(secret: Self.testSecret),
            clockSkew: 0,
            maxAge: 300, // 5 minutes max age
            enableReplayProtection: false
        ))

        // Create a token that was issued 10 minutes ago but expires in 1 hour
        // This simulates a long-lived token that exceeds our max age policy
        let oldIat = Date().addingTimeInterval(-600) // 10 minutes ago
        let futureExp = Date().addingTimeInterval(3600) // 1 hour from now

        // Manually create JWT with old iat
        let header = #"{"alg":"HS256","typ":"JWT"}"#
        let payloadDict: [String: Any] = [
            "sub": "user-123",
            "iss": "https://auth.example.com",
            "exp": futureExp.timeIntervalSince1970,
            "iat": oldIat.timeIntervalSince1970
        ]
        let payloadData = try! JSONSerialization.data(withJSONObject: payloadDict)
        let headerB64 = base64URLEncode(header.data(using: .utf8)!)
        let payloadB64 = base64URLEncode(payloadData)
        let signedPart = "\(headerB64).\(payloadB64)"
        let key = SymmetricKey(data: Self.testSecret.data(using: .utf8)!)
        let signature = HMAC<SHA256>.authenticationCode(for: signedPart.data(using: .utf8)!, using: key)
        let signatureB64 = base64URLEncode(Data(signature))
        let jwt = "\(signedPart).\(signatureB64)"

        let credentials = Credentials.bearer(token: jwt)

        do {
            _ = try await authenticator.authenticate(credentials)
            #expect(Bool(false), "Should have thrown for token exceeding max age")
        } catch let error as AuthenticationError {
            if case .expired = error {
                // Expected
            } else {
                #expect(Bool(false), "Expected expired error, got \(error)")
            }
        } catch {
            #expect(Bool(false), "Expected AuthenticationError")
        }
    }

    // MARK: - JWT Algorithm Mismatch Tests

    @Test("JWTAuthenticator algorithm mismatch HS256 vs ES256")
    func testJWTAuthenticatorAlgorithmMismatch() async throws {
        // Configure for HS256
        let authenticator = JWTAuthenticator(configuration: .init(
            issuer: "https://auth.example.com",
            signingKey: .symmetric(secret: Self.testSecret),
            enableReplayProtection: false
        ))

        // Create ES256 token
        let privateKey = P256.Signing.PrivateKey()
        let jwt = try JWTHelper.createES256Token(
            subject: "user-123",
            issuer: "https://auth.example.com",
            privateKey: privateKey
        )

        let credentials = Credentials.bearer(token: jwt)

        do {
            _ = try await authenticator.authenticate(credentials)
            #expect(Bool(false), "Should have thrown for algorithm mismatch")
        } catch let error as AuthenticationError {
            if case .malformed(let reason) = error {
                #expect(reason.contains("Algorithm mismatch"))
            } else {
                #expect(Bool(false), "Expected malformed error, got \(error)")
            }
        } catch {
            #expect(Bool(false), "Expected AuthenticationError")
        }
    }

    // MARK: - JWT Malformed Token Tests

    @Test("JWTAuthenticator malformed token")
    func testJWTAuthenticatorMalformedToken() async {
        let authenticator = JWTAuthenticator(configuration: .init(
            issuer: "https://auth.example.com",
            signingKey: .symmetric(secret: Self.testSecret),
            enableReplayProtection: false
        ))

        let credentials = Credentials.bearer(token: "not-a-valid-jwt")

        do {
            _ = try await authenticator.authenticate(credentials)
            #expect(Bool(false), "Should have thrown for malformed token")
        } catch let error as AuthenticationError {
            if case .malformed = error {
                // Expected
            } else {
                #expect(Bool(false), "Expected malformed error")
            }
        } catch {
            #expect(Bool(false), "Expected AuthenticationError")
        }
    }

    @Test("JWTAuthenticator wrong credential type")
    func testJWTAuthenticatorWrongCredentialType() async {
        let authenticator = JWTAuthenticator(configuration: .init(
            issuer: "https://auth.example.com",
            signingKey: .symmetric(secret: Self.testSecret),
            enableReplayProtection: false
        ))

        let credentials = Credentials.apiKey(key: "some-api-key")

        do {
            _ = try await authenticator.authenticate(credentials)
            #expect(Bool(false), "Should have thrown for wrong credential type")
        } catch let error as AuthenticationError {
            if case .malformed = error {
                // Expected
            } else {
                #expect(Bool(false), "Expected malformed error")
            }
        } catch {
            #expect(Bool(false), "Expected AuthenticationError")
        }
    }

    // MARK: - JWT No Signature Validation (Testing Mode)

    @Test("JWTAuthenticator no signature validation mode")
    func testJWTAuthenticatorNoSignatureValidation() async throws {
        let authenticator = JWTAuthenticator(configuration: .init(
            issuer: "https://auth.example.com",
            audience: "my-app",
            signingKey: .none, // No signature validation
            enableReplayProtection: false
        ))

        // Create a simple JWT with mock signature
        let jwt = createMockJWT(payload: """
        {
            "sub": "user-123",
            "iss": "https://auth.example.com",
            "aud": "my-app",
            "exp": \(Date().addingTimeInterval(3600).timeIntervalSince1970),
            "roles": ["admin", "user"]
        }
        """)

        let credentials = Credentials.bearer(token: jwt)
        let principal = try await authenticator.authenticate(credentials)

        #expect(principal.id == "user-123")
        #expect(principal.hasRole("admin"))
        #expect(principal.hasRole("user"))
    }

    // MARK: - Custom Claims Tests

    @Test("JWTAuthenticator custom claims")
    func testJWTAuthenticatorCustomClaims() async throws {
        let authenticator = JWTAuthenticator(configuration: .init(
            issuer: "https://auth.example.com",
            signingKey: .symmetric(secret: Self.testSecret),
            enableReplayProtection: false
        ))

        let jwt = JWTHelper.createHS256Token(
            subject: "user-123",
            issuer: "https://auth.example.com",
            customClaims: ["tenant": "acme-corp", "department": "engineering"],
            secret: Self.testSecret
        )

        let credentials = Credentials.bearer(token: jwt)
        let principal = try await authenticator.authenticate(credentials)

        #expect(principal.id == "user-123")
        #expect(principal.attributes["tenant"] == "acme-corp")
        #expect(principal.attributes["department"] == "engineering")
    }

    // MARK: - Helper Functions

    /// Creates a mock JWT for testing (no signature validation mode only)
    private func createMockJWT(payload: String) -> String {
        let header = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}"
        let headerB64 = base64URLEncode(header.data(using: .utf8)!)
        let payloadB64 = base64URLEncode(payload.data(using: .utf8)!)
        let signature = "mock-signature"

        return "\(headerB64).\(payloadB64).\(signature)"
    }

    private func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
