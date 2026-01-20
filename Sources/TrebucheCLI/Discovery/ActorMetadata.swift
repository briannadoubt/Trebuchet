import Foundation

/// Metadata about a discovered distributed actor
public struct ActorMetadata: Sendable, Codable, Hashable {
    /// The actor's type name
    public let name: String

    /// The file where the actor is defined
    public let filePath: String

    /// Line number where the actor is declared
    public let lineNumber: Int

    /// Distributed methods exposed by this actor
    public let methods: [MethodMetadata]

    /// Whether the actor conforms to StatefulActor
    public let isStateful: Bool

    /// Custom configuration specified in comments
    public let annotations: [String: String]

    public init(
        name: String,
        filePath: String,
        lineNumber: Int,
        methods: [MethodMetadata],
        isStateful: Bool = false,
        annotations: [String: String] = [:]
    ) {
        self.name = name
        self.filePath = filePath
        self.lineNumber = lineNumber
        self.methods = methods
        self.isStateful = isStateful
        self.annotations = annotations
    }
}

/// Metadata about a distributed method
public struct MethodMetadata: Sendable, Codable, Hashable {
    /// Method name (e.g., "join")
    public let name: String

    /// Full method signature (e.g., "join(player:)")
    public let signature: String

    /// Parameter types
    public let parameters: [ParameterMetadata]

    /// Return type (nil for void)
    public let returnType: String?

    /// Whether the method can throw
    public let canThrow: Bool

    public init(
        name: String,
        signature: String,
        parameters: [ParameterMetadata],
        returnType: String?,
        canThrow: Bool
    ) {
        self.name = name
        self.signature = signature
        self.parameters = parameters
        self.returnType = returnType
        self.canThrow = canThrow
    }
}

/// Metadata about a method parameter
public struct ParameterMetadata: Sendable, Codable, Hashable {
    /// External parameter name (nil if _)
    public let label: String?

    /// Internal parameter name
    public let name: String

    /// Type name
    public let type: String

    public init(label: String?, name: String, type: String) {
        self.label = label
        self.name = name
        self.type = type
    }
}
