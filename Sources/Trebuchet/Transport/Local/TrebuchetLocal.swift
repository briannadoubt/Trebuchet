import Distributed
import Foundation

/// A unified server and client for in-process distributed actors.
///
/// `TrebuchetLocal` provides a simplified API for working with distributed actors
/// in a single process. It combines the functionality of `TrebuchetServer` and
/// `TrebuchetClient` without requiring network configuration, making it ideal for:
///
/// - **Testing**: Write tests for distributed actor systems without network setup
/// - **Playgrounds**: Experiment with distributed actors interactively
/// - **Single-process apps**: Use location transparency within one process
/// - **Development**: Rapid prototyping and debugging
///
/// ## Basic Usage
///
/// ```swift
/// @Trebuchet
/// distributed actor Counter {
///     var count = 0
///
///     distributed func increment() -> Int {
///         count += 1
///         return count
///     }
/// }
///
/// // Create local instance
/// let local = await TrebuchetLocal()
///
/// // Expose an actor
/// let counter = Counter(actorSystem: local.actorSystem)
/// await local.expose(counter, as: "counter")
///
/// // Resolve and call the actor (even in the same process!)
/// let resolved = try local.resolve(Counter.self, id: "counter")
/// let count = try await resolved.increment()  // Returns 1
/// ```
///
/// ## Streaming Support
///
/// Configure streaming for actors with `@StreamedState` properties:
///
/// ```swift
/// @Trebuchet
/// distributed actor GameRoom {
///     @StreamedState var players: [Player] = []
///
///     distributed func addPlayer(_ player: Player) {
///         players.append(player)
///     }
///
///     distributed func observePlayers() -> AsyncStream<[Player]>
/// }
///
/// let local = await TrebuchetLocal()
///
/// // Configure streaming
/// await local.configureStreaming(
///     for: GameRoomStreaming.self,
///     method: "observePlayers"
/// ) { await $0.observePlayers() }
///
/// // Expose and resolve
/// let room = GameRoom(actorSystem: local.actorSystem)
/// await local.expose(room, as: "main-room")
///
/// let resolved = try local.resolve(GameRoom.self, id: "main-room")
///
/// // Subscribe to streaming updates
/// for await players in try await resolved.observePlayers() {
///     print("Players: \(players)")
/// }
/// ```
///
/// ## Type-Safe Streaming with Enums
///
/// Use the auto-generated `StreamingMethod` enum for type safety:
///
/// ```swift
/// await local.configureStreaming(
///     for: GameRoomStreaming.self,
///     method: GameRoom.StreamingMethod.observePlayers
/// ) { await $0.observePlayers() }
/// ```
///
/// ## Multiple Streaming Methods
///
/// Configure multiple streaming methods with a switch statement:
///
/// ```swift
/// await local.configureStreaming(for: GameRoomStreaming.self) { method, room in
///     switch method {
///     case .observePlayers:
///         return await room.observePlayers()
///     case .observeGameState:
///         return await room.observeGameState()
///     }
/// }
/// ```
///
/// ## Factory Pattern
///
/// Create and expose actors in one call:
///
/// ```swift
/// let counter = await local.expose("counter") { actorSystem in
///     Counter(actorSystem: actorSystem)
/// }
/// ```
///
/// ## Testing Example
///
/// Perfect for unit tests:
///
/// ```swift
/// @Test
/// func testDistributedCounter() async throws {
///     let local = await TrebuchetLocal()
///
///     // Expose actor
///     let counter = Counter(actorSystem: local.actorSystem)
///     await local.expose(counter, as: "test-counter")
///
///     // Resolve and test
///     let resolved = try local.resolve(Counter.self, id: "test-counter")
///     let result = try await resolved.increment()
///
///     #expect(result == 1)
/// }
/// ```
///
/// ## SwiftUI Integration
///
/// While primarily for testing, you can use `TrebuchetLocal` in SwiftUI:
///
/// ```swift
/// @Observable
/// final class GameModel {
///     let local: TrebuchetLocal
///     var room: GameRoom?
///
///     init() async {
///         local = await TrebuchetLocal()
///         let room = GameRoom(actorSystem: local.actorSystem)
///         await local.expose(room, as: "main-room")
///         self.room = try? local.resolve(GameRoom.self, id: "main-room")
///     }
/// }
/// ```
///
/// ## Thread Safety
///
/// `TrebuchetLocal` uses internal actors for thread-safe access to the actor
/// registry and streaming configuration. All public methods are safe to call
/// from any context.
///
/// - Note: For production networked applications, use `TrebuchetServer` and
///   `TrebuchetClient` instead. `TrebuchetLocal` is optimized for in-process
///   communication only.
public final class TrebuchetLocal: Sendable {
    /// The actor system used by this instance
    public let actorSystem: TrebuchetRuntime

