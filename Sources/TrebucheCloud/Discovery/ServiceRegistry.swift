import Foundation
import Trebuchet

// MARK: - Service Registry Protocol

/// Protocol for service discovery and actor location registration.
///
/// Service registries allow actors to be discovered by logical name rather than
/// requiring hardcoded endpoints. This enables dynamic scaling and failover.
public protocol ServiceRegistry: Sendable {
    /// Register an actor's location in the registry
    /// - Parameters:
    ///   - actorID: The logical actor identifier
    ///   - endpoint: The cloud endpoint where the actor is deployed
    ///   - metadata: Additional metadata about the actor
    ///   - ttl: Time-to-live for the registration (for health checking)
    func register(
        actorID: String,
        endpoint: CloudEndpoint,
        metadata: [String: String],
        ttl: Duration?
    ) async throws

    /// Resolve an actor's current location
    /// - Parameter actorID: The logical actor identifier
    /// - Returns: The endpoint if found, nil otherwise
    func resolve(actorID: String) async throws -> CloudEndpoint?

    /// Resolve all instances of an actor (for load balancing)
    /// - Parameter actorID: The logical actor identifier
    /// - Returns: All registered endpoints for this actor
    func resolveAll(actorID: String) async throws -> [CloudEndpoint]

    /// Watch for changes to an actor's location
    /// - Parameter actorID: The actor to watch
    /// - Returns: Stream of endpoint updates
    func watch(actorID: String) -> AsyncStream<RegistryEvent>

    /// Deregister an actor
    /// - Parameter actorID: The actor to deregister
    func deregister(actorID: String) async throws

    /// Heartbeat to keep registration alive
    /// - Parameter actorID: The actor to heartbeat
    func heartbeat(actorID: String) async throws

    /// List all registered actors
    /// - Parameter prefix: Optional prefix filter
    /// - Returns: List of registered actor IDs
    func list(prefix: String?) async throws -> [String]
}

// MARK: - Registry Events

/// Events emitted by service registry watches
public enum RegistryEvent: Sendable {
    /// Actor endpoint was registered or updated
    case updated(actorID: String, endpoint: CloudEndpoint)

    /// Actor endpoint was removed
    case removed(actorID: String)

    /// Multiple endpoints available (for load balancing)
    case endpoints(actorID: String, endpoints: [CloudEndpoint])

    /// Watch encountered an error
    case error(Error)
}

// MARK: - Cloud Endpoint

/// Represents an endpoint in a cloud environment.
///
/// Unlike the base `Endpoint` which uses host:port, cloud endpoints
/// can reference various cloud-native identifiers.
public struct CloudEndpoint: Sendable, Codable, Hashable {
    /// The cloud provider hosting this endpoint
    public let provider: CloudProviderType

    /// The region where the endpoint is located
    public let region: String

    /// Provider-specific identifier (ARN, URL, service name, etc.)
    public let identifier: String

    /// The protocol/scheme to use
    public let scheme: EndpointScheme

    /// Optional metadata
    public let metadata: [String: String]

    public init(
        provider: CloudProviderType,
        region: String,
        identifier: String,
        scheme: EndpointScheme = .https,
        metadata: [String: String] = [:]
    ) {
        self.provider = provider
        self.region = region
        self.identifier = identifier
        self.scheme = scheme
        self.metadata = metadata
    }

    /// Create an AWS Lambda endpoint
    public static func awsLambda(
        functionArn: String,
        region: String
    ) -> CloudEndpoint {
        CloudEndpoint(
            provider: .aws,
            region: region,
            identifier: functionArn,
            scheme: .lambda
        )
    }

    /// Create an AWS API Gateway endpoint
    public static func awsApiGateway(
        url: String,
        region: String
    ) -> CloudEndpoint {
        CloudEndpoint(
            provider: .aws,
            region: region,
            identifier: url,
            scheme: .https
        )
    }

