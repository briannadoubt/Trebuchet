// RoleBasedPolicy.swift
// Role-based access control (RBAC) policy

import Foundation

/// Role-based access control policy
public struct RoleBasedPolicy: AuthorizationPolicy {
    /// Access rule
    public struct Rule: Sendable {
        /// Role that grants access
        public let role: String

        /// Actor type pattern (* for all)
        public let actorType: String

        /// Method pattern (* for all)
        public let method: String

        /// Resource type pattern (optional, * for all)
        public let resourceType: String?

        /// Creates a new access rule
        /// - Parameters:
        ///   - role: Role name
        ///   - actorType: Actor type pattern
        ///   - method: Method pattern
        ///   - resourceType: Resource type pattern (optional)
        public init(
            role: String,
            actorType: String = "*",
            method: String = "*",
            resourceType: String? = nil
        ) {
            self.role = role
            self.actorType = actorType
            self.method = method
            self.resourceType = resourceType
        }
    }

    private let rules: [Rule]
    private let denyByDefault: Bool

    /// Creates a new role-based policy
    /// - Parameters:
    ///   - rules: Access rules
    ///   - denyByDefault: Deny access if no rule matches (default: true)
    public init(rules: [Rule], denyByDefault: Bool = true) {
        self.rules = rules
        self.denyByDefault = denyByDefault
    }

    public func authorize(
        _ principal: Principal,
        action: Action,
        resource: Resource
    ) async throws -> Bool {
        // Check each rule
        for rule in rules {
            // Check if principal has the required role
            guard principal.hasRole(rule.role) else {
                continue
            }

            // Check if rule matches the action
            guard matches(pattern: rule.actorType, value: action.actorType) else {
                continue
            }

            guard matches(pattern: rule.method, value: action.method) else {
                continue
            }

            // Check if rule matches the resource
            if let resourcePattern = rule.resourceType {
                guard matches(pattern: resourcePattern, value: resource.type) else {
                    continue
                }
            }

            // Rule matches - allow access
            return true
        }

        // No matching rule found
        return !denyByDefault
    }

    /// Checks if a pattern matches a value
    /// - Parameters:
    ///   - pattern: Pattern (* for wildcard)
    ///   - value: Value to match
    /// - Returns: True if matches
    private func matches(pattern: String, value: String) -> Bool {
        if pattern == "*" {
            return true
        }

        // Support simple prefix matching with *
        if pattern.hasSuffix("*") {
            let prefix = String(pattern.dropLast())
            return value.hasPrefix(prefix)
        }

        // Support simple suffix matching with *
        if pattern.hasPrefix("*") {
            let suffix = String(pattern.dropFirst())
            return value.hasSuffix(suffix)
        }

        // Exact match
        return pattern == value
    }
}

/// Predefined rules for common scenarios
public extension RoleBasedPolicy.Rule {
    /// Admin has full access
    static let adminFullAccess = RoleBasedPolicy.Rule(
        role: "admin",
        actorType: "*",
        method: "*"
    )

    /// User can read
    static let userReadOnly = RoleBasedPolicy.Rule(
        role: "user",
        actorType: "*",
        method: "get*"
    )

    /// Service can invoke
    static let serviceInvoke = RoleBasedPolicy.Rule(
        role: "service",
        actorType: "*",
        method: "*"
    )
}

/// Predefined policies
public extension RoleBasedPolicy {
    /// Admin-only policy
    static let adminOnly = RoleBasedPolicy(rules: [.adminFullAccess])

    /// Admin full + user read-only
    static let adminUserRead = RoleBasedPolicy(rules: [
        .adminFullAccess,
        .userReadOnly
    ])
}