    /// The underlying transport (isolated per TrebuchetLocal instance)
    private let transport: LocalTransport

    /// Registry of exposed actors by name
    private let exposedActors = ExposedActorRegistry()

    /// Registry of streaming handlers by type
    private let streamingHandlers = StreamingHandlerRegistry()

    /// Task handling incoming messages
    private let messageHandlerTask: Task<Void, Never>

    /// Create a new local instance
    ///
    /// This creates a unified server and client that communicate in-process
    /// using an isolated in-process local transport.
    public init() async {
        self.transport = LocalTransport.isolated()
        self.actorSystem = TrebuchetRuntime()

        // Configure the actor system with local transport
        actorSystem.configure(
            transport: transport,
            host: "local",
            port: 0
        )

        // Set up the streaming handler
        let handlers = streamingHandlers
        actorSystem.streamingHandler = { envelope, actor in
            try await handlers.handle(envelope: envelope, actor: actor)
        }

        // Set up name-to-ID translator
        let exposed = exposedActors
        actorSystem.nameToIDTranslator = { name in
            await exposed.getID(for: name)
        }

        // Start listening for messages
        try? await transport.listen(on: Endpoint(host: "local", port: 0))

        // Process incoming messages
        // Capture dependencies to avoid self-before-init error
        let actorSystem = self.actorSystem
        let exposedActors = self.exposedActors
        let transport = self.transport

        self.messageHandlerTask = Task { [weak actorSystem, weak exposedActors, weak transport] in
            guard let actorSystem, let exposedActors, let transport else { return }

            for await message in transport.incoming {
                await Self.handleMessageStatic(
                    message,
                    actorSystem: actorSystem,
                    exposedActors: exposedActors
                )
            }
        }
    }

    deinit {
        messageHandlerTask.cancel()
    }

    /// Stops local message handling for this instance.
    ///
    /// Call this in tests to ensure deterministic cleanup between cases.
    public func shutdown() async {
        messageHandlerTask.cancel()
        await transport.shutdown()
    }

    /// Expose an actor with a given name so it can be resolved
    ///
    /// - Parameters:
    ///   - actor: The distributed actor to expose
    ///   - name: The name used to resolve this actor
    ///
    /// Example:
    /// ```swift
    /// let counter = Counter(actorSystem: local.actorSystem)
    /// await local.expose(counter, as: "counter")
    /// ```
    public func expose<Act: DistributedActor>(_ actor: Act, as name: String) async where Act.ID == TrebuchetActorID {
        await exposedActors.register(actor, as: name)
    }

    /// Create and expose an actor with a factory closure
    ///
    /// - Parameters:
    ///   - name: The name used to resolve this actor
    ///   - factory: A closure that creates the actor instance
    /// - Returns: The created actor instance
    ///
    /// Example:
    /// ```swift
    /// let counter = await local.expose("counter") { actorSystem in
    ///     Counter(actorSystem: actorSystem)
    /// }
    /// ```
    @discardableResult
    public func expose<Act: DistributedActor>(
        _ name: String,
        factory: @Sendable (TrebuchetRuntime) -> Act
    ) async -> Act where Act.ID == TrebuchetActorID {
        let actor = factory(actorSystem)
        await exposedActors.register(actor, as: name)
        return actor
    }

    /// Resolve a remote actor by its ID
    ///
    /// - Parameters:
    ///   - actorType: The type of the distributed actor
    ///   - id: The actor's ID string (as exposed with `expose(_:as:)`)
    /// - Returns: A proxy to the actor
    ///
    /// Example:
    /// ```swift
    /// let counter = try local.resolve(Counter.self, id: "counter")
    /// let count = try await counter.increment()
    /// ```
    public func resolve<Act: DistributedActor>(
        _ actorType: Act.Type,
        id: String
    ) throws -> Act where Act.ID == TrebuchetActorID, Act.ActorSystem == TrebuchetRuntime {
        // Use a routable local endpoint so invocation flows through LocalTransport,
        // where exposed-name translation maps "id" -> actual actor ID.
        let actorID = TrebuchetActorID(id: id, host: "local", port: 0)
        return try Act.resolve(id: actorID, using: actorSystem)
    }

    /// Get the ID for an exposed actor by name
    ///
    /// - Parameter name: The name the actor was exposed as
    /// - Returns: The actor's ID, or nil if not found
    public func actorID(for name: String) async -> TrebuchetActorID? {
        await exposedActors.getID(for: name)
    }

    // MARK: - Streaming Configuration

