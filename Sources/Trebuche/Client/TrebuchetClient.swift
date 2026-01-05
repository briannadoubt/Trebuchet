import Distributed
import Foundation

/// A client that connects to a Trebuchet server and resolves remote actors.
///
/// Example usage:
/// ```swift
/// let client = TrebuchetClient(transport: .webSocket(host: "localhost", port: 8080))
/// try await client.connect()
/// let room = try client.resolve(GameRoom.self, id: "main-room")
/// try await room.join(player: me)
/// ```
public final class TrebuchetClient: Sendable {
    /// The actor system used by this client
    public let actorSystem: TrebuchetActorSystem

    /// The transport configuration
    private let transportConfig: TransportConfiguration

    /// The transport layer
    private let transport: any TrebuchetTransport

    /// The server endpoint we're connecting to
    private let serverEndpoint: Endpoint

    /// JSON decoder
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Create a new client with the specified transport
    /// - Parameter transport: The transport configuration (e.g., `.webSocket(host: "localhost", port: 8080)`)
    public init(transport: TransportConfiguration) {
        self.transportConfig = transport
        self.serverEndpoint = transport.endpoint
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

    /// Connect to the server
    ///
    /// This establishes the underlying transport connection and starts
    /// processing incoming responses.
    public func connect() async throws {
        // Start processing incoming responses in the background
        Task {
            for await message in transport.incoming {
                await handleResponse(message)
            }
        }
    }

    /// Resolve a remote actor by its ID
    ///
    /// - Parameters:
    ///   - actorType: The type of the distributed actor
    ///   - id: The actor's ID string (as exposed by the server)
    /// - Returns: A proxy to the remote actor
    public func resolve<Act: DistributedActor>(
        _ actorType: Act.Type,
        id: String
    ) throws -> Act where Act.ID == TrebuchetActorID, Act.ActorSystem == TrebuchetActorSystem {
        let actorID = TrebuchetActorID(
            id: id,
            host: serverEndpoint.host,
            port: serverEndpoint.port
        )

        return try Act.resolve(id: actorID, using: actorSystem)
    }

    /// Disconnect from the server
    public func disconnect() async {
        await transport.shutdown()
    }

    // MARK: - Private

    private func handleResponse(_ message: TransportMessage) async {
        do {
            let response = try decoder.decode(ResponseEnvelope.self, from: message.data)
            actorSystem.completePendingCall(response: response)
        } catch {
            // Log error but don't crash
            print("Failed to decode response: \(error)")
        }
    }
}
