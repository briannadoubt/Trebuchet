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
        targetIdentifier: String,
        streamFilter: StreamFilter? = nil,
        protocolVersion: UInt32 = TrebuchetProtocolVersion.current
    ) throws -> InvocationEnvelope {
        InvocationEnvelope(
            callID: callID,
            actorID: actorID,
            targetIdentifier: targetIdentifier,
            protocolVersion: protocolVersion,
            genericSubstitutions: genericSubstitutions,
            arguments: arguments,
            streamFilter: streamFilter
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

/// Marker type indicating a streaming subscription has been established
/// This is Codable so it can be returned from distributed methods
public struct StreamSubscription: Codable, Sendable {
    public let streamID: UUID
    public let propertyName: String

    public init(streamID: UUID, propertyName: String) {
        self.streamID = streamID
        self.propertyName = propertyName
    }
}

/// Wire format for stream resumption after reconnection
public struct StreamResumeEnvelope: Codable, Sendable {
    public let streamID: UUID
    public let lastSequence: UInt64
    public let actorID: TrebuchetActorID
    public let targetIdentifier: String

    public init(streamID: UUID, lastSequence: UInt64, actorID: TrebuchetActorID, targetIdentifier: String) {
        self.streamID = streamID
        self.lastSequence = lastSequence
        self.actorID = actorID
        self.targetIdentifier = targetIdentifier
    }
}

/// Protocol version constants
public enum TrebuchetProtocolVersion {
    /// Version 1: Initial protocol
    public static let v1: UInt32 = 1

    /// Version 2: Adds protocol versioning and backward compatibility
    public static let v2: UInt32 = 2

    /// Current protocol version used by this build
    public static let current: UInt32 = v2

    /// Minimum supported protocol version
    public static let minimum: UInt32 = v1
}

/// Wire format for a remote method invocation
public struct InvocationEnvelope: Codable, Sendable {
    public let callID: UUID
    public let actorID: TrebuchetActorID
    public let targetIdentifier: String
    public let protocolVersion: UInt32  // Protocol version for backward compatibility
    public let genericSubstitutions: [String]
    public let arguments: [Data]
    public let streamFilter: StreamFilter?  // Optional filter for streaming methods
    public let traceContext: TraceContext?  // Optional trace context for distributed tracing

    public init(
        callID: UUID,
        actorID: TrebuchetActorID,
        targetIdentifier: String,
        protocolVersion: UInt32 = TrebuchetProtocolVersion.current,
        genericSubstitutions: [String],
        arguments: [Data],
        streamFilter: StreamFilter? = nil,
        traceContext: TraceContext? = nil
    ) {
        self.callID = callID
        self.actorID = actorID
        self.targetIdentifier = targetIdentifier
        self.protocolVersion = protocolVersion
        self.genericSubstitutions = genericSubstitutions
        self.arguments = arguments
        self.streamFilter = streamFilter
        self.traceContext = traceContext
    }

    // Custom decoding for backward compatibility with v1 clients
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        callID = try container.decode(UUID.self, forKey: .callID)
        actorID = try container.decode(TrebuchetActorID.self, forKey: .actorID)
        targetIdentifier = try container.decode(String.self, forKey: .targetIdentifier)
        // Default to v1 if not present (backward compatibility)
        protocolVersion = try container.decodeIfPresent(UInt32.self, forKey: .protocolVersion) ?? TrebuchetProtocolVersion.v1
        genericSubstitutions = try container.decode([String].self, forKey: .genericSubstitutions)
        arguments = try container.decode([Data].self, forKey: .arguments)
        streamFilter = try container.decodeIfPresent(StreamFilter.self, forKey: .streamFilter)
        traceContext = try container.decodeIfPresent(TraceContext.self, forKey: .traceContext)
    }

    enum CodingKeys: String, CodingKey {
        case callID
        case actorID
        case targetIdentifier
        case protocolVersion
        case genericSubstitutions
        case arguments
        case streamFilter
        case traceContext
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

// MARK: - Streaming Envelopes

/// Wire format for stream initiation
public struct StreamStartEnvelope: Codable, Sendable {
    public let streamID: UUID
    public let callID: UUID
    public let actorID: TrebuchetActorID
    public let targetIdentifier: String
    public let filter: StreamFilter?  // Optional filter for server-side filtering

    public init(streamID: UUID, callID: UUID, actorID: TrebuchetActorID, targetIdentifier: String, filter: StreamFilter? = nil) {
        self.streamID = streamID
        self.callID = callID
        self.actorID = actorID
        self.targetIdentifier = targetIdentifier
        self.filter = filter
    }
}

/// Wire format for stream data update
public struct StreamDataEnvelope: Codable, Sendable {
    public let streamID: UUID
    public let sequenceNumber: UInt64
    public let data: Data
    public let timestamp: Date

    public init(streamID: UUID, sequenceNumber: UInt64, data: Data, timestamp: Date = Date()) {
        self.streamID = streamID
        self.sequenceNumber = sequenceNumber
        self.data = data
        self.timestamp = timestamp
    }
}

/// Reason for stream termination
public enum StreamEndReason: String, Codable, Sendable {
    case completed
    case actorTerminated
    case clientUnsubscribed
    case connectionClosed
    case error
}

/// Wire format for stream completion
public struct StreamEndEnvelope: Codable, Sendable {
    public let streamID: UUID
    public let reason: StreamEndReason

    public init(streamID: UUID, reason: StreamEndReason) {
        self.streamID = streamID
        self.reason = reason
    }
}

/// Wire format for stream error
public struct StreamErrorEnvelope: Codable, Sendable {
    public let streamID: UUID
    public let errorMessage: String

    public init(streamID: UUID, errorMessage: String) {
        self.streamID = streamID
        self.errorMessage = errorMessage
    }
}

/// Discriminated union for all Trebuchet message types
public enum TrebuchetEnvelope: Codable, Sendable {
    case invocation(InvocationEnvelope)
    case response(ResponseEnvelope)
    case streamStart(StreamStartEnvelope)
    case streamData(StreamDataEnvelope)
    case streamEnd(StreamEndEnvelope)
    case streamError(StreamErrorEnvelope)
    case streamResume(StreamResumeEnvelope)

    enum CodingKeys: String, CodingKey {
        case type
        case payload
    }

    enum EnvelopeType: String, Codable {
        case invocation
        case response
        case streamStart
        case streamData
        case streamEnd
        case streamError
        case streamResume
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .invocation(let envelope):
            try container.encode(EnvelopeType.invocation, forKey: .type)
            try container.encode(envelope, forKey: .payload)
        case .response(let envelope):
            try container.encode(EnvelopeType.response, forKey: .type)
            try container.encode(envelope, forKey: .payload)
        case .streamStart(let envelope):
            try container.encode(EnvelopeType.streamStart, forKey: .type)
            try container.encode(envelope, forKey: .payload)
        case .streamData(let envelope):
            try container.encode(EnvelopeType.streamData, forKey: .type)
            try container.encode(envelope, forKey: .payload)
        case .streamEnd(let envelope):
            try container.encode(EnvelopeType.streamEnd, forKey: .type)
            try container.encode(envelope, forKey: .payload)
        case .streamError(let envelope):
            try container.encode(EnvelopeType.streamError, forKey: .type)
            try container.encode(envelope, forKey: .payload)
        case .streamResume(let envelope):
            try container.encode(EnvelopeType.streamResume, forKey: .type)
            try container.encode(envelope, forKey: .payload)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(EnvelopeType.self, forKey: .type)

        switch type {
        case .invocation:
            let envelope = try container.decode(InvocationEnvelope.self, forKey: .payload)
            self = .invocation(envelope)
        case .response:
            let envelope = try container.decode(ResponseEnvelope.self, forKey: .payload)
            self = .response(envelope)
        case .streamStart:
            let envelope = try container.decode(StreamStartEnvelope.self, forKey: .payload)
            self = .streamStart(envelope)
        case .streamData:
            let envelope = try container.decode(StreamDataEnvelope.self, forKey: .payload)
            self = .streamData(envelope)
        case .streamEnd:
            let envelope = try container.decode(StreamEndEnvelope.self, forKey: .payload)
            self = .streamEnd(envelope)
        case .streamError:
            let envelope = try container.decode(StreamErrorEnvelope.self, forKey: .payload)
            self = .streamError(envelope)
        case .streamResume:
            let envelope = try container.decode(StreamResumeEnvelope.self, forKey: .payload)
            self = .streamResume(envelope)
        }
    }
}
