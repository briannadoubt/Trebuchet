import Distributed
import Foundation

/// A server that hosts distributed actors and handles incoming connections.
///
/// Example usage:
/// ```swift
/// let server = TrebuchetServer(transport: .webSocket(port: 8080))
/// let room = GameRoom(actorSystem: server.actorSystem)
/// await server.expose(room, as: "main-room")
/// try await server.run()
/// ```
public final class TrebuchetServer: Sendable {
    /// The actor system used by this server
    public let actorSystem: TrebuchetActorSystem

    /// The transport configuration
    private let transportConfig: TransportConfiguration

    /// The transport layer
    private let transport: any TrebuchetTransport

    /// Registry of exposed actors by name
    private let exposedActors = ExposedActorRegistry()

    /// Registry of streaming handlers by type
    private let streamingHandlers = StreamingHandlerRegistry()

    /// Create a new server with the specified transport
    /// - Parameter transport: The transport configuration (e.g., `.webSocket(port: 8080)`)
    public init(transport: TransportConfiguration) {
        self.transportConfig = transport
        self.actorSystem = TrebuchetActorSystem()

        switch transport {
        case .webSocket(_, _, let tls):
            self.transport = WebSocketTransport(tlsConfiguration: tls)
        case .tcp:
            fatalError("TCP transport not yet implemented")
        }

        // Configure the actor system with transport info
        actorSystem.configure(
            transport: self.transport,
            host: transport.endpoint.host,
            port: transport.endpoint.port
        )

        // Set up the main streaming handler to dispatch to registered handlers
        let handlers = streamingHandlers
        actorSystem.streamingHandler = { envelope, actor in
            try await handlers.handle(envelope: envelope, actor: actor)
        }
    }

    /// Expose an actor with a given name so clients can resolve it
    /// - Parameters:
    ///   - actor: The distributed actor to expose
    ///   - name: The name clients will use to resolve this actor
    public func expose<Act: DistributedActor>(_ actor: Act, as name: String) async where Act.ID == TrebuchetActorID {
        await exposedActors.register(actor, as: name)
    }

    /// Create and expose an actor with a factory closure
    /// - Parameters:
    ///   - name: The name clients will use to resolve this actor
    ///   - factory: A closure that creates the actor instance
    /// - Returns: The created actor instance
    @discardableResult
    public func expose<Act: DistributedActor>(
        _ name: String,
        factory: @Sendable (TrebuchetActorSystem) -> Act
    ) async -> Act where Act.ID == TrebuchetActorID {
        let actor = factory(actorSystem)
        await exposedActors.register(actor, as: name)
        return actor
    }

    /// Configure streaming support for a specific actor type
    /// Multiple calls to this method will register handlers for different types
    /// - Parameter configure: A closure that receives an invocation envelope and actor, and returns a data stream
    public func configureStreaming(_ configure: @escaping @Sendable (InvocationEnvelope, any DistributedActor) async throws -> AsyncStream<Data>) async {
        await streamingHandlers.register(handler: configure)
    }

    /// Configure streaming for actors that conform to a specific protocol
    /// Multiple calls to this method will register handlers for different protocol types
    public func configureStreaming<T>(
        for protocolType: T.Type,
        handler: @escaping @Sendable (InvocationEnvelope, T) async throws -> AsyncStream<Data>
    ) async {
        // Capture the handler in a way that doesn't require sending the metatype
        await streamingHandlers.registerTyped(handler: handler)
    }

    /// Helper to create a streaming data stream from a typed stream
    /// - Parameter stream: A typed async stream to encode
    /// - Returns: An async stream of encoded data
    public static func encodeStream<T: Codable & Sendable>(_ stream: AsyncStream<T>) -> AsyncStream<Data> {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        return AsyncStream { continuation in
            Task {
                for await value in stream {
                    if let data = try? encoder.encode(value) {
                        continuation.yield(data)
                    }
                }
                continuation.finish()
            }
        }
    }

    /// Configure streaming for a single observe method on a protocol
    /// Multiple calls to this method will register handlers for different protocol types
    /// This is a convenience for the common case of one streaming property
    ///
    /// Example:
    /// ```swift
    /// // Register streaming for TodoList
    /// await server.configureStreaming(
    ///     for: TodoListStreaming.self,
    ///     method: "observeState"
    /// ) { await $0.observeState() }
    ///
    /// // Register streaming for GameRoom (doesn't overwrite TodoList!)
    /// await server.configureStreaming(
    ///     for: GameRoomStreaming.self,
    ///     method: "observePlayers"
    /// ) { await $0.observePlayers() }
    /// ```
    public func configureStreaming<T, State: Codable & Sendable>(
        for protocolType: T.Type,
        method: String,
        observe: @escaping @Sendable (T) async -> AsyncStream<State>
    ) async {
        await configureStreaming(for: protocolType) { envelope, actor in
            guard envelope.targetIdentifier == method else {
                throw TrebuchetError.remoteInvocationFailed("Unknown streaming method: \(envelope.targetIdentifier)")
            }
            return Self.encodeStream(await observe(actor))
        }
    }

