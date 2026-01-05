import Distributed
import Foundation

/// The core distributed actor system for Trebuchet.
///
/// This system manages the lifecycle of distributed actors and handles
/// remote method invocations across the network.
public final class TrebuchetActorSystem: DistributedActorSystem, @unchecked Sendable {
    public typealias ActorID = TrebuchetActorID
    public typealias SerializationRequirement = Codable
    public typealias InvocationEncoder = TrebuchetEncoder
    public typealias InvocationDecoder = TrebuchetDecoder
    public typealias ResultHandler = TrebuchetResultHandler

    /// Local actors registered with this system
    private let localActors = ActorRegistry()

    /// Pending remote calls waiting for responses
    private let pendingCalls = PendingCallsRegistry()

    /// The transport layer for network communication
    private var transport: (any TrebuchetTransport)?

    /// Host this system is bound to (when acting as server)
    public private(set) var host: String?

    /// Port this system is listening on (when acting as server)
    public private(set) var port: UInt16?

    /// Encoder for wire format
    private let encoder = JSONEncoder()

    /// Decoder for wire format
    private let decoder = JSONDecoder()

    public init() {
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - DistributedActorSystem Requirements

    public func resolve<Act>(
        id: TrebuchetActorID,
        as actorType: Act.Type
    ) throws -> Act? where Act: DistributedActor, Act.ID == TrebuchetActorID {
        // For remote actors, return nil - the system will create a remote proxy
        // For local actors, we could look them up, but the system handles this
        return nil
    }

    public func assignID<Act>(
        _ actorType: Act.Type
    ) -> TrebuchetActorID where Act: DistributedActor, Act.ID == TrebuchetActorID {
        // Generate a new unique ID for a local actor
        let id = UUID().uuidString
        if let host, let port {
            return TrebuchetActorID(id: id, host: host, port: port)
        }
        return TrebuchetActorID(id: id)
    }

    public func actorReady<Act>(
        _ actor: Act
    ) where Act: DistributedActor, Act.ID == TrebuchetActorID {
        Task { await localActors.register(actor) }
    }

    public func resignID(_ id: TrebuchetActorID) {
        Task { await localActors.unregister(id: id) }
    }

    public func makeInvocationEncoder() -> TrebuchetEncoder {
        TrebuchetEncoder()
    }

    public func remoteCall<Act, Err, Res>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder,
        throwing: Err.Type,
        returning: Res.Type
    ) async throws -> Res
    where Act: DistributedActor,
          Act.ID == TrebuchetActorID,
          Err: Error,
          Res: Codable {
        let callID = UUID()
        let envelope = try invocation.build(
            callID: callID,
            actorID: actor.id,
            targetIdentifier: target.identifier
        )

        // If it's a local actor, execute directly
        if actor.id.isLocal, let localActor = await localActors.get(id: actor.id, as: Act.self) {
            return try await executeLocalCall(
                on: localActor,
                target: target,
                envelope: envelope,
                returning: Res.self
            )
        }

        // Remote call
        return try await executeRemoteCall(
            envelope: envelope,
            returning: Res.self
        )
    }

