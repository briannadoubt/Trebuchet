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
    }

    /// Expose an actor with a given name so clients can resolve it
    /// - Parameters:
    ///   - actor: The distributed actor to expose
    ///   - name: The name clients will use to resolve this actor
    public func expose<Act: DistributedActor>(_ actor: Act, as name: String) async where Act.ID == TrebuchetActorID {
        await exposedActors.register(actor, as: name)
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
            var envelope = try decoder.decode(InvocationEnvelope.self, from: message.data)

            // Translate exposed name to real actor ID if needed
            if let realID = await exposedActors.getID(for: envelope.actorID.id) {
                envelope = InvocationEnvelope(
                    callID: envelope.callID,
                    actorID: realID,
                    targetIdentifier: envelope.targetIdentifier,
                    genericSubstitutions: envelope.genericSubstitutions,
                    arguments: envelope.arguments
                )
            }

            let response = await actorSystem.handleIncomingInvocation(envelope)
            let responseData = try encoder.encode(response)
            try await message.respond(responseData)
        } catch {
            // Try to extract callID from the message for error response
            if let envelope = try? decoder.decode(InvocationEnvelope.self, from: message.data) {
                let errorResponse = ResponseEnvelope.failure(
                    callID: envelope.callID,
                    error: String(describing: error)
                )
                if let responseData = try? encoder.encode(errorResponse) {
                    try? await message.respond(responseData)
                }
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
