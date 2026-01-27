// AuthorizationPolicy.swift
// Authorization policy protocol

import Foundation

/// Action being performed on a resource
public struct Action: Sendable, Hashable, Codable {
    /// Actor type being accessed
    public let actorType: String

    /// Method being invoked
    public let method: String

    /// Creates a new action
    /// - Parameters:
    ///   - actorType: Actor type
    ///   - method: Method name
    public init(actorType: String, method: String) {
        self.actorType = actorType
        self.method = method
    }
}

/// Resource being accessed
public struct Resource: Sendable, Hashable, Codable {
    /// Resource type
    public let type: String

    /// Resource ID
    public let id: String?

    /// Additional attributes
    public let attributes: [String: String]

    /// Creates a new resource
    /// - Parameters:
    ///   - type: Resource type
    ///   - id: Resource ID (optional)
    ///   - attributes: Additional attributes
    public init(
        type: String,
        id: String? = nil,
        attributes: [String: String] = [:]
    ) {
        self.type = type
        self.id = id
        self.attributes = attributes
    }
}

/// Protocol for authorization policies
public protocol AuthorizationPolicy: Sendable {
    /// Determines if a principal is authorized to perform an action on a resource
    /// - Parameters:
    ///   - principal: The principal requesting access
    ///   - action: The action to perform
    ///   - resource: The resource being accessed
    /// - Returns: True if authorized
    func authorize(
        _ principal: Principal,
        action: Action,
        resource: Resource
    ) async throws -> Bool
}

/// Authorization errors
public enum AuthorizationError: Error, Sendable {
    /// Access denied
    case accessDenied

    /// Policy evaluation failed
    case evaluationFailed(reason: String)

    /// Custom error
    case custom(message: String)
}

extension AuthorizationError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .accessDenied:
            return "Access denied"
        case .evaluationFailed(let reason):
            return "Policy evaluation failed: \(reason)"
        case .custom(let message):
            return message
        }
    }
}
