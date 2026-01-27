/// TrebuchetCloud - Cloud-native distributed actor framework
///
/// TrebuchetCloud extends Trebuchet with support for deploying distributed actors
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
/// import TrebuchetCloud
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
/// import TrebuchetCloud
///
/// // Create a cloud client with service discovery
/// let cloud = TrebuchetCloudClient(
///     registry: AWSCloudMapRegistry(namespace: "my-app"),
///     provider: .aws
/// )
///
/// // Resolve and invoke a remote actor
/// let counter = try await cloud.resolve(Counter.self, id: "counter")
/// let count = try await counter.increment()
/// ```

@_exported import Trebuchet
import Foundation

// MARK: - Re-exports

// Core protocols
public typealias CloudProviderProtocol = CloudProvider
public typealias ServiceRegistryProtocol = ServiceRegistry
public typealias ActorStateStoreProtocol = ActorStateStore

// MARK: - TrebuchetCloud Client

/// Client for interacting with cloud-deployed distributed actors.
public actor TrebuchetCloudClient {
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
        case .http:
            transport = HTTPTransport(tlsEnabled: false)
        case .https:
            transport = HTTPTransport.https()
        case .lambda, .cloudFunction, .azureFunction:
            // For now, fall back to HTTPS transport since cloud function
            // endpoints typically use HTTPS. Full implementation would
            // use provider-specific SDKs (AWS SDK, GCP SDK, etc.)
            transport = HTTPTransport.https()
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

extension TrebuchetCloudClient {
    /// Create a client for local development
    /// - Parameters:
    ///   - host: The host to connect to (default: localhost)
    ///   - port: The port to connect to (default: 8080)
    /// - Returns: A cloud client configured for local development
    public static func local(host: String = "localhost", port: UInt16 = 8080) async -> TrebuchetCloudClient {
        let endpoint = CloudEndpoint(
            provider: .local,
            region: "local",
            identifier: "\(host):\(port)",
            scheme: .http
        )
        let registry = LocalDevelopmentRegistry(defaultEndpoint: endpoint)
        return TrebuchetCloudClient(registry: registry, provider: .local)
    }
}

// MARK: - Local Development Registry

/// A registry that returns a default endpoint for any actor ID.
/// Used for local development where all actors are hosted on the same gateway.
public actor LocalDevelopmentRegistry: ServiceRegistry {
    private let defaultEndpoint: CloudEndpoint
    private var registrations: [String: CloudEndpoint] = [:]

    /// Create a local development registry
    /// - Parameter defaultEndpoint: The default endpoint for unregistered actors
    public init(defaultEndpoint: CloudEndpoint) {
        self.defaultEndpoint = defaultEndpoint
    }

    public func register(
        actorID: String,
        endpoint: CloudEndpoint,
        metadata: [String: String],
        ttl: Duration?
    ) async throws {
        registrations[actorID] = endpoint
    }

    public func resolve(actorID: String) async throws -> CloudEndpoint? {
        // Return specific registration if exists, otherwise return default
        registrations[actorID] ?? defaultEndpoint
    }

    public func resolveAll(actorID: String) async throws -> [CloudEndpoint] {
        if let specific = registrations[actorID] {
            return [specific]
        }
        return [defaultEndpoint]
    }

    public nonisolated func watch(actorID: String) -> AsyncStream<RegistryEvent> {
        AsyncStream { continuation in
            Task { [self] in
                let endpoint = await self.registrations[actorID] ?? self.defaultEndpoint
                continuation.yield(.updated(actorID: actorID, endpoint: endpoint))
            }
        }
    }

    public func deregister(actorID: String) async throws {
        registrations.removeValue(forKey: actorID)
    }

    public func heartbeat(actorID: String) async throws {
        // No-op for local development
    }

    public func list(prefix: String?) async throws -> [String] {
        let keys = Array(registrations.keys)
        if let prefix {
            return keys.filter { $0.hasPrefix(prefix) }
        }
        return keys
    }
}

// MARK: - Version

/// TrebuchetCloud version
public enum TrebuchetCloudVersion {
    public static let major = 0
    public static let minor = 1
    public static let patch = 0
    public static var string: String { "\(major).\(minor).\(patch)" }
}
