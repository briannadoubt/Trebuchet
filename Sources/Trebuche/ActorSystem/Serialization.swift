import Distributed
import Foundation

/// Encoder for remote method invocations
public struct TrebuchetEncoder: DistributedTargetInvocationEncoder {
    public typealias SerializationRequirement = Codable

    private var genericSubstitutions: [String] = []
    private var arguments: [Data] = []
    private let encoder: JSONEncoder

    public init() {
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
    }

    public mutating func recordGenericSubstitution<T>(_ type: T.Type) throws {
        genericSubstitutions.append(String(reflecting: type))
    }

    public mutating func recordArgument<Value: Codable>(
        _ argument: RemoteCallArgument<Value>
    ) throws {
        let data = try encoder.encode(argument.value)
        arguments.append(data)
    }

    public mutating func recordReturnType<R: Codable>(_ type: R.Type) throws {
        // We track the return type in the envelope, not here
    }

    public mutating func recordErrorType<E: Error>(_ type: E.Type) throws {
        // Error type tracking for future use
    }

    public mutating func doneRecording() throws {
        // Finalization complete
    }

    /// Build the final encoded invocation
    func build(
        callID: UUID,
        actorID: TrebuchetActorID,
        targetIdentifier: String
    ) throws -> InvocationEnvelope {
        InvocationEnvelope(
            callID: callID,
            actorID: actorID,
            targetIdentifier: targetIdentifier,
            genericSubstitutions: genericSubstitutions,
            arguments: arguments
        )
    }
}

/// Decoder for remote method invocations
public struct TrebuchetDecoder: DistributedTargetInvocationDecoder {
    public typealias SerializationRequirement = Codable

    private let envelope: InvocationEnvelope
    private var argumentIndex: Int = 0
    private let decoder: JSONDecoder

    public init(envelope: InvocationEnvelope) {
        self.envelope = envelope
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public mutating func decodeGenericSubstitutions() throws -> [Any.Type] {
        // For now, we don't support generic substitutions at runtime
        // This would require a type registry
        []
    }

    public mutating func decodeNextArgument<Argument: Codable>() throws -> Argument {
        guard argumentIndex < envelope.arguments.count else {
            throw TrebuchetError.deserializationFailed(
                DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: [],
                        debugDescription: "Not enough arguments in invocation"
                    )
                )
            )
        }
        let data = envelope.arguments[argumentIndex]
        argumentIndex += 1
        return try decoder.decode(Argument.self, from: data)
    }

    public mutating func decodeErrorType() throws -> Any.Type? {
        nil // We use generic Error handling
    }

    public mutating func decodeReturnType() throws -> Any.Type? {
        nil // Return type is known at the call site
    }
}

/// Handler for processing the result of a remote call
public final class TrebuchetResultHandler: DistributedTargetInvocationResultHandler, @unchecked Sendable {
    public typealias SerializationRequirement = Codable

    private let encoder: JSONEncoder
    public private(set) var resultData: Data?
    public private(set) var errorMessage: String?

    public init() {
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
    }

    public func onReturn<Success: Codable>(value: Success) async throws {
        resultData = try encoder.encode(value)
    }

    public func onReturnVoid() async throws {
        resultData = Data() // Empty data for void
    }

    public func onThrow<Err: Error>(error: Err) async throws {
        errorMessage = String(describing: error)
    }
}

/// Wire format for a remote method invocation
public struct InvocationEnvelope: Codable, Sendable {
    public let callID: UUID
    public let actorID: TrebuchetActorID
    public let targetIdentifier: String
    public let genericSubstitutions: [String]
    public let arguments: [Data]

    public init(
        callID: UUID,
        actorID: TrebuchetActorID,
        targetIdentifier: String,
        genericSubstitutions: [String],
        arguments: [Data]
    ) {
        self.callID = callID
        self.actorID = actorID
        self.targetIdentifier = targetIdentifier
        self.genericSubstitutions = genericSubstitutions
        self.arguments = arguments
    }
}

/// Wire format for a remote call response
public struct ResponseEnvelope: Codable, Sendable {
    public let callID: UUID
    public let result: Data?
    public let errorMessage: String?

    public var isSuccess: Bool {
        errorMessage == nil
    }

    public init(callID: UUID, result: Data?, errorMessage: String?) {
        self.callID = callID
        self.result = result
        self.errorMessage = errorMessage
    }

    public static func success(callID: UUID, result: Data) -> ResponseEnvelope {
        ResponseEnvelope(callID: callID, result: result, errorMessage: nil)
    }

    public static func failure(callID: UUID, error: String) -> ResponseEnvelope {
        ResponseEnvelope(callID: callID, result: nil, errorMessage: error)
    }
}