    /// Configure streaming support for a specific actor type
    ///
    /// Multiple calls to this method will register handlers for different types.
    ///
    /// - Parameter configure: A closure that receives an invocation envelope and actor, and returns a data stream
    ///
    /// Example:
    /// ```swift
    /// await local.configureStreaming { envelope, actor in
    ///     guard let room = actor as? GameRoom else {
    ///         throw TrebuchetError.remoteInvocationFailed("Wrong actor type")
    ///     }
    ///     let stream = await room.observePlayers()
    ///     return TrebuchetLocal.encodeStream(stream)
    /// }
    /// ```
    public func configureStreaming(_ configure: @escaping @Sendable (InvocationEnvelope, any DistributedActor) async throws -> AsyncStream<Data>) async {
        await streamingHandlers.register(handler: configure)
    }

    /// Configure streaming for actors that conform to a specific protocol
    ///
    /// Multiple calls to this method will register handlers for different protocol types.
    ///
    /// - Parameters:
    ///   - protocolType: The protocol type that actors must conform to
    ///   - handler: A closure that receives an invocation envelope and typed actor, and returns a data stream
    ///
    /// Example:
    /// ```swift
    /// await local.configureStreaming(for: GameRoomStreaming.self) { envelope, room in
    ///     let stream = await room.observePlayers()
    ///     return TrebuchetLocal.encodeStream(stream)
    /// }
    /// ```
    public func configureStreaming<T>(
        for protocolType: T.Type,
        handler: @escaping @Sendable (InvocationEnvelope, T) async throws -> AsyncStream<Data>
    ) async {
        await streamingHandlers.registerTyped(handler: handler)
    }

    /// Configure streaming for a single observe method on a protocol
    ///
    /// This is a convenience for the common case of one streaming property.
    ///
    /// - Parameters:
    ///   - protocolType: The protocol type that actors must conform to
    ///   - method: The name of the streaming method (e.g., "observeState")
    ///   - observe: A closure that receives the typed actor and returns a typed stream
    ///
    /// Example:
    /// ```swift
    /// await local.configureStreaming(
    ///     for: GameRoomStreaming.self,
    ///     method: "observePlayers"
    /// ) { await $0.observePlayers() }
    /// ```
    public func configureStreaming<T, State: Codable & Sendable>(
        for protocolType: T.Type,
        method: String,
        observe: @escaping @Sendable (T) async -> AsyncStream<State>
    ) async {
        await streamingHandlers.registerTypedWithMethod(method: method) { envelope, actor in
            let stream = await observe(actor)
            return Self.encodeStream(stream)
        }
    }

    /// Configure streaming using a type-safe enum for methods
    ///
    /// The enum is auto-generated by `@Trebuchet` as `ActorName.StreamingMethod`.
    ///
    /// - Parameters:
    ///   - protocolType: The protocol type that actors must conform to
    ///   - method: The streaming method enum case
    ///   - observe: A closure that receives the typed actor and returns a typed stream
    ///
    /// Example:
    /// ```swift
    /// await local.configureStreaming(
    ///     for: GameRoomStreaming.self,
    ///     method: GameRoom.StreamingMethod.observePlayers
    /// ) { await $0.observePlayers() }
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
    /// This approach ensures exhaustive handling of all streaming methods at compile time.
    ///
    /// - Parameters:
    ///   - protocolType: The protocol type that actors must conform to
    ///   - handler: A closure that receives a method enum and typed actor, and returns a typed stream
    ///
    /// Example:
    /// ```swift
    /// await local.configureStreaming(for: GameRoomStreaming.self) { method, room in
    ///     switch method {
    ///     case .observePlayers:
    ///         return await room.observePlayers()
    ///     case .observeGameState:
    ///         return await room.observeGameState()
    ///     }
    /// }
    /// ```
    public func configureStreaming<T, Method, State: Codable & Sendable>(
        for protocolType: T.Type,
        handler: @escaping @Sendable (Method, T) async throws -> AsyncStream<State>
    ) async where Method: RawRepresentable & CaseIterable & Sendable, Method.RawValue == String {
        // Capture all cases outside the closure to avoid Sendable warnings
        let allCases = Array(Method.allCases)

        await configureStreaming(for: protocolType) { envelope, actor in
            // Try to parse the target identifier as an enum case
            guard let method = allCases.first(where: { $0.rawValue == envelope.targetIdentifier }) else {
                throw TrebuchetError.remoteInvocationFailed("Unknown streaming method: \(envelope.targetIdentifier)")
            }
            return Self.encodeStream(try await handler(method, actor))
        }
    }

    /// Helper to create a streaming data stream from a typed stream
    ///
    /// - Parameter stream: A typed async stream to encode
    /// - Returns: An async stream of encoded data
    ///
    /// Example:
    /// ```swift
    /// let typedStream: AsyncStream<Player> = ...
    /// let dataStream = TrebuchetLocal.encodeStream(typedStream)
    /// ```
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

