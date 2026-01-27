// AuthenticationTests.swift
// Tests for authentication providers

import Testing
import Foundation
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

    // MARK: - JWT Authenticator Tests

    @Test("JWTAuthenticator valid token")
    func testJWTAuthenticatorValidToken() async throws {
        let authenticator = JWTAuthenticator(configuration: .init(
            issuer: "https://auth.example.com",
            audience: "my-app"
        ))

        // Create a simple JWT (header.payload.signature)
        // This is a mock JWT for testing - in production use proper signing
        let futureExp = Date().addingTimeInterval(3600).timeIntervalSince1970
        let payload = """
        {
            "sub": "user-123",
            "iss": "https://auth.example.com",
            "aud": "my-app",
            "exp": \(futureExp),
            "roles": ["admin", "user"]
        }
        """

        let jwt = createMockJWT(payload: payload)
        let credentials = Credentials.bearer(token: jwt)

        let principal = try await authenticator.authenticate(credentials)

        #expect(principal.id == "user-123")
        #expect(principal.hasRole("admin"))
        #expect(principal.hasRole("user"))
    }

    @Test("JWTAuthenticator wrong issuer")
    func testJWTAuthenticatorWrongIssuer() async {
        let authenticator = JWTAuthenticator(configuration: .init(
            issuer: "https://auth.example.com"
        ))

        let payload = """
        {
            "sub": "user-123",
            "iss": "https://wrong-issuer.com",
            "exp": \(Date().addingTimeInterval(3600).timeIntervalSince1970)
        }
        """

        let jwt = createMockJWT(payload: payload)
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

    @Test("JWTAuthenticator expired token")
    func testJWTAuthenticatorExpiredToken() async {
        let authenticator = JWTAuthenticator(configuration: .init(
            issuer: "https://auth.example.com",
            clockSkew: 0  // No tolerance
        ))

        let pastExp = Date().addingTimeInterval(-3600).timeIntervalSince1970
        let payload = """
        {
            "sub": "user-123",
            "iss": "https://auth.example.com",
            "exp": \(pastExp)
        }
        """

        let jwt = createMockJWT(payload: payload)
        let credentials = Credentials.bearer(token: jwt)

        do {
            _ = try await authenticator.authenticate(credentials)
            #expect(Bool(false), "Should have thrown for expired token")
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

    @Test("JWTAuthenticator malformed token")
    func testJWTAuthenticatorMalformedToken() async {
        let authenticator = JWTAuthenticator(configuration: .init(
            issuer: "https://auth.example.com"
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

    // MARK: - Helper Functions

    /// Creates a mock JWT for testing
    /// Note: This does NOT create a properly signed JWT. For testing only!
    private func createMockJWT(payload: String) -> String {
        let header = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}"
        let headerB64 = base64URLEncode(header)
        let payloadB64 = base64URLEncode(payload)
        let signature = "mock-signature"

        return "\(headerB64).\(payloadB64).\(signature)"
    }

    private func base64URLEncode(_ string: String) -> String {
        let data = string.data(using: .utf8)!
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
