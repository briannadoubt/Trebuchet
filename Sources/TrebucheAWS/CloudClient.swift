import Distributed
import Foundation
import Trebuche
import TrebucheCloud

// MARK: - Cloud Client

/// Client for resolving and calling actors across Lambda invocations
public actor TrebucheCloudClient {
    private let actorSystem: TrebuchetActorSystem
    private let registry: any ServiceRegistry
    private let transportFactory: TransportFactory

    /// Cache of transports by actor ID
    private var transportCache: [String: any TrebuchetTransport] = [:]

    /// Factory for creating transports
    public typealias TransportFactory = @Sendable (CloudEndpoint) async throws -> any TrebuchetTransport

    public init(
        actorSystem: TrebuchetActorSystem,
        registry: any ServiceRegistry,
        transportFactory: @escaping TransportFactory
    ) {
        self.actorSystem = actorSystem
        self.registry = registry
        self.transportFactory = transportFactory
    }

    /// Create a cloud client configured for AWS
    public static func aws(
        region: String,
        namespace: String,
        credentials: AWSCredentials = .default
    ) -> TrebucheCloudClient {
        let actorSystem = TrebuchetActorSystem()
        let registry = CloudMapRegistry(
            namespace: namespace,
            region: region,
            credentials: credentials
        )

        return TrebucheCloudClient(
            actorSystem: actorSystem,
            registry: registry
        ) { endpoint in
            LambdaInvokeTransport(
                functionArn: endpoint.identifier,
                region: region,
                credentials: credentials
            )
        }
    }

    /// Resolve a remote actor by ID
    /// - Parameters:
    ///   - actorType: The type of actor to resolve
    ///   - id: The actor's logical ID
    /// - Returns: A remote reference to the actor
    public func resolve<A: DistributedActor>(
        _ actorType: A.Type,
        id: String
    ) async throws -> A where A.ActorSystem == TrebuchetActorSystem {
        // Look up the actor's endpoint
        guard let endpoint = try await registry.resolve(actorID: id) else {
            throw CloudError.actorNotFound(actorID: id, provider: .aws)
        }

        // Get or create transport
        _ = try await getTransport(for: id, endpoint: endpoint)

        // Create remote actor ID
        guard let trebucheEndpoint = endpoint.toEndpoint() else {
            // For Lambda endpoints, create a synthetic endpoint using the identifier as host
            let actorID = TrebuchetActorID(id: id, host: endpoint.identifier, port: 443)
            return try A.resolve(id: actorID, using: actorSystem)
        }

        let actorID = TrebuchetActorID(id: id, host: trebucheEndpoint.host, port: trebucheEndpoint.port)
        return try A.resolve(id: actorID, using: actorSystem)
    }

    /// Resolve all instances of an actor (for load balancing)
    /// - Parameters:
    ///   - actorType: The type of actor to resolve
    ///   - id: The actor's logical ID
    /// - Returns: Array of remote references
    public func resolveAll<A: DistributedActor>(
        _ actorType: A.Type,
        id: String
    ) async throws -> [A] where A.ActorSystem == TrebuchetActorSystem {
        let endpoints = try await registry.resolveAll(actorID: id)

        var actors: [A] = []
        for endpoint in endpoints {
            if let trebucheEndpoint = endpoint.toEndpoint() {
                let actorID = TrebuchetActorID(id: id, host: trebucheEndpoint.host, port: trebucheEndpoint.port)
                if let actor = try? A.resolve(id: actorID, using: actorSystem) {
                    actors.append(actor)
                }
            } else {
                // For Lambda endpoints
                let actorID = TrebuchetActorID(id: id, host: endpoint.identifier, port: 443)
                if let actor = try? A.resolve(id: actorID, using: actorSystem) {
                    actors.append(actor)
                }
            }
        }
        return actors
    }

    /// Watch for changes to an actor's location
    /// - Parameter id: The actor ID to watch
    /// - Returns: Stream of registry events
    public func watch(id: String) -> AsyncStream<RegistryEvent> {
        registry.watch(actorID: id)
    }

    /// The underlying actor system
    public nonisolated var system: TrebuchetActorSystem {
        actorSystem
    }

    // MARK: - Private

    private func getTransport(for actorID: String, endpoint: CloudEndpoint) async throws -> any TrebuchetTransport {
        if let cached = transportCache[actorID] {
            return cached
        }

        let transport = try await transportFactory(endpoint)
        transportCache[actorID] = transport
        return transport
    }
}

// MARK: - Gateway Extension for Actor-to-Actor Calls

extension CloudGateway {
    /// Create a client for calling other actors from within an actor
    public func makeClient(
        region: String,
        credentials: AWSCredentials = .default
    ) -> TrebucheCloudClient? {
        // This would use the gateway's registry if available
        // For now, return nil if no registry is configured
        return nil
    }

    /// Process an invocation envelope and return a response
    public func process(_ envelope: InvocationEnvelope) async -> ResponseEnvelope {
        // This is a placeholder for the internal routing logic
        // The actual implementation would use executeDistributedTarget
        ResponseEnvelope.failure(
            callID: envelope.callID,
            error: "Gateway routing not implemented"
        )
    }
}

// MARK: - Actor Resolution Helpers

/// Helper protocol for actors that can resolve other actors
public protocol CloudActorResolver {
    var cloudClient: TrebucheCloudClient { get }
}

extension CloudActorResolver {
    /// Resolve another actor by type and ID
    public func resolve<A: DistributedActor>(
        _ actorType: A.Type,
        id: String
    ) async throws -> A where A.ActorSystem == TrebuchetActorSystem {
        try await cloudClient.resolve(actorType, id: id)
    }
}

// MARK: - Lambda Context

/// Extended Lambda context with cloud client
public struct CloudLambdaContext: Sendable {
    public let requestID: String
    public let functionName: String
    public let memoryLimit: Int
    public let deadline: Date
    public let region: String
    public let client: TrebucheCloudClient

    public var remainingTime: Duration {
        let remaining = deadline.timeIntervalSinceNow
        return .seconds(max(0, remaining))
    }

    public init(
        requestID: String,
        functionName: String,
        memoryLimit: Int,
        deadline: Date,
        region: String,
        client: TrebucheCloudClient
    ) {
        self.requestID = requestID
        self.functionName = functionName
        self.memoryLimit = memoryLimit
        self.deadline = deadline
        self.region = region
        self.client = client
    }

    /// Resolve another actor
    public func resolve<A: DistributedActor>(
        _ actorType: A.Type,
        id: String
    ) async throws -> A where A.ActorSystem == TrebuchetActorSystem {
        try await client.resolve(actorType, id: id)
    }
}