    // MARK: - Private

    private static func handleMessageStatic(
        _ message: TransportMessage,
        actorSystem: TrebuchetRuntime,
        exposedActors: ExposedActorRegistry
    ) async {
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
                        protocolVersion: invocationEnvelope.protocolVersion,
                        genericSubstitutions: invocationEnvelope.genericSubstitutions,
                        arguments: invocationEnvelope.arguments,
                        streamFilter: invocationEnvelope.streamFilter,
                        traceContext: invocationEnvelope.traceContext
                    )
                }

                // Check if this is a streaming method
                if invocationEnvelope.targetIdentifier.hasPrefix("observe") {
                    await Self.handleStreamingInvocation(
                        invocationEnvelope,
                        actorSystem: actorSystem,
                        respond: message.respond
                    )
                } else {
                    // Regular RPC invocation
                    let response = await actorSystem.handleIncomingInvocation(invocationEnvelope)
                    let responseEnvelope = TrebuchetEnvelope.response(response)
                    let responseData = try encoder.encode(responseEnvelope)
                    try await message.respond(responseData)
                }

            case .response(let response):
                // Handle response from remote actor
                actorSystem.completePendingCall(response: response)

            case .streamStart(let streamStart):
                await actorSystem.handleStreamStart(streamStart)

            case .streamData(let streamData):
                await actorSystem.handleStreamData(streamData)

            case .streamEnd(let streamEnd):
                await actorSystem.handleStreamEnd(streamEnd)

            case .streamError(let streamError):
                await actorSystem.handleStreamError(streamError)

            case .streamResume:
                // Stream resume not supported in local transport
                break
            }
        } catch {
            // Send error response for decoding failures
            let errorResponse = ResponseEnvelope(
                callID: UUID(),
                result: nil,
                errorMessage: "Failed to decode message: \(error.localizedDescription)"
            )
            let errorEnvelope = TrebuchetEnvelope.response(errorResponse)
            if let errorData = try? encoder.encode(errorEnvelope) {
                try? await message.respond(errorData)
            }
        }
    }

    private static func handleStreamingInvocation(
        _ envelope: InvocationEnvelope,
        actorSystem: TrebuchetRuntime,
        respond: @escaping @Sendable (Data) async throws -> Void
    ) async {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let streamID = UUID()

        do {
            // Send StreamStart envelope
            let streamStart = StreamStartEnvelope(
                streamID: streamID,
                callID: envelope.callID,
                actorID: envelope.actorID,
                targetIdentifier: envelope.targetIdentifier,
                filter: envelope.streamFilter
            )
            let startEnvelope = TrebuchetEnvelope.streamStart(streamStart)
            let startData = try encoder.encode(startEnvelope)
            try await respond(startData)

            // Execute the streaming method
            let stream = try await actorSystem.executeStreamingTarget(envelope)

            // Stream data in background
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

private actor StreamingHandlerRegistry {
    private var handlers: [@Sendable (InvocationEnvelope, any DistributedActor) async throws -> AsyncStream<Data>?] = []

    func register(handler: @escaping @Sendable (InvocationEnvelope, any DistributedActor) async throws -> AsyncStream<Data>) {
        handlers.append { envelope, actor in
            try await handler(envelope, actor)
        }
    }

    func registerTyped<T>(handler: @escaping @Sendable (InvocationEnvelope, T) async throws -> AsyncStream<Data>) {
        handlers.append { envelope, actor in
            guard let typedActor = actor as? T else {
                return nil
            }
            return try await handler(envelope, typedActor)
        }
    }

    func registerTypedWithMethod<T>(
        method: String,
        handler: @escaping @Sendable (InvocationEnvelope, T) async throws -> AsyncStream<Data>
    ) {
        handlers.append { envelope, actor in
            // Check type first
            guard let typedActor = actor as? T else {
                return nil
            }

            // Check method name
            guard envelope.targetIdentifier == method else {
                return nil
            }

            return try await handler(envelope, typedActor)
        }
    }

    func handle(envelope: InvocationEnvelope, actor: any DistributedActor) async throws -> AsyncStream<Data> {
        // Try each handler in order until one succeeds
        for handler in handlers {
            do {
                if let stream = try await handler(envelope, actor) {
                    return stream
                }
                // nil means type mismatch, continue to next handler
            } catch {
                // Handler matched but threw an error - propagate it immediately
                throw error
            }
        }

        // No handler could handle this actor/method combination
        throw TrebuchetError.remoteInvocationFailed(
            "No streaming handler registered for actor type '\(type(of: actor))' and method '\(envelope.targetIdentifier)'"
        )
    }
}
