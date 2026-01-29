import Foundation
import Trebuchet
import TrebuchetCloud
import SotoServiceDiscovery
import SotoCore

// MARK: - CloudMap Service Registry

/// Service registry implementation using AWS Cloud Map (Service Discovery)
///
/// AWS Cloud Map provides DNS-based service discovery for distributed actors.
/// This implementation manages actor instance registration and discovery across
/// multiple Lambda functions or EC2 instances.
///
/// ## Architecture
///
/// - **Namespace**: Top-level organization (e.g., "my-app-prod")
/// - **Service**: Groups instances (e.g., "actors")
/// - **Instances**: Individual actor deployments with metadata
///
/// ## Example Usage
///
/// ```swift
/// let registry = CloudMapRegistry(
///     namespace: "my-app-prod",
///     serviceName: "trebuchet-actors",
///     region: .useast1
/// )
///
/// try await registry.register(
///     actorID: "game-room-123",
///     endpoint: CloudEndpoint(
///         provider: .aws,
///         region: "us-east-1",
///         identifier: "arn:aws:lambda:us-east-1:123:function:actors",
///         scheme: .lambda
///     ),
///     metadata: ["version": "1.0.0"],
///     ttl: .seconds(300)
/// )
/// ```
public actor CloudMapRegistry: ServiceRegistry {
    private let client: ServiceDiscovery
    private let awsClient: AWSClient
    private let namespace: String
    private let serviceName: String

    /// Cached namespace ID to avoid repeated lookups
    private var cachedNamespaceId: String?

    /// Cached service ID to avoid repeated lookups
    private var cachedServiceId: String?

    /// Local cache of registrations for fast lookups
    private var cache: [String: CloudEndpoint] = [:]

    /// Watchers for change notifications
    private var watchers: [String: [AsyncStream<RegistryEvent>.Continuation]] = [:]

    /// Initialize CloudMap registry
    ///
    /// - Parameters:
    ///   - namespace: Cloud Map namespace (e.g., "my-app-prod")
    ///   - serviceName: Service name within namespace (default: "trebuchet-actors")
    ///   - region: AWS region (default: .useast1)
    ///   - endpoint: Custom endpoint for testing (e.g., LocalStack)
    ///   - awsClient: Optional custom AWSClient
    public init(
        namespace: String,
        serviceName: String = "trebuchet-actors",
        region: Region = .useast1,
        endpoint: String? = nil,
        awsClient: AWSClient? = nil
    ) {
        self.namespace = namespace
        self.serviceName = serviceName

        self.awsClient = awsClient ?? AWSClient(credentialProvider: .default)

        if let endpoint = endpoint {
            self.client = ServiceDiscovery(client: self.awsClient, region: region, endpoint: endpoint)
        } else {
            self.client = ServiceDiscovery(client: self.awsClient, region: region)
        }
    }

    public func register(
        actorID: String,
        endpoint: CloudEndpoint,
        metadata: [String: String],
        ttl: Duration?
    ) async throws {
        // Build attributes from metadata and endpoint
        var attributes: [String: String] = metadata
        attributes["ENDPOINT"] = endpoint.identifier
        attributes["REGION"] = endpoint.region
        attributes["PROVIDER"] = endpoint.provider.rawValue
        attributes["SCHEME"] = endpoint.scheme.rawValue

        let serviceId = try await getOrCreateServiceId()

        let input = ServiceDiscovery.RegisterInstanceRequest(
            attributes: attributes,
            instanceId: actorID,
            serviceId: serviceId
        )

        _ = try await client.registerInstance(input)

        // Update local cache
        cache[actorID] = endpoint

        // Notify watchers
        notifyWatchers(actorID: actorID, event: .updated(actorID: actorID, endpoint: endpoint))
    }

    public func resolve(actorID: String) async throws -> CloudEndpoint? {
        // Check cache first
        if let cached = cache[actorID] {
            return cached
        }

        // Query CloudMap
        let input = ServiceDiscovery.DiscoverInstancesRequest(
            namespaceName: namespace,
            queryParameters: ["actorId": actorID],
            serviceName: serviceName
        )

        do {
            let output = try await client.discoverInstances(input)

            guard let instance = output.instances?.first else {
                return nil
            }

            let endpoint = parseEndpoint(from: instance)
            cache[actorID] = endpoint
            return endpoint
        } catch let error as ServiceDiscoveryErrorType where error == .namespaceNotFound || error == .serviceNotFound {
            // Service or namespace doesn't exist yet
            return nil
        }
    }

    public func resolveAll(actorID: String) async throws -> [CloudEndpoint] {
        let input = ServiceDiscovery.DiscoverInstancesRequest(
            namespaceName: namespace,
            queryParameters: ["actorId": actorID],
            serviceName: serviceName
        )

        do {
            let output = try await client.discoverInstances(input)
            return output.instances?.compactMap { parseEndpoint(from: $0) } ?? []
        } catch let error as ServiceDiscoveryErrorType where error == .namespaceNotFound || error == .serviceNotFound {
            return []
        }
    }

    public nonisolated func watch(actorID: String) -> AsyncStream<RegistryEvent> {
        AsyncStream { continuation in
            Task {
                await self.addWatcher(actorID: actorID, continuation: continuation)

                // Send current state if available
                if let endpoint = await self.cache[actorID] {
                    continuation.yield(.updated(actorID: actorID, endpoint: endpoint))
                }
            }
        }
    }

    public func deregister(actorID: String) async throws {
        let serviceId = try await getOrCreateServiceId()

        let input = ServiceDiscovery.DeregisterInstanceRequest(
            instanceId: actorID,
            serviceId: serviceId
        )

        _ = try await client.deregisterInstance(input)

        cache.removeValue(forKey: actorID)
        notifyWatchers(actorID: actorID, event: .removed(actorID: actorID))
    }

    public func heartbeat(actorID: String) async throws {
        // CloudMap uses health checks, so heartbeat is just updating metadata
        guard let endpoint = cache[actorID] else {
            throw CloudError.actorNotFound(actorID: actorID, provider: .aws)
        }

        // Re-register with updated timestamp
        try await register(
            actorID: actorID,
            endpoint: endpoint,
            metadata: ["lastHeartbeat": ISO8601DateFormatter().string(from: Date())],
            ttl: .seconds(30)
        )
    }

    public func list(prefix: String?) async throws -> [String] {
        let serviceId = try await getOrCreateServiceId()

        let input = ServiceDiscovery.ListInstancesRequest(
            serviceId: serviceId
        )

        let output = try await client.listInstances(input)

        var ids = output.instances?.compactMap { $0.id } ?? []

        if let prefix = prefix {
            ids = ids.filter { $0.hasPrefix(prefix) }
        }

        return ids
    }

    // MARK: - Private Helpers

    /// Get or create the Cloud Map namespace ID
    private func getOrCreateNamespaceId() async throws -> String {
        // Return cached value if available
        if let cached = cachedNamespaceId {
            return cached
        }

        // List namespaces to find ours
        let listInput = ServiceDiscovery.ListNamespacesRequest()
        let listOutput = try await client.listNamespaces(listInput)

        if let existing = listOutput.namespaces?.first(where: { $0.name == namespace }) {
            guard let namespaceId = existing.id else {
                throw CloudError.deploymentFailed(provider: .aws, reason: "Namespace summary missing ID")
            }
            cachedNamespaceId = namespaceId
            return namespaceId
        }

        // Create namespace if it doesn't exist
        let createInput = ServiceDiscovery.CreatePrivateDnsNamespaceRequest(
            name: namespace,
            vpc: try await getVpcId()
        )

        let createOutput = try await client.createPrivateDnsNamespace(createInput)

        // Wait for operation to complete and get the namespace ID from the operation
        guard let operationId = createOutput.operationId else {
            throw CloudError.deploymentFailed(provider: .aws, reason: "CreatePrivateDnsNamespace returned no operation ID")
        }

        try await waitForOperation(operationId: operationId)

        // Get the namespace ID from the operation result
        let operation = try await client.getOperation(.init(operationId: operationId))
        guard let namespaceId = operation.operation?.targets?[.namespace] else {
            throw CloudError.deploymentFailed(provider: .aws, reason: "Operation result missing namespace ID")
        }

        cachedNamespaceId = namespaceId
        return namespaceId
    }

    /// Get or create the Cloud Map service ID
    private func getOrCreateServiceId() async throws -> String {
        // Return cached value if available
        if let cached = cachedServiceId {
            return cached
        }

        let namespaceId = try await getOrCreateNamespaceId()

        // List services to find ours
        let listInput = ServiceDiscovery.ListServicesRequest()
        let listOutput = try await client.listServices(listInput)

        if let existing = listOutput.services?.first(where: { $0.name == serviceName }) {
            guard let serviceId = existing.id else {
                throw CloudError.deploymentFailed(provider: .aws, reason: "Service summary missing ID")
            }
            cachedServiceId = serviceId
            return serviceId
        }

        // Create service if it doesn't exist
        let dnsConfig = ServiceDiscovery.DnsConfig(
            dnsRecords: [
                ServiceDiscovery.DnsRecord(
                    ttl: 60,
                    type: .a
                )
            ],
            routingPolicy: .multivalue
        )

        let createInput = ServiceDiscovery.CreateServiceRequest(
            dnsConfig: dnsConfig,
            name: serviceName,
            namespaceId: namespaceId
        )

        let createOutput = try await client.createService(createInput)

        guard let serviceId = createOutput.service?.id else {
            throw CloudError.deploymentFailed(provider: .aws, reason: "Service creation returned nil service ID")
        }
        cachedServiceId = serviceId
        return serviceId
    }

    /// Get VPC ID for private DNS namespace (required for Cloud Map)
    /// In production, this should be configured via environment variable
    private func getVpcId() async throws -> String {
        // Try environment variable first
        if let vpcId = ProcessInfo.processInfo.environment["TREBUCHET_VPC_ID"] {
            return vpcId
        }

        // For now, throw error - VPC ID must be provided
        throw CloudError.configurationInvalid("TREBUCHET_VPC_ID environment variable required for Cloud Map")
    }

    /// Wait for a Cloud Map operation to complete
    private func waitForOperation(operationId: String) async throws {
        var attempts = 0
        let maxAttempts = 30

        while attempts < maxAttempts {
            let input = ServiceDiscovery.GetOperationRequest(operationId: operationId)
            let output = try await client.getOperation(input)

            switch output.operation?.status {
            case .success:
                return
            case .fail:
                throw CloudError.deploymentFailed(provider: .aws, reason: "Cloud Map operation failed")
            case .pending, .submitted, .none:
                try await Task.sleep(for: .seconds(2))
                attempts += 1
            }
        }

        throw CloudError.timeout(operation: "Cloud Map operation", duration: .seconds(60))
    }

    private func parseEndpoint(from instance: ServiceDiscovery.HttpInstanceSummary) -> CloudEndpoint? {
        guard let attributes = instance.attributes,
              let identifier = attributes["ENDPOINT"],
              let regionStr = attributes["REGION"] else {
            return nil
        }

        let providerStr = attributes["PROVIDER"] ?? "aws"
        let provider = CloudProviderType(rawValue: providerStr) ?? .aws

        let schemeStr = attributes["SCHEME"] ?? "lambda"
        let scheme = EndpointScheme(rawValue: schemeStr) ?? .lambda

        return CloudEndpoint(
            provider: provider,
            region: regionStr,
            identifier: identifier,
            scheme: scheme
        )
    }

    private func addWatcher(actorID: String, continuation: AsyncStream<RegistryEvent>.Continuation) {
        var list = watchers[actorID] ?? []
        list.append(continuation)
        watchers[actorID] = list
    }

    private func notifyWatchers(actorID: String, event: RegistryEvent) {
        guard let continuations = watchers[actorID] else { return }
        for continuation in continuations {
            continuation.yield(event)
        }
    }

    // MARK: - Lifecycle

    /// Shutdown the underlying AWS client
    ///
    /// This should be called when the registry is no longer needed to properly
    /// clean up resources. After calling shutdown, the registry cannot be used.
    public func shutdown() async throws {
        try await awsClient.shutdown()
    }
}
