import Foundation
import Distributed

// MARK: - Method Signature

/// Represents a versioned method signature for protocol compatibility
public struct MethodSignature: Hashable, Codable, Sendable {
    /// Method name
    public let name: String

    /// Parameter types as strings
    public let parameterTypes: [String]

    /// Return type as string
    public let returnType: String

    /// Protocol version when this method was introduced
    public let version: UInt32

    /// Target identifier (mangled name)
    public let targetIdentifier: String

    public init(
        name: String,
        parameterTypes: [String],
        returnType: String,
        version: UInt32,
        targetIdentifier: String
    ) {
        self.name = name
        self.parameterTypes = parameterTypes
        self.returnType = returnType
        self.version = version
        self.targetIdentifier = targetIdentifier
    }
}

// MARK: - Method Registry

/// Registry for tracking method signatures across protocol versions
public actor MethodRegistry {
    /// Maps target identifier to all its versions
    private var methods: [String: [MethodSignature]] = [:]

    /// Maps old target identifiers to new ones for method renames
    private var redirects: [String: String] = [:]

    public init() {}

    /// Register a method signature
    /// - Parameter signature: The method signature to register
    public func register(_ signature: MethodSignature) {
        methods[signature.targetIdentifier, default: []].append(signature)
    }

    /// Register multiple method signatures
    /// - Parameter signatures: The method signatures to register
    public func register(_ signatures: [MethodSignature]) {
        for signature in signatures {
            register(signature)
        }
    }

    /// Register a redirect from an old target identifier to a new one
    /// Useful for handling method renames
    /// - Parameters:
    ///   - oldIdentifier: The old target identifier
    ///   - newIdentifier: The new target identifier
    public func registerRedirect(from oldIdentifier: String, to newIdentifier: String) {
        redirects[oldIdentifier] = newIdentifier
    }

    /// Resolve a method signature for a given protocol version
    /// - Parameters:
    ///   - identifier: The target identifier
    ///   - protocolVersion: The client's protocol version
    /// - Returns: The best matching method signature, or nil if not found
    public func resolve(
        identifier: String,
        protocolVersion: UInt32
    ) -> MethodSignature? {
        // Check for redirects first
        let resolvedIdentifier = redirects[identifier] ?? identifier

        // Find all signatures for this identifier
        guard let signatures = methods[resolvedIdentifier] else {
            return nil
        }

        // Find the newest signature that's compatible with the client's version
        return signatures
            .filter { $0.version <= protocolVersion }
            .max(by: { $0.version < $1.version })
    }

    /// Get all registered method signatures
    /// - Returns: All registered signatures
    public func allSignatures() -> [MethodSignature] {
        methods.values.flatMap { $0 }
    }

    /// Get all signatures for a specific target identifier
    /// - Parameter identifier: The target identifier
    /// - Returns: All signatures for the identifier
    public func signatures(for identifier: String) -> [MethodSignature] {
        methods[identifier] ?? []
    }

    /// Clear all registered methods and redirects
    public func clear() {
        methods.removeAll()
        redirects.removeAll()
    }
}

// MARK: - Protocol Negotiation

/// Result of protocol version negotiation
public struct NegotiatedProtocol: Sendable {
    /// The negotiated protocol version
    public let version: UInt32

    /// Whether the client is using an older version
    public let isClientOutdated: Bool

    /// Whether the server is using an older version
    public let isServerOutdated: Bool

    public init(version: UInt32, clientVersion: UInt32, serverVersion: UInt32) {
        self.version = version
        self.isClientOutdated = clientVersion < serverVersion
        self.isServerOutdated = serverVersion < clientVersion
    }
}

/// Protocol negotiator for determining compatibility between client and server
public struct ProtocolNegotiator: Sendable {
    /// Minimum supported protocol version
    public let minVersion: UInt32

    /// Maximum supported protocol version
    public let maxVersion: UInt32

    public init(minVersion: UInt32, maxVersion: UInt32) {
        self.minVersion = minVersion
        self.maxVersion = maxVersion
    }

    /// Negotiate protocol version with a client
    /// - Parameter clientVersion: The client's protocol version
    /// - Returns: The negotiated protocol, or nil if incompatible
    public func negotiate(with clientVersion: UInt32) -> NegotiatedProtocol? {
        // Find the highest mutually supported version
        let negotiated = min(clientVersion, maxVersion)

        // Check if negotiated version is within our supported range
        guard negotiated >= minVersion else {
            return nil // Incompatible
        }

        return NegotiatedProtocol(
            version: negotiated,
            clientVersion: clientVersion,
            serverVersion: maxVersion
        )
    }

    /// Check if a protocol version is supported
    /// - Parameter version: The protocol version to check
    /// - Returns: True if supported
    public func supports(version: UInt32) -> Bool {
        version >= minVersion && version <= maxVersion
    }
}

extension ProtocolNegotiator {
    /// Default negotiator supporting v1 and v2
    public static let `default` = ProtocolNegotiator(
        minVersion: TrebuchetProtocolVersion.minimum,
        maxVersion: TrebuchetProtocolVersion.current
    )
}
