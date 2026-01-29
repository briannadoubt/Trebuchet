import Distributed
import Foundation

/// Server state for graceful shutdown
public enum ServerState: Sendable {
    /// Server is running and accepting new requests
    case running

    /// Server is draining existing requests but rejecting new ones
    case draining

    /// Server is fully stopped
    case stopped
}

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

    /// Buffer for outgoing stream data (for resumption support)
    private let streamBuffer = ServerStreamBuffer()

    /// Filter state for stateful filters (like "changed")
    private let filterState = StreamFilterState()

    /// Tracker for in-flight requests
    private let inflightTracker = InflightRequestTracker()

    /// Current server state
    private let serverState = ServerStateManager()

    /// When the server started
    private let startTime = ContinuousClock.Instant.now

    /// Create a new server with the specified transport
    /// - Parameter transport: The transport configuration (e.g., `.webSocket(port: 8080)`)
    public init(transport: TransportConfiguration) {
        self.transportConfig = transport
        self.actorSystem = TrebuchetActorSystem()

        switch transport {
        case .webSocket(_, _, let tls):
            self.transport = WebSocketTransport(tlsConfiguration: tls)
        case .tcp:
            self.transport = TCPTransport()
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

    /// Get the ID for an exposed actor by name
    /// - Parameter name: The name the actor was exposed as
    /// - Returns: The actor's ID, or nil if not found
    public func actorID(for name: String) async -> TrebuchetActorID? {
        await exposedActors.getID(for: name)
    }

    /// Start the server and begin accepting connections
    ///
    /// This method runs until the server is stopped via `shutdown()` or `gracefulShutdown()`.
    public func run() async throws {
        // Set state to running
        await serverState.setState(.running)

        // Start listening
        try await transport.listen(on: transportConfig.endpoint)

        // Process incoming messages
        for await message in transport.incoming {
            // Check if we should accept new requests
            let state = await serverState.getState()
            guard state == .running else {
                // Reject during draining with helpful error
                await rejectRequest(message, reason: "Server is shutting down")
                continue
            }

            await handleMessage(message)
        }
    }

    /// Stop the server immediately
    ///
    /// This method stops the server immediately without waiting for in-flight requests.
    /// For production deployments, prefer `gracefulShutdown()`.
    public func shutdown() async {
        await serverState.setState(.stopped)

        // Clean up all active streams
        await actorSystem.streamRegistry.removeAllStreams()

        // Clean up all stream buffers
        await streamBuffer.removeAllBuffers()

        // Clean up filter state
        await filterState.clearAllState()

        // Cancel all in-flight requests
        await inflightTracker.cancelAll()

        // Shutdown transport
        await transport.shutdown()
    }

    /// Gracefully shutdown the server
    ///
    /// This method:
    /// 1. Stops accepting new requests (enters draining state)
    /// 2. Waits for in-flight requests to complete (up to timeout)
    /// 3. Cancels remaining requests after timeout
    /// 4. Cleans up resources and shuts down transport
    ///
    /// - Parameter timeout: Maximum time to wait for requests to complete (default: 30 seconds)
    public func gracefulShutdown(timeout: Duration = .seconds(30)) async {
        // Phase 1: Stop accepting new requests
        await serverState.setState(.draining)

        // Phase 2: Wait for in-flight requests to complete
        let deadline = ContinuousClock.now + timeout
        while await inflightTracker.count() > 0 {
            if ContinuousClock.now >= deadline {
                break
            }

            // Check every 100ms
            try? await Task.sleep(for: .milliseconds(100))
        }

        // Phase 3: Force cleanup
        await inflightTracker.cancelAll()
        await actorSystem.streamRegistry.removeAllStreams()
        await streamBuffer.removeAllBuffers()
        await filterState.clearAllState()

        // Phase 4: Shutdown transport
        await serverState.setState(.stopped)
        await transport.shutdown()
    }

    /// Get the current server state
    /// - Returns: The current server state
    public func getState() async -> ServerState {
        await serverState.getState()
    }

    /// Get health status for load balancer checks
    /// - Returns: Health status including server state and metrics
    public func healthStatus() async -> HealthStatus {
        let state = await serverState.getState()
        let inflightCount = await inflightTracker.count()
        let activeStreams = await actorSystem.streamRegistry.activeStreamCount()

        let statusString: String
        switch state {
        case .running:
            statusString = "healthy"
        case .draining:
            statusString = "draining"
        case .stopped:
            statusString = "unhealthy"
        }

        return HealthStatus(
            status: statusString,
            timestamp: Date(),
            inflightRequests: inflightCount,
            activeStreams: activeStreams,
            uptime: ContinuousClock.now - startTime
        )
    }

    // MARK: - Private

    private func rejectRequest(_ message: TransportMessage, reason: String) async {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        // Try to parse the message to get callID
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let envelope = try? decoder.decode(TrebuchetEnvelope.self, from: message.data),
           case .invocation(let invocation) = envelope {
            let errorResponse = ResponseEnvelope.failure(
                callID: invocation.callID,
                error: reason
            )
            let responseEnvelope = TrebuchetEnvelope.response(errorResponse)
            if let responseData = try? encoder.encode(responseEnvelope) {
                try? await message.respond(responseData)
            }
        }
    }

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
                    // Track the request
                    await inflightTracker.begin(
                        callID: invocationEnvelope.callID,
                        actorID: invocationEnvelope.actorID.id,
                        method: invocationEnvelope.targetIdentifier
                    )

                    let response = await actorSystem.handleIncomingInvocation(invocationEnvelope)

                    // Mark as complete
                    await inflightTracker.complete(callID: invocationEnvelope.callID)

                    let responseEnvelope = TrebuchetEnvelope.response(response)
                    let responseData = try encoder.encode(responseEnvelope)
                    try await message.respond(responseData)
                }

            case .streamResume(let resumeEnvelope):
                await handleStreamResume(resumeEnvelope, respond: message.respond)

            case .response, .streamStart, .streamData, .streamEnd, .streamError:
                // Servers shouldn't receive these - silently ignore
                break
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
                targetIdentifier: envelope.targetIdentifier,
                filter: envelope.streamFilter
            )
            let startEnvelope = TrebuchetEnvelope.streamStart(streamStart)
            let startData = try encoder.encode(startEnvelope)
            try await respond(startData)

            // Execute the streaming method through the actor system
            let stream = try await actorSystem.executeStreamingTarget(envelope)

            // Run stream iteration in background task to avoid blocking the message handler
            let buffer = streamBuffer
            let filterStateManager = filterState
            let filter = envelope.streamFilter
            Task {
                do {
                    var sequenceNumber: UInt64 = 0
                    for try await data in stream {
                        // Apply filter before sending (if specified)
                        if let filter = filter {
                            let passes = await filterStateManager.matches(filter, data: data, streamID: streamID)
                            if !passes {
                                continue  // Skip this update
                            }
                        }

                        sequenceNumber += 1

                        // Buffer the data for potential resumption
                        await buffer.buffer(streamID: streamID, sequence: sequenceNumber, data: data)

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

                    // Clean up buffer and filter state
                    await buffer.removeBuffer(streamID: streamID)
                    await filterStateManager.clearState(for: streamID)
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

                    // Clean up buffer and filter state on error
                    await buffer.removeBuffer(streamID: streamID)
                    await filterStateManager.clearState(for: streamID)
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
        if let bufferedData = await streamBuffer.getBufferedData(
            streamID: envelope.streamID,
            afterSequence: envelope.lastSequence
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
                // Silently ignore replay errors - stream will restart
                return
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
            try await handler(envelope, actor)
        }
    }

    /// Register a type-specific streaming handler
    /// The type checking happens within the closure, avoiding metatype transfer
    func registerTyped<T>(handler: @escaping @Sendable (InvocationEnvelope, T) async throws -> AsyncStream<Data>) {
        handlers.append { envelope, actor in
            guard let typedActor = actor as? T else {
                return nil
            }
            return try await handler(envelope, typedActor)
        }
    }

    /// Handle a streaming invocation by trying each registered handler
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

// MARK: - Server Stream Buffer

/// Buffer for outgoing stream data to support resumption after connection loss.
///
/// When clients disconnect and reconnect, this buffer allows them to resume streams
/// without missing updates. The buffer operates as a sliding window, keeping only
/// the most recent updates.
///
/// ## Buffer Sizing
///
/// The default buffer size of **100 items** is chosen to balance memory usage
/// with practical reconnection scenarios:
///
/// - **Memory**: ~10KB per buffer (assuming 100 bytes per item average)
/// - **Time coverage**: ~10 seconds at 10 updates/sec, ~100 seconds at 1 update/sec
/// - **Typical use**: Handles brief disconnections (network blips, app backgrounding)
///
/// ## Tuning Guidelines
///
/// Adjust `maxBufferSize` based on your update frequency and expected disconnection duration:
///
/// | Update Rate | Disconnection | Buffer Size | Memory |
/// |-------------|---------------|-------------|--------|
/// | 1/sec | 1 minute | 60 | ~6KB |
/// | 10/sec | 10 seconds | 100 (default) | ~10KB |
/// | 100/sec | 1 second | 100 | ~10KB |
/// | 1/sec | 10 minutes | 600 | ~60KB |
///
/// - **Low-frequency updates**: Increase buffer size for longer coverage
/// - **High-frequency updates**: Keep default or lower if reconnections are quick
/// - **Mobile apps**: Consider 200-300 for backgrounding scenarios
/// - **Memory-constrained**: Reduce to 50 for minimal footprint
///
/// ## TTL (Time-to-Live)
///
/// The default TTL of **300 seconds (5 minutes)** determines how long buffers persist
/// after the last activity. After TTL expires, reconnecting clients receive a fresh
/// stream start instead of buffered data.
///
/// - Short TTL (60s): Fast cleanup, less memory, requires quick reconnection
/// - Long TTL (600s): Better reconnection window, more memory held
private actor ServerStreamBuffer {
    private struct BufferedStream {
        var recentData: [(sequence: UInt64, data: Data)] = []
        var lastActivity: Date = Date()
    }

    private var buffers: [UUID: BufferedStream] = [:]
    private let maxBufferSize: Int
    private let ttl: TimeInterval

    /// Initialize stream buffer
    ///
    /// - Parameters:
    ///   - maxBufferSize: Maximum items to buffer per stream (default: 100)
    ///   - ttl: Time-to-live for buffers in seconds (default: 300 = 5 minutes)
    init(maxBufferSize: Int = 100, ttl: TimeInterval = 300) {
        self.maxBufferSize = maxBufferSize
        self.ttl = ttl
    }

    /// Buffer outgoing stream data
    func buffer(streamID: UUID, sequence: UInt64, data: Data) {
        var stream = buffers[streamID] ?? BufferedStream()
        stream.recentData.append((sequence, data))
        stream.lastActivity = Date()

        // Keep only recent items
        if stream.recentData.count > maxBufferSize {
            stream.recentData.removeFirst()
        }

        buffers[streamID] = stream
    }

    /// Get buffered data for resumption
    func getBufferedData(streamID: UUID, afterSequence: UInt64) -> [(sequence: UInt64, data: Data)]? {
        guard let stream = buffers[streamID] else {
            return nil
        }

        // Check if buffer is still valid (not expired)
        if Date().timeIntervalSince(stream.lastActivity) > ttl {
            buffers.removeValue(forKey: streamID)
            return nil
        }

        // Return data after the given sequence
        return stream.recentData.filter { $0.sequence > afterSequence }
    }

    /// Remove buffer for a completed stream
    func removeBuffer(streamID: UUID) {
        buffers.removeValue(forKey: streamID)
    }

    /// Clean up all buffers
    func removeAllBuffers() {
        buffers.removeAll()
    }
}

// MARK: - Server State Manager

/// Actor for managing server state safely
private actor ServerStateManager {
    private var state: ServerState = .stopped

    func setState(_ newState: ServerState) {
        state = newState
    }

    func getState() -> ServerState {
        state
    }
}

// MARK: - Health Status

/// Health status for load balancer checks
public struct HealthStatus: Codable, Sendable {
    /// Status string: "healthy", "draining", or "unhealthy"
    public let status: String

    /// Timestamp when status was checked
    public let timestamp: Date

    /// Number of in-flight requests
    public let inflightRequests: Int

    /// Number of active streams
    public let activeStreams: Int

    /// Server uptime
    public let uptime: Duration

    public var isHealthy: Bool {
        status == "healthy"
    }

    public init(
        status: String,
        timestamp: Date,
        inflightRequests: Int,
        activeStreams: Int,
        uptime: Duration
    ) {
        self.status = status
        self.timestamp = timestamp
        self.inflightRequests = inflightRequests
        self.activeStreams = activeStreams
        self.uptime = uptime
    }
}