    public func remoteCallVoid<Act, Err>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder,
        throwing: Err.Type
    ) async throws
    where Act: DistributedActor,
          Act.ID == TrebuchetActorID,
          Err: Error {
        let callID = UUID()
        let envelope = try invocation.build(
            callID: callID,
            actorID: actor.id,
            targetIdentifier: target.identifier
        )

        // If it's a local actor, execute directly
        if actor.id.isLocal, let localActor = await localActors.get(id: actor.id, as: Act.self) {
            try await executeLocalCallVoid(
                on: localActor,
                target: target,
                envelope: envelope
            )
            return
        }

        // Remote call
        try await executeRemoteCallVoid(envelope: envelope)
    }

    // MARK: - Internal Methods

    /// Configure the transport layer
    func configure(transport: some TrebuchetTransport, host: String, port: UInt16) {
        self.transport = transport
        self.host = host
        self.port = port
    }

    /// Handle an incoming invocation from the network
    func handleIncomingInvocation(_ envelope: InvocationEnvelope) async -> ResponseEnvelope {
        // Find the local actor
        guard let actor = await localActors.getAny(id: envelope.actorID) else {
            return .failure(callID: envelope.callID, error: "Actor not found: \(envelope.actorID)")
        }

        // Execute the call
        do {
            var decoder = TrebuchetDecoder(envelope: envelope)
            let handler = TrebuchetResultHandler()

            try await executeDistributedTarget(
                on: actor,
                target: RemoteCallTarget(envelope.targetIdentifier),
                invocationDecoder: &decoder,
                handler: handler
            )

            if let errorMessage = handler.errorMessage {
                return .failure(callID: envelope.callID, error: errorMessage)
            }

            return .success(callID: envelope.callID, result: handler.resultData ?? Data())
        } catch {
            return .failure(callID: envelope.callID, error: String(describing: error))
        }
    }

    /// Register a pending call and wait for its response
    func registerPendingCall(id: UUID) async throws -> ResponseEnvelope {
        try await pendingCalls.wait(for: id)
    }

    /// Complete a pending call with a response
    func completePendingCall(response: ResponseEnvelope) {
        Task { await pendingCalls.complete(response) }
    }

    // MARK: - Private Methods

    private func executeLocalCall<Act, Res>(
        on actor: Act,
        target: RemoteCallTarget,
        envelope: InvocationEnvelope,
        returning: Res.Type
    ) async throws -> Res
    where Act: DistributedActor, Res: Codable {
        var invocationDecoder = TrebuchetDecoder(envelope: envelope)
        let handler = TrebuchetResultHandler()

        try await executeDistributedTarget(
            on: actor,
            target: target,
            invocationDecoder: &invocationDecoder,
            handler: handler
        )

        if let errorMessage = handler.errorMessage {
            throw TrebuchetError.remoteInvocationFailed(errorMessage)
        }

        guard let resultData = handler.resultData else {
            throw TrebuchetError.deserializationFailed(
                DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: [],
                        debugDescription: "No result data"
                    )
                )
            )
        }

        return try self.decoder.decode(Res.self, from: resultData)
    }

    private func executeLocalCallVoid<Act>(
        on actor: Act,
        target: RemoteCallTarget,
        envelope: InvocationEnvelope
    ) async throws where Act: DistributedActor {
        var invocationDecoder = TrebuchetDecoder(envelope: envelope)
        let handler = TrebuchetResultHandler()

        try await executeDistributedTarget(
            on: actor,
            target: target,
            invocationDecoder: &invocationDecoder,
            handler: handler
        )

        if let errorMessage = handler.errorMessage {
            throw TrebuchetError.remoteInvocationFailed(errorMessage)
        }
    }

    private func executeRemoteCall<Res: Codable>(
        envelope: InvocationEnvelope,
        returning: Res.Type
    ) async throws -> Res {
        guard let transport else {
            throw TrebuchetError.systemNotRunning
        }

        guard let host = envelope.actorID.host,
              let port = envelope.actorID.port else {
            throw TrebuchetError.actorNotFound(envelope.actorID)
        }

        // Send the invocation
        let data = try encoder.encode(envelope)
        try await transport.send(data, to: .init(host: host, port: port))

        // Wait for response
        let response = try await registerPendingCall(id: envelope.callID)

        if let errorMessage = response.errorMessage {
            throw TrebuchetError.remoteInvocationFailed(errorMessage)
        }

        guard let resultData = response.result else {
            throw TrebuchetError.deserializationFailed(
                DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: [],
                        debugDescription: "No result data in response"
                    )
                )
            )
        }

        return try decoder.decode(Res.self, from: resultData)
    }

    private func executeRemoteCallVoid(envelope: InvocationEnvelope) async throws {
        guard let transport else {
            throw TrebuchetError.systemNotRunning
        }

        guard let host = envelope.actorID.host,
              let port = envelope.actorID.port else {
            throw TrebuchetError.actorNotFound(envelope.actorID)
        }

        // Send the invocation
        let data = try encoder.encode(envelope)
        try await transport.send(data, to: .init(host: host, port: port))

        // Wait for response
        let response = try await registerPendingCall(id: envelope.callID)

        if let errorMessage = response.errorMessage {
            throw TrebuchetError.remoteInvocationFailed(errorMessage)
        }
    }
}

// MARK: - Actor Registry

/// Thread-safe registry for local actors
private actor ActorRegistry {
    private var actors: [TrebuchetActorID: any DistributedActor] = [:]

    func register(_ actor: some DistributedActor) {
        guard let id = actor.id as? TrebuchetActorID else { return }
        actors[id] = actor
    }

    func unregister(id: TrebuchetActorID) {
        actors.removeValue(forKey: id)
    }

    func get<Act: DistributedActor>(id: TrebuchetActorID, as type: Act.Type) -> Act? {
        actors[id] as? Act
    }

    func getAny(id: TrebuchetActorID) -> (any DistributedActor)? {
        actors[id]
    }
}

// MARK: - Pending Calls Registry

/// Thread-safe registry for pending remote calls
private actor PendingCallsRegistry {
    private var pending: [UUID: CheckedContinuation<ResponseEnvelope, Error>] = [:]

    func wait(for id: UUID) async throws -> ResponseEnvelope {
        try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
        }
    }

    func complete(_ response: ResponseEnvelope) {
        if let continuation = pending.removeValue(forKey: response.callID) {
            continuation.resume(returning: response)
        }
    }

    func fail(id: UUID, error: Error) {
        if let continuation = pending.removeValue(forKey: id) {
            continuation.resume(throwing: error)
        }
    }
}