    /// Create a GCP Cloud Function endpoint (Gen 1)
    ///
    /// For Cloud Functions Gen 1, the URL format is:
    /// `https://{region}-{project}.cloudfunctions.net/{name}`
    ///
    /// - Parameters:
    ///   - name: The function name
    ///   - project: The GCP project ID
    ///   - region: The GCP region (e.g., "us-central1")
    /// - Returns: A cloud endpoint for the function
    public static func gcpCloudFunction(
        name: String,
        project: String,
        region: String
    ) -> CloudEndpoint {
        // Gen 1 Cloud Functions URL format
        let url = "https://\(region)-\(project).cloudfunctions.net/\(name)"
        return CloudEndpoint(
            provider: .gcp,
            region: region,
            identifier: url,
            scheme: .https,
            metadata: [
                "functionName": name,
                "project": project,
                "generation": "1"
            ]
        )
    }

    /// Create a GCP Cloud Function endpoint (Gen 2 / Cloud Run)
    ///
    /// For Cloud Functions Gen 2, functions run on Cloud Run with URLs like:
    /// `https://{name}-{hash}-{region}.a.run.app`
    ///
    /// Since the hash is auto-generated, you must provide the full URL.
    ///
    /// - Parameters:
    ///   - url: The full Cloud Run URL for the function
    ///   - region: The GCP region
    /// - Returns: A cloud endpoint for the function
    public static func gcpCloudFunctionGen2(
        url: String,
        region: String
    ) -> CloudEndpoint {
        CloudEndpoint(
            provider: .gcp,
            region: region,
            identifier: url,
            scheme: .https,
            metadata: ["generation": "2"]
        )
    }

    /// Create a GCP Cloud Function endpoint using direct invocation
    ///
    /// Uses the Cloud Functions API for direct invocation (requires auth).
    /// The identifier is the resource path for API calls.
    ///
    /// - Parameters:
    ///   - name: The function name
    ///   - project: The GCP project ID
    ///   - region: The GCP region
    /// - Returns: A cloud endpoint for direct API invocation
    public static func gcpCloudFunctionDirect(
        name: String,
        project: String,
        region: String
    ) -> CloudEndpoint {
        CloudEndpoint(
            provider: .gcp,
            region: region,
            identifier: "projects/\(project)/locations/\(region)/functions/\(name)",
            scheme: .cloudFunction,
            metadata: [
                "functionName": name,
                "project": project,
                "invocationType": "direct"
            ]
        )
    }

    /// Create a Kubernetes service endpoint
    public static func kubernetes(
        serviceName: String,
        namespace: String,
        port: UInt16 = 80
    ) -> CloudEndpoint {
        CloudEndpoint(
            provider: .kubernetes,
            region: namespace,
            identifier: "\(serviceName).\(namespace).svc.cluster.local:\(port)",
            scheme: .http
        )
    }

    /// Convert to a traditional Trebuchet Endpoint if possible
    public func toEndpoint() -> Endpoint? {
        // Only HTTP-based schemes can be converted
        switch scheme {
        case .http, .https:
            return parseHTTPEndpoint()
        case .lambda, .cloudFunction, .azureFunction:
            // These don't map to traditional endpoints - they require
            // provider-specific SDKs for invocation
            return nil
        }
    }

    private func parseHTTPEndpoint() -> Endpoint? {
        // Remove scheme prefix if present
        var hostPart = identifier
        if hostPart.hasPrefix("https://") {
            hostPart = String(hostPart.dropFirst(8))
        } else if hostPart.hasPrefix("http://") {
            hostPart = String(hostPart.dropFirst(7))
        }

        // Remove path component (everything after first /)
        if let slashIndex = hostPart.firstIndex(of: "/") {
            hostPart = String(hostPart[..<slashIndex])
        }

        // Parse host:port
        let components = hostPart.split(separator: ":")
        if components.count == 2, let port = UInt16(components[1]) {
            return Endpoint(host: String(components[0]), port: port)
        } else if components.count == 1 {
            // No port specified, use default based on scheme
            return Endpoint(host: String(components[0]), port: scheme == .https ? 443 : 80)
        }

        return nil
    }

