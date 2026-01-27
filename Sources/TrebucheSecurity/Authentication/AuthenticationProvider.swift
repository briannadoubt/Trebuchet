// AuthenticationProvider.swift
// Protocol for authentication providers

import Foundation

/// Protocol for authentication providers
public protocol AuthenticationProvider: Sendable {
    /// Authenticates credentials and returns a principal
    /// - Parameter credentials: Credentials to authenticate
    /// - Returns: Authenticated principal
    /// - Throws: AuthenticationError if authentication fails
    func authenticate(_ credentials: Credentials) async throws -> Principal
}

/// Authentication errors
public enum AuthenticationError: Error, Sendable {
    /// Invalid credentials
    case invalidCredentials

    /// Expired credentials
    case expired

    /// Malformed credentials
    case malformed(reason: String)

    /// Authentication provider unavailable
    case unavailable

    /// Custom error
    case custom(message: String)
}

extension AuthenticationError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidCredentials:
            return "Invalid credentials"
        case .expired:
            return "Credentials have expired"
        case .malformed(let reason):
            return "Malformed credentials: \(reason)"
        case .unavailable:
            return "Authentication provider unavailable"
        case .custom(let message):
            return message
        }
    }
}
