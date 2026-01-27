import Foundation
import Trebuchet
import TrebuchetCloud

// MARK: - CloudMap Service Registry

/// Service registry implementation using AWS Cloud Map
public actor CloudMapRegistry: ServiceRegistry {
    private let namespace: String
    private let region: String
    private let credentials: AWSCredentials

    /// Local cache of registrations
    private var cache: [String: CloudEndpoint] = [:]

    /// Watchers for change notifications
    private var watchers: [String: [AsyncStream<RegistryEvent>.Continuation]] = [:]

    public init(
        namespace: String,
        region: String = "us-east-1",
        credentials: AWSCredentials = .default
    ) {
        self.namespace = namespace
        self.region = region
        self.credentials = credentials
    }

    public func register(
        actorID: String,
        endpoint: CloudEndpoint,
        metadata: [String: String],
        ttl: Duration?
    ) async throws {
        // Build attributes from metadata
        var attributes: [String: String] = metadata
        attributes["ENDPOINT"] = endpoint.identifier
        attributes["REGION"] = endpoint.region
        attributes["PROVIDER"] = endpoint.provider.rawValue

        let request = CloudMapRequest(
            operation: "RegisterInstance",
            serviceId: try await getServiceId(),
            instanceId: actorID,
            attributes: attributes
        )

        try await execute(request)

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
        let request = CloudMapRequest(
            operation: "DiscoverInstances",
            namespaceName: namespace,
            serviceName: "actors",
            queryParameters: ["actorId": actorID]
        )

        let response = try await execute(request)

        guard let instance = response.instances?.first else {
            return nil
        }

        let endpoint = parseEndpoint(from: instance)
        cache[actorID] = endpoint
        return endpoint
    }

    public func resolveAll(actorID: String) async throws -> [CloudEndpoint] {
        let request = CloudMapRequest(
            operation: "DiscoverInstances",
            namespaceName: namespace,
            serviceName: "actors",
            queryParameters: ["actorId": actorID]
        )

        let response = try await execute(request)

        return response.instances?.compactMap { parseEndpoint(from: $0) } ?? []
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
        let request = CloudMapRequest(
            operation: "DeregisterInstance",
            serviceId: try await getServiceId(),
            instanceId: actorID
        )

        try await execute(request)

        cache.removeValue(forKey: actorID)
        notifyWatchers(actorID: actorID, event: .removed(actorID: actorID))
    }

    public func heartbeat(actorID: String) async throws {
        // CloudMap uses health checks, so heartbeat is just updating TTL
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
        let request = CloudMapRequest(
            operation: "ListInstances",
            serviceId: try await getServiceId()
        )

        let response = try await execute(request)

        var ids = response.instances?.compactMap { $0["instanceId"] as? String } ?? []

        if let prefix = prefix {
            ids = ids.filter { $0.hasPrefix(prefix) }
        }

        return ids
    }

    // MARK: - Private

    private func getServiceId() async throws -> String {
        // In a real implementation, this would look up the service ID
        // from CloudMap or use a cached value
        return "\(namespace)/actors"
    }

    private func parseEndpoint(from instance: [String: Any]) -> CloudEndpoint? {
        guard let identifier = instance["ENDPOINT"] as? String,
              let regionStr = instance["REGION"] as? String else {
            return nil
        }

        let providerStr = instance["PROVIDER"] as? String ?? "aws"
        let provider = CloudProviderType(rawValue: providerStr) ?? .aws

        return CloudEndpoint(
            provider: provider,
            region: regionStr,
            identifier: identifier,
            scheme: .lambda
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

    private func execute(_ request: CloudMapRequest) async throws -> CloudMapResponse {
        // In a real implementation, this would use the AWS SDK (Soto)
        // For now, we return an empty response
        return CloudMapResponse()
    }
}

// MARK: - CloudMap Types

struct CloudMapRequest: Codable {
    let operation: String
    var serviceId: String?
    var instanceId: String?
    var namespaceName: String?
    var serviceName: String?
    var attributes: [String: String]?
    var queryParameters: [String: String]?
}

struct CloudMapResponse: Codable {
    var instances: [[String: Any]]?

    init(instances: [[String: Any]]? = nil) {
        self.instances = instances
    }

    init(from decoder: Decoder) throws {
        // Custom decoding for dynamic dictionaries
        let container = try decoder.container(keyedBy: DynamicCodingKeys.self)

        if container.contains(DynamicCodingKeys(stringValue: "Instances")!) {
            // Would decode instances array
            self.instances = nil
        } else {
            self.instances = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        // Custom encoding for dynamic dictionaries
    }
}

struct DynamicCodingKeys: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}