    /// Configure streaming using a type-safe enum for methods
    /// The enum is auto-generated by @Trebuchet as ActorName.StreamingMethod
    ///
    /// Example:
    /// ```swift
    /// await server.configureStreaming(
    ///     for: TodoListStreaming.self,
    ///     method: TodoList.StreamingMethod.observeState
    /// ) { await $0.observeState() }
    /// ```
    public func configureStreaming<T, Method: RawRepresentable, State: Codable & Sendable>(
        for protocolType: T.Type,
        method: Method,
        observe: @escaping @Sendable (T) async -> AsyncStream<State>
    ) async where Method.RawValue == String {
        await configureStreaming(for: protocolType, method: method.rawValue, observe: observe)
    }

    /// Configure streaming with a type-safe switch over all streaming methods
    ///
    /// Example:
    /// ```swift
    /// await server.configureStreaming(for: GameRoomStreaming.self) { method, room in
    ///     switch method {
    ///     case .observeGameState:
    ///         return await room.observeGameState()
    ///     case .observePlayerList:
    ///         return await room.observePlayerList()
    ///     }
    /// }
    /// ```
    public func configureStreaming<T, Method: RawRepresentable & CaseIterable, State: Codable & Sendable>(
        for protocolType: T.Type,
        handler: @escaping @Sendable (Method, T) async throws -> AsyncStream<State>
    ) async where Method.RawValue == String {
        await configureStreaming(for: protocolType) { envelope, actor in
            // Try to parse the target identifier as an enum case
            guard let method = Method.allCases.first(where: { $0.rawValue == envelope.targetIdentifier }) else {
                throw TrebuchetError.remoteInvocationFailed("Unknown streaming method: \(envelope.targetIdentifier)")
            }
            return Self.encodeStream(try await handler(method, actor))
        }
    }

    /// Get the ID for an exposed actor by name
    /// - Parameter name: The name the actor was exposed as
    /// - Returns: The actor's ID, or nil if not found
    public func actorID(for name: String) async -> TrebuchetActorID? {
        await exposedActors.getID(for: name)
    }

    /// Start the server and begin accepting connections
    ///
    /// This method runs until the server is stopped via `shutdown()`.
    public func run() async throws {
        // Start listening
        try await transport.listen(on: transportConfig.endpoint)

        // Process incoming messages
        for await message in transport.incoming {
            await handleMessage(message)
        }
    }

    /// Stop the server
    public func shutdown() async {
        await transport.shutdown()
    }

    // MARK: - Private

    private func handleMessage(_ message: TransportMessage) async {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        do {
            let envelope = try decoder.decode(TrebuchetEnvelope.self, from: message.data)

            switch envelope {
            case .invocation(var invocationEnvelope):
                // Translate exposed name to real actor ID if needed
                if let realID = await exposedActors.getID(for: invocationEnvelope.actorID.id) {
                    invocationEnvelope = InvocationEnvelope(
                        callID: invocationEnvelope.callID,
                        actorID: realID,
                        targetIdentifier: invocationEnvelope.targetIdentifier,
                        genericSubstitutions: invocationEnvelope.genericSubstitutions,
                        arguments: invocationEnvelope.arguments
                    )
                }

                // Check if this is a streaming method (observe* methods)
                if invocationEnvelope.targetIdentifier.hasPrefix("observe") {
                    await handleStreamingInvocation(invocationEnvelope, respond: message.respond)
                } else {
                    // Regular RPC invocation
                    let response = await actorSystem.handleIncomingInvocation(invocationEnvelope)
                    let responseEnvelope = TrebuchetEnvelope.response(response)
                    let responseData = try encoder.encode(responseEnvelope)
                    try await message.respond(responseData)
                }

            case .streamResume(let resumeEnvelope):
                await handleStreamResume(resumeEnvelope, respond: message.respond)

            case .response, .streamStart, .streamData, .streamEnd, .streamError:
                // Servers shouldn't receive these
                print("Warning: Server received unexpected non-invocation envelope")
            }
        } catch {
            // Try to extract callID from the message for error response
            if let envelope = try? decoder.decode(TrebuchetEnvelope.self, from: message.data),
               case .invocation(let invocation) = envelope {
                let errorResponse = ResponseEnvelope.failure(
                    callID: invocation.callID,
                    error: String(describing: error)
                )
                let responseEnvelope = TrebuchetEnvelope.response(errorResponse)
                if let responseData = try? encoder.encode(responseEnvelope) {
                    try? await message.respond(responseData)
                }
            }
        }
    }

