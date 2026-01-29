import Distributed
import Foundation
import Trebuchet

// MARK: - Local Provider

/// A cloud provider for local development and testing.
///
/// The local provider simulates cloud deployments by running actors
/// in-process with HTTP endpoints, allowing you to develop and test
/// cloud-native actors without deploying to actual cloud infrastructure.
public actor LocalProvider: CloudProvider {
    public static let providerType: CloudProviderType = .local

    private let host: String
    private let basePort: UInt16
    private var nextPort: UInt16
    private var deployments: [String: LocalDeployment] = [:]
    private var gateways: [String: CloudGateway] = [:]

    /// Create a local provider
    /// - Parameters:
    ///   - host: Host to bind to (default: localhost)
    ///   - basePort: Starting port for actor gateways
    public init(host: String = "localhost", basePort: UInt16 = 9000) {
        self.host = host
        self.basePort = basePort
        self.nextPort = basePort
    }

    // MARK: - CloudProvider Conformance

    public func deploy<A: DistributedActor>(
        _ actorType: A.Type,
        as actorID: String,
        config: LocalFunctionConfig,
        factory: @Sendable (TrebuchetActorSystem) -> A
    ) async throws -> LocalDeployment where A.ActorSystem == TrebuchetActorSystem {
        let port = nextPort
        nextPort += 1

        // Create a gateway for this actor
        let gateway = CloudGateway(configuration: .init(
            host: host,
            port: port,
            stateStore: config.stateStore,
            registry: config.registry
        ))

        // Create the actor instance using the factory
        let actor = factory(gateway.system)

        // Expose the actor
        try await gateway.expose(actor, as: actorID)

        // Start the gateway in the background
        Task {
            try await gateway.run()
        }

        // Give the server a moment to start
        try await Task.sleep(for: .milliseconds(100))

        let deployment = LocalDeployment(
            actorID: actorID,
            host: host,
            port: port,
            actorType: String(describing: A.self)
        )

        deployments[actorID] = deployment
        gateways[actorID] = gateway

        return deployment
    }

    public func transport(for deployment: LocalDeployment) async throws -> any TrebuchetTransport {
        HTTPTransport()
    }

    public func listDeployments() async throws -> [LocalDeployment] {
        Array(deployments.values)
    }

    public func undeploy(_ deployment: LocalDeployment) async throws {
        if let gateway = gateways[deployment.actorID] {
            await gateway.shutdown()
        }
        deployments.removeValue(forKey: deployment.actorID)
        gateways.removeValue(forKey: deployment.actorID)
    }

    public func status(of deployment: LocalDeployment) async throws -> DeploymentStatus {
        if deployments[deployment.actorID] != nil {
            return .active
        }
        return .removed
    }

    /// Shutdown all local deployments
    public func shutdownAll() async {
        for gateway in gateways.values {
            await gateway.shutdown()
        }
        deployments.removeAll()
        gateways.removeAll()
    }
}

// MARK: - Local Function Config

/// Configuration for local actor deployment
public struct LocalFunctionConfig: Sendable {
    public var stateStore: (any ActorStateStore)?
    public var registry: (any ServiceRegistry)?
    public var environment: [String: String]

    public init(
        stateStore: (any ActorStateStore)? = nil,
        registry: (any ServiceRegistry)? = nil,
        environment: [String: String] = [:]
    ) {
        self.stateStore = stateStore
        self.registry = registry
        self.environment = environment
    }

    public static let `default` = LocalFunctionConfig()
}

// MARK: - Local Deployment

/// Result of deploying an actor locally
public struct LocalDeployment: CloudDeployment {
    public let provider: CloudProviderType = .local
    public let actorID: String
    public let region: String = "local"
    public let host: String
    public let port: UInt16
    public let actorType: String
    public let createdAt: Date

    public var identifier: String {
        "\(host):\(port)"
    }

    enum CodingKeys: String, CodingKey {
        case provider, actorID, region, host, port, actorType, createdAt
    }

    public init(
        actorID: String,
        host: String,
        port: UInt16,
        actorType: String
    ) {
        self.actorID = actorID
        self.host = host
        self.port = port
        self.actorType = actorType
        self.createdAt = Date()
    }

    /// Convert to a cloud endpoint
    public var endpoint: CloudEndpoint {
        CloudEndpoint(
            provider: .local,
            region: "local",
            identifier: identifier,
            scheme: .http,
            metadata: ["actorType": actorType]
        )
    }

    /// Convert to a traditional Trebuchet endpoint
    public var trebuchetEndpoint: Endpoint {
        Endpoint(host: host, port: port)
    }
}

// MARK: - Development Helpers

extension LocalProvider {
    /// Quick setup for development with a single actor
    /// - Parameters:
    ///   - actorType: The distributed actor type to deploy
    ///   - actorID: The logical ID for this actor instance
    ///   - port: The port to use (default: 8080)
    ///   - factory: A closure that creates the actor given an actor system
    /// - Returns: A tuple containing the provider, deployment, and actor system
    public static func quickStart<A: DistributedActor>(
        _ actorType: A.Type,
        as actorID: String,
        port: UInt16 = 8080,
        factory: @Sendable @escaping (TrebuchetActorSystem) -> A
    ) async throws -> (provider: LocalProvider, deployment: LocalDeployment, system: TrebuchetActorSystem) where A.ActorSystem == TrebuchetActorSystem {
        let provider = LocalProvider(basePort: port)
        let deployment = try await provider.deploy(actorType, as: actorID, config: .default, factory: factory)

        // Get the gateway's actor system for creating actors
        let gateway = await provider.gateway(for: actorID)

        return (provider, deployment, gateway?.system ?? TrebuchetActorSystem())
    }

    /// Get the gateway for a deployed actor (for testing)
    func gateway(for actorID: String) -> CloudGateway? {
        gateways[actorID]
    }
}
