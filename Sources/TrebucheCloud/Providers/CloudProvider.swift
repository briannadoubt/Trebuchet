import Distributed
import Foundation
import Trebuche

// MARK: - Cloud Provider Protocol

/// Protocol defining a cloud provider that can deploy and invoke distributed actors.
///
/// Cloud providers handle the specifics of deploying actors to serverless platforms
/// (Lambda, Cloud Functions, Azure Functions) and creating transports for invoking them.
public protocol CloudProvider: Sendable {
    /// Configuration type for deploying functions
    associatedtype FunctionConfig: Sendable

    /// Result type returned after deployment
    associatedtype DeploymentResult: CloudDeployment

    /// The provider type identifier
    static var providerType: CloudProviderType { get }

    /// Deploy an actor type as a serverless function
    /// - Parameters:
    ///   - actorType: The distributed actor type to deploy
    ///   - actorID: The logical ID for this actor instance
    ///   - config: Provider-specific configuration
    ///   - factory: A closure that creates the actor given an actor system
    /// - Returns: Deployment result containing function identifier
    func deploy<A: DistributedActor>(
        _ actorType: A.Type,
        as actorID: String,
        config: FunctionConfig,
        factory: @Sendable (TrebuchetActorSystem) -> A
    ) async throws -> DeploymentResult where A.ActorSystem == TrebuchetActorSystem

    /// Create a transport for invoking deployed actors
    /// - Parameter deployment: The deployment to create a transport for
    /// - Returns: A transport configured for the deployed function
    func transport(for deployment: DeploymentResult) async throws -> any TrebuchetTransport

    /// List all deployed actor functions
    /// - Returns: Array of current deployments
    func listDeployments() async throws -> [DeploymentResult]

    /// Remove a deployment
    /// - Parameter deployment: The deployment to remove
    func undeploy(_ deployment: DeploymentResult) async throws

    /// Check health/status of a deployment
    /// - Parameter deployment: The deployment to check
    /// - Returns: Current status of the deployment
    func status(of deployment: DeploymentResult) async throws -> DeploymentStatus
}

// MARK: - Cloud Provider Type

/// Enumeration of supported cloud providers
public enum CloudProviderType: String, Sendable, Codable, Hashable {
    case aws
    case gcp
    case azure
    case kubernetes
    case local  // For testing/development

    public var displayName: String {
        switch self {
        case .aws: return "Amazon Web Services"
        case .gcp: return "Google Cloud Platform"
        case .azure: return "Microsoft Azure"
        case .kubernetes: return "Kubernetes"
        case .local: return "Local Development"
        }
    }
}

// MARK: - Cloud Deployment Protocol

/// Protocol for deployment results from cloud providers
public protocol CloudDeployment: Sendable, Codable, Hashable {
    /// The cloud provider type
    var provider: CloudProviderType { get }

    /// The actor ID this deployment hosts
    var actorID: String { get }

    /// The region where deployed
    var region: String { get }

    /// Provider-specific identifier (ARN, URL, etc.)
    var identifier: String { get }

    /// When the deployment was created
    var createdAt: Date { get }
}

// MARK: - Deployment Status

/// Status of a cloud deployment
public enum DeploymentStatus: Sendable, Codable, Hashable {
    /// Deployment is being created
    case deploying

    /// Deployment is active and ready
    case active

    /// Deployment is updating
    case updating

    /// Deployment failed
    case failed(reason: String)

    /// Deployment is being removed
    case removing

    /// Deployment has been removed
    case removed

    public var isHealthy: Bool {
        switch self {
        case .active: return true
        default: return false
        }
    }
}

// MARK: - Function Configuration

/// Base configuration for serverless function deployment
public struct FunctionConfiguration: Sendable, Codable {
    /// Memory allocation in MB
    public var memoryMB: Int

    /// Timeout duration
    public var timeout: Duration

    /// Maximum concurrent executions
    public var concurrency: Int?

    /// Environment variables
    public var environment: [String: String]

    /// Tags/labels for the function
    public var tags: [String: String]

    public init(
        memoryMB: Int = 256,
        timeout: Duration = .seconds(30),
        concurrency: Int? = nil,
        environment: [String: String] = [:],
        tags: [String: String] = [:]
    ) {
        self.memoryMB = memoryMB
        self.timeout = timeout
        self.concurrency = concurrency
        self.environment = environment
        self.tags = tags
    }

    /// Common memory presets
    public static let small = FunctionConfiguration(memoryMB: 128)
    public static let medium = FunctionConfiguration(memoryMB: 512)
    public static let large = FunctionConfiguration(memoryMB: 1024)
    public static let xlarge = FunctionConfiguration(memoryMB: 2048)
}

// MARK: - Cloud Error

/// Errors that can occur during cloud operations
public enum CloudError: Error, Sendable {
    case deploymentFailed(provider: CloudProviderType, reason: String)
    case invocationFailed(actorID: String, reason: String)
    case actorNotFound(actorID: String, provider: CloudProviderType)
    case authenticationFailed(provider: CloudProviderType, reason: String)
    case quotaExceeded(provider: CloudProviderType, resource: String)
    case regionNotSupported(provider: CloudProviderType, region: String)
    case configurationInvalid(String)
    case networkError(underlying: Error)
    case providerUnavailable(CloudProviderType)
    case timeout(operation: String, duration: Duration)
    case stateStoreFailed(reason: String)
    case registryError(reason: String)
}

extension CloudError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .deploymentFailed(let provider, let reason):
            return "Deployment to \(provider.displayName) failed: \(reason)"
        case .invocationFailed(let actorID, let reason):
            return "Invocation of actor '\(actorID)' failed: \(reason)"
        case .actorNotFound(let actorID, let provider):
            return "Actor '\(actorID)' not found on \(provider.displayName)"
        case .authenticationFailed(let provider, let reason):
            return "Authentication with \(provider.displayName) failed: \(reason)"
        case .quotaExceeded(let provider, let resource):
            return "Quota exceeded on \(provider.displayName): \(resource)"
        case .regionNotSupported(let provider, let region):
            return "Region '\(region)' not supported by \(provider.displayName)"
        case .configurationInvalid(let reason):
            return "Invalid configuration: \(reason)"
        case .networkError(let underlying):
            return "Network error: \(underlying)"
        case .providerUnavailable(let provider):
            return "\(provider.displayName) is currently unavailable"
        case .timeout(let operation, let duration):
            return "Operation '\(operation)' timed out after \(duration)"
        case .stateStoreFailed(let reason):
            return "State store operation failed: \(reason)"
        case .registryError(let reason):
            return "Service registry error: \(reason)"
        }
    }
}