    private func handleStreamingInvocation(_ envelope: InvocationEnvelope, respond: @escaping @Sendable (Data) async throws -> Void) async {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let streamID = UUID()

        do {
            // Send StreamStart envelope
            let streamStart = StreamStartEnvelope(
                streamID: streamID,
                callID: envelope.callID,
                actorID: envelope.actorID,
                targetIdentifier: envelope.targetIdentifier
            )
            let startEnvelope = TrebuchetEnvelope.streamStart(streamStart)
            let startData = try encoder.encode(startEnvelope)
            try await respond(startData)

            // Execute the streaming method through the actor system
            let stream = try await actorSystem.executeStreamingTarget(envelope)

            // Run stream iteration in background task to avoid blocking the message handler
            Task {
                do {
                    var sequenceNumber: UInt64 = 0
                    for try await data in stream {
                        sequenceNumber += 1

                        let dataEnvelope = StreamDataEnvelope(
                            streamID: streamID,
                            sequenceNumber: sequenceNumber,
                            data: data,
                            timestamp: Date()
                        )
                        let envelope = TrebuchetEnvelope.streamData(dataEnvelope)
                        let envelopeData = try encoder.encode(envelope)
                        try await respond(envelopeData)
                    }

                    // Stream completed successfully
                    let endEnvelope = TrebuchetEnvelope.streamEnd(
                        StreamEndEnvelope(streamID: streamID, reason: .completed)
                    )
                    let endData = try encoder.encode(endEnvelope)
                    try await respond(endData)
                } catch {
                    // Send error envelope
                    let errorEnvelope = TrebuchetEnvelope.streamError(
                        StreamErrorEnvelope(
                            streamID: streamID,
                            errorMessage: "Stream error: \(error.localizedDescription)"
                        )
                    )
                    if let errorData = try? encoder.encode(errorEnvelope) {
                        try? await respond(errorData)
                    }
                }
            }

        } catch {
            // Send error envelope
            let errorEnvelope = TrebuchetEnvelope.streamError(
                StreamErrorEnvelope(
                    streamID: streamID,
                    errorMessage: "Stream setup error: \(error.localizedDescription)"
                )
            )
            if let errorData = try? encoder.encode(errorEnvelope) {
                try? await respond(errorData)
            }
        }
    }

    private func handleStreamResume(_ envelope: StreamResumeEnvelope, respond: @escaping @Sendable (Data) async throws -> Void) async {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        // Check if we have buffered data for this stream
        if let bufferedData = await actorSystem.streamRegistry.resumeStream(
            streamID: envelope.streamID,
            lastSequence: envelope.lastSequence
        ), !bufferedData.isEmpty {
            // Replay buffered data
            do {
                for (sequence, data) in bufferedData {
                    let dataEnvelope = StreamDataEnvelope(
                        streamID: envelope.streamID,
                        sequenceNumber: sequence,
                        data: data,
                        timestamp: Date()
                    )
                    let envelopeData = try encoder.encode(TrebuchetEnvelope.streamData(dataEnvelope))
                    try await respond(envelopeData)
                }
            } catch {
                print("Error replaying buffered data: \(error)")
            }
        } else {
            // Buffer expired or stream not found - restart stream
            // Convert resume envelope to invocation envelope
            let invocation = InvocationEnvelope(
                callID: UUID(),
                actorID: envelope.actorID,
                targetIdentifier: envelope.targetIdentifier,
                genericSubstitutions: [],
                arguments: []
            )

            // Restart the stream
            await handleStreamingInvocation(invocation, respond: respond)
        }
    }
}

// MARK: - Exposed Actor Registry

private actor ExposedActorRegistry {
    private var actors: [String: TrebuchetActorID] = [:]

    func register(_ actor: some DistributedActor, as name: String) {
        guard let id = actor.id as? TrebuchetActorID else { return }
        actors[name] = id
    }

    func getID(for name: String) -> TrebuchetActorID? {
        actors[name]
    }
}

// MARK: - Streaming Handler Registry

/// Registry for managing multiple streaming handlers for different actor types
private actor StreamingHandlerRegistry {
    private var handlers: [@Sendable (InvocationEnvelope, any DistributedActor) async throws -> AsyncStream<Data>?] = []

    /// Register a general streaming handler
    func register(handler: @escaping @Sendable (InvocationEnvelope, any DistributedActor) async throws -> AsyncStream<Data>) {
        handlers.append { envelope, actor in
            try? await handler(envelope, actor)
        }
    }

    /// Register a type-specific streaming handler
    /// The type checking happens within the closure, avoiding metatype transfer
    func registerTyped<T>(handler: @escaping @Sendable (InvocationEnvelope, T) async throws -> AsyncStream<Data>) {
        handlers.append { envelope, actor in
            guard let typedActor = actor as? T else {
                return nil
            }
            return try? await handler(envelope, typedActor)
        }
    }

    /// Handle a streaming invocation by trying each registered handler
    func handle(envelope: InvocationEnvelope, actor: any DistributedActor) async throws -> AsyncStream<Data> {
        // Try each handler in order until one succeeds
        for handler in handlers {
            if let stream = try await handler(envelope, actor) {
                return stream
            }
        }

        // No handler could handle this actor/method combination
        throw TrebuchetError.remoteInvocationFailed(
            "No streaming handler registered for actor type '\(type(of: actor))' and method '\(envelope.targetIdentifier)'"
        )
    }
}
