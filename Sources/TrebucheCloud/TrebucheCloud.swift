/// TrebucheCloud - Cloud-native distributed actor framework
///
/// TrebucheCloud extends Trebuche with support for deploying distributed actors
/// to serverless platforms like AWS Lambda, GCP Cloud Functions, and Azure Functions.
///
/// ## Features
///
/// - **Cloud Providers**: Deploy actors to AWS, GCP, Azure, or Kubernetes
/// - **Service Discovery**: Automatic actor location via service registries
/// - **State Management**: External state stores for stateless serverless functions
/// - **HTTP Transport**: HTTP-based invocation for cloud compatibility
///
/// ## Quick Start
///
/// ```swift
/// import TrebucheCloud
///
/// // Create a cloud gateway for local development
/// let gateway = CloudGateway.development(port: 8080)
///
/// // Create and expose an actor
/// let counter = Counter(actorSystem: gateway.system)
/// try await gateway.expose(counter, as: "counter")
///
/// // Start the gateway
/// try await gateway.run()
/// ```
///
/// ## Cloud Deployment
///
/// ```swift
/// import TrebucheCloud
///
/// // Create a cloud client with service discovery
/// let cloud = TrebucheCloudClient(
///     registry: AWSCloudMapRegistry(namespace: "my-app"),
///     provider: .aws
/// )
///
/// // Resolve and invoke a remote actor
/// let counter = try await cloud.resolve(Counter.self, id: "counter")
/// let count = try await counter.increment()
/// ```

@_exported import Trebuche
import Foundation

// MARK: - Re-exports

// Core protocols
public typealias CloudProviderProtocol = CloudProvider
public typealias ServiceRegistryProtocol = ServiceRegistry
public typealias ActorStateStoreProtocol = ActorStateStore

// MARK: - TrebucheCloud Client

/// Client for interacting with cloud-deployed distributed actors.
public actor TrebucheCloudClient {
    private let registry: any ServiceRegistry
    private let providerType: CloudProviderType
    private let actorSystem: TrebuchetActorSystem
    private var transports: [String: any TrebuchetTransport] = [:]

    /// Create a cloud client
    /// - Parameters:
    ///   - registry: Service registry for actor discovery
    ///   - provider: The cloud provider type
    public init(
        registry: any ServiceRegistry,
        provider: CloudProviderType
    ) {
        self.registry = registry
        self.providerType = provider
        self.actorSystem = TrebuchetActorSystem()
    }

    /// The actor system used by this client
    public nonisolated var system: TrebuchetActorSystem {
        actorSystem
    }

    /// Resolve a remote actor by ID
    /// - Parameters:
    ///   - actorType: The type of actor to resolve
    ///   - id: The logical actor ID
    /// - Returns: A proxy to the remote actor
    public func resolve<A: DistributedActor>(
        _ actorType: A.Type,
        id: String
    ) async throws -> A where A.ActorSystem == TrebuchetActorSystem {
        // Look up the actor's endpoint in the registry
        guard let endpoint = try await registry.resolve(actorID: id) else {
            throw CloudError.actorNotFound(actorID: id, provider: providerType)
        }

        // Get or create transport for this endpoint
        let transport = try await getOrCreateTransport(for: endpoint)

        // Connect if needed
        if let traditionalEndpoint = endpoint.toEndpoint() {
            try await transport.connect(to: traditionalEndpoint)
        }

        // Create actor ID with endpoint info
        let actorID: TrebuchetActorID
        if let traditionalEndpoint = endpoint.toEndpoint() {
            actorID = TrebuchetActorID(
                id: id,
                host: traditionalEndpoint.host,
                port: traditionalEndpoint.port
            )
        } else {
            // For non-HTTP endpoints (Lambda, etc.), use the identifier
            actorID = TrebuchetActorID(
                id: id,
                host: endpoint.identifier,
                port: 443
            )
        }

        // Resolve through the actor system
        return try A.resolve(id: actorID, using: actorSystem)
    }

    /// Watch for actor availability changes
    /// - Parameter id: The actor ID to watch
    /// - Returns: Stream of availability events
    public func watch(actorID id: String) -> AsyncStream<ActorAvailability> {
        AsyncStream { continuation in
            Task {
                for await event in registry.watch(actorID: id) {
                    switch event {
                    case .updated(_, let endpoint):
                        continuation.yield(.available(endpoint: endpoint))
                    case .removed:
                        continuation.yield(.unavailable)
                    case .endpoints(_, let endpoints):
                        continuation.yield(.multipleInstances(count: endpoints.count))
                    case .error(let error):
                        continuation.yield(.error(error))
                    }
                }
                continuation.finish()
            }
        }
    }

    private func getOrCreateTransport(for endpoint: CloudEndpoint) async throws -> any TrebuchetTransport {
        let key = endpoint.identifier

        if let existing = transports[key] {
            return existing
        }

        // Create appropriate transport based on endpoint scheme
        let transport: any TrebuchetTransport
        switch endpoint.scheme {
        case .http, .https:
            transport = HTTPTransport()
        case .lambda, .cloudFunction, .azureFunction:
            // For now, fall back to HTTP transport
            // Full implementation would use provider-specific SDK
            transport = HTTPTransport()
        }

        transports[key] = transport
        return transport
    }

    /// Shutdown the client and all connections
    public func shutdown() async {
        for transport in transports.values {
            await transport.shutdown()
        }
        transports.removeAll()
    }
}

/// Actor availability status
public enum ActorAvailability: Sendable {
    case available(endpoint: CloudEndpoint)
    case unavailable
    case multipleInstances(count: Int)
    case error(Error)
}

// MARK: - Convenience Extensions

extension TrebucheCloudClient {
    /// Create a client for local development
    public static func local(port: UInt16 = 8080) async -> TrebucheCloudClient {
        let registry = InMemoryRegistry()
        await registerLocalEndpoint(registry: registry, port: port)
        return TrebucheCloudClient(registry: registry, provider: .local)
    }

    private static func registerLocalEndpoint(registry: InMemoryRegistry, port: UInt16) async {
        // Pre-register a local endpoint for development
        let endpoint = CloudEndpoint(
            provider: .local,
            region: "local",
            identifier: "localhost:\(port)",
            scheme: .http
        )
        try? await registry.register(
            actorID: "*",
            endpoint: endpoint,
            metadata: [:],
            ttl: nil
        )
    }
}

// MARK: - Version

/// TrebucheCloud version
public enum TrebucheCloudVersion {
    public static let major = 0
    public static let minor = 1
    public static let patch = 0
    public static var string: String { "\(major).\(minor).\(patch)" }
}
