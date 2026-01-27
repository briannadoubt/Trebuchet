// APIKeyAuthenticator.swift
// API key-based authentication

import Foundation

/// API key authenticator
public actor APIKeyAuthenticator: AuthenticationProvider {
    /// API key configuration
    public struct APIKeyConfig: Sendable {
        /// API key value
        public let key: String

        /// Principal ID associated with this key
        public let principalId: String

        /// Roles for this key
        public let roles: Set<String>

        /// Optional expiration
        public let expiresAt: Date?

        /// Creates a new API key configuration
        public init(
            key: String,
            principalId: String,
            roles: Set<String> = [],
            expiresAt: Date? = nil
        ) {
            self.key = key
            self.principalId = principalId
            self.roles = roles
            self.expiresAt = expiresAt
        }
    }

    private var apiKeys: [String: APIKeyConfig] = [:]

    /// Creates a new API key authenticator
    /// - Parameter keys: Configured API keys
    public init(keys: [APIKeyConfig] = []) {
        for key in keys {
            apiKeys[key.key] = key
        }
    }

    /// Registers a new API key
    /// - Parameter config: API key configuration
    public func register(_ config: APIKeyConfig) {
        apiKeys[config.key] = config
    }

    /// Revokes an API key
    /// - Parameter key: API key to revoke
    public func revoke(_ key: String) {
        apiKeys.removeValue(forKey: key)
    }

    public func authenticate(_ credentials: Credentials) async throws -> Principal {
        let key: String

        switch credentials {
        case .apiKey(let k):
            key = k
        case .bearer(let token):
            // Support bearer token format for API keys
            key = token
        default:
            throw AuthenticationError.malformed(reason: "Expected API key")
        }

        guard let config = apiKeys[key] else {
            throw AuthenticationError.invalidCredentials
        }

        // Check expiration
        if let expiresAt = config.expiresAt, Date() > expiresAt {
            throw AuthenticationError.expired
        }

        return Principal(
            id: config.principalId,
            type: .service,
            roles: config.roles,
            expiresAt: config.expiresAt
        )
    }
}