    /// The path component of the identifier URL, if any
    public var path: String? {
        guard scheme.isHTTPBased else { return nil }

        var pathPart = identifier
        if pathPart.hasPrefix("https://") {
            pathPart = String(pathPart.dropFirst(8))
        } else if pathPart.hasPrefix("http://") {
            pathPart = String(pathPart.dropFirst(7))
        }

        if let slashIndex = pathPart.firstIndex(of: "/") {
            return String(pathPart[slashIndex...])
        }

        return nil
    }
}

// MARK: - Endpoint Scheme

/// The protocol scheme for cloud endpoints
public enum EndpointScheme: String, Sendable, Codable, Hashable {
    case http
    case https
    case lambda      // AWS Lambda direct invoke
    case cloudFunction  // GCP Cloud Function
    case azureFunction  // Azure Function

    public var isHTTPBased: Bool {
        switch self {
        case .http, .https: return true
        default: return false
        }
    }
}

// MARK: - In-Memory Registry

/// Simple in-memory service registry for testing and local development.
public actor InMemoryRegistry: ServiceRegistry {
    private var registrations: [String: RegistrationEntry] = [:]
    private var watchers: [String: [AsyncStream<RegistryEvent>.Continuation]] = [:]

    private struct RegistrationEntry {
        var endpoints: [CloudEndpoint]
        var metadata: [String: String]
        var ttl: Duration?
        var lastHeartbeat: Date
    }

    public init() {}

    public func register(
        actorID: String,
        endpoint: CloudEndpoint,
        metadata: [String: String],
        ttl: Duration?
    ) async throws {
        var entry = registrations[actorID] ?? RegistrationEntry(
            endpoints: [],
            metadata: metadata,
            ttl: ttl,
            lastHeartbeat: Date()
        )

        if !entry.endpoints.contains(endpoint) {
            entry.endpoints.append(endpoint)
        }
        entry.metadata = metadata
        entry.ttl = ttl
        entry.lastHeartbeat = Date()

        registrations[actorID] = entry

        // Notify watchers
        notifyWatchers(actorID: actorID, event: .updated(actorID: actorID, endpoint: endpoint))
    }

    public func resolve(actorID: String) async throws -> CloudEndpoint? {
        registrations[actorID]?.endpoints.first
    }

    public func resolveAll(actorID: String) async throws -> [CloudEndpoint] {
        registrations[actorID]?.endpoints ?? []
    }

    public nonisolated func watch(actorID: String) -> AsyncStream<RegistryEvent> {
        AsyncStream { continuation in
            Task { [self] in
                await self.addWatcher(actorID: actorID, continuation: continuation)

                // Send current state
                if let entry = await self.registrations[actorID] {
                    if entry.endpoints.count == 1, let endpoint = entry.endpoints.first {
                        continuation.yield(.updated(actorID: actorID, endpoint: endpoint))
                    } else if entry.endpoints.count > 1 {
                        continuation.yield(.endpoints(actorID: actorID, endpoints: entry.endpoints))
                    }
                }
            }
        }
    }

    public func deregister(actorID: String) async throws {
        registrations.removeValue(forKey: actorID)
        notifyWatchers(actorID: actorID, event: .removed(actorID: actorID))
    }

    public func heartbeat(actorID: String) async throws {
        guard var entry = registrations[actorID] else {
            throw CloudError.actorNotFound(actorID: actorID, provider: .local)
        }
        entry.lastHeartbeat = Date()
        registrations[actorID] = entry
    }

    public func list(prefix: String?) async throws -> [String] {
        let keys = Array(registrations.keys)
        if let prefix {
            return keys.filter { $0.hasPrefix(prefix) }
        }
        return keys
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
}
