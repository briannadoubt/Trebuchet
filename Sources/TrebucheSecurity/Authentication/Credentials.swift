// Credentials.swift
// Authentication credentials types

import Foundation

/// Credentials for authentication
public enum Credentials: Sendable {
    /// Bearer token (e.g., JWT)
    case bearer(token: String)

    /// API key
    case apiKey(key: String)

    /// Basic authentication (username:password)
    case basic(username: String, password: String)

    /// Custom credentials
    case custom(type: String, value: String)
}

/// Principal representing an authenticated user/service
public struct Principal: Sendable, Codable {
    /// Unique identifier for the principal
    public let id: String

    /// Principal type (user, service, etc.)
    public let type: PrincipalType

    /// Roles assigned to the principal
    public let roles: Set<String>

    /// Additional attributes
    public let attributes: [String: String]

    /// Timestamp when authentication occurred
    public let authenticatedAt: Date

    /// Optional expiration time
    public let expiresAt: Date?

    /// Creates a new principal
    /// - Parameters:
    ///   - id: Principal ID
    ///   - type: Principal type
    ///   - roles: Assigned roles
    ///   - attributes: Additional attributes
    ///   - authenticatedAt: Authentication timestamp (defaults to now)
    ///   - expiresAt: Optional expiration time
    public init(
        id: String,
        type: PrincipalType = .user,
        roles: Set<String> = [],
        attributes: [String: String] = [:],
        authenticatedAt: Date = Date(),
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.type = type
        self.roles = roles
        self.attributes = attributes
        self.authenticatedAt = authenticatedAt
        self.expiresAt = expiresAt
    }

    /// Checks if the principal has a specific role
    /// - Parameter role: Role to check
    /// - Returns: True if the principal has the role
    public func hasRole(_ role: String) -> Bool {
        roles.contains(role)
    }

    /// Checks if the principal has any of the specified roles
    /// - Parameter roles: Roles to check
    /// - Returns: True if the principal has at least one of the roles
    public func hasAnyRole(_ roles: Set<String>) -> Bool {
        !self.roles.isDisjoint(with: roles)
    }

    /// Checks if the principal has all of the specified roles
    /// - Parameter roles: Roles to check
    /// - Returns: True if the principal has all of the roles
    public func hasAllRoles(_ roles: Set<String>) -> Bool {
        self.roles.isSuperset(of: roles)
    }

    /// Checks if the principal is expired
    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() > expiresAt
    }
}

/// Type of principal
public enum PrincipalType: String, Sendable, Codable {
    /// Human user
    case user

    /// Service account
    case service

    /// System component
    case system
}
