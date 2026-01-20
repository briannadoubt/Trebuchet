import Foundation

/// Configuration for a Trebuche deployment
public struct TrebucheConfig: Codable, Sendable {
    /// Project name
    public var name: String

    /// Configuration version
    public var version: String

    /// Default settings
    public var defaults: DefaultSettings

    /// Actor-specific configurations
    public var actors: [String: ActorConfig]

    /// Environment configurations
    public var environments: [String: EnvironmentConfig]?

    /// State storage configuration
    public var state: StateConfig?

    /// Service discovery configuration
    public var discovery: DiscoveryConfig?

    public init(
        name: String,
        version: String = "1",
        defaults: DefaultSettings = DefaultSettings(),
        actors: [String: ActorConfig] = [:],
        environments: [String: EnvironmentConfig]? = nil,
        state: StateConfig? = nil,
        discovery: DiscoveryConfig? = nil
    ) {
        self.name = name
        self.version = version
        self.defaults = defaults
        self.actors = actors
        self.environments = environments
        self.state = state
        self.discovery = discovery
    }
}

/// Default settings for all actors
public struct DefaultSettings: Codable, Sendable {
    /// Cloud provider to use
    public var provider: String

    /// AWS/GCP region
    public var region: String

    /// Memory allocation in MB
    public var memory: Int

    /// Timeout in seconds
    public var timeout: Int

    public init(
        provider: String = "aws",
        region: String = "us-east-1",
        memory: Int = 512,
        timeout: Int = 30
    ) {
        self.provider = provider
        self.region = region
        self.memory = memory
        self.timeout = timeout
    }
}

/// Configuration for a specific actor
public struct ActorConfig: Codable, Sendable {
    /// Memory allocation in MB
    public var memory: Int?

    /// Timeout in seconds
    public var timeout: Int?

    /// Whether this actor requires external state storage
    public var stateful: Bool?

    /// Whether this actor should run in its own Lambda function
    public var isolated: Bool?

    /// Environment variables
    public var environment: [String: String]?

    public init(
        memory: Int? = nil,
        timeout: Int? = nil,
        stateful: Bool? = nil,
        isolated: Bool? = nil,
        environment: [String: String]? = nil
    ) {
        self.memory = memory
        self.timeout = timeout
        self.stateful = stateful
        self.isolated = isolated
        self.environment = environment
    }
}

/// Environment-specific configuration
public struct EnvironmentConfig: Codable, Sendable {
    /// Region for this environment
    public var region: String?

    /// Memory allocation override
    public var memory: Int?

    /// Additional environment variables
    public var environment: [String: String]?

    public init(
        region: String? = nil,
        memory: Int? = nil,
        environment: [String: String]? = nil
    ) {
        self.region = region
        self.memory = memory
        self.environment = environment
    }
}

/// State storage configuration
public struct StateConfig: Codable, Sendable {
    /// Type of state store (dynamodb, firestore, cosmosdb)
    public var type: String

    /// Table/collection name
    public var tableName: String?

    public init(type: String = "dynamodb", tableName: String? = nil) {
        self.type = type
        self.tableName = tableName
    }
}

/// Service discovery configuration
public struct DiscoveryConfig: Codable, Sendable {
    /// Type of registry (cloudmap, etc.)
    public var type: String

    /// Namespace for actor discovery
    public var namespace: String?

    public init(type: String = "cloudmap", namespace: String? = nil) {
        self.type = type
        self.namespace = namespace
    }
}

// MARK: - Resolved Configuration

/// A fully resolved configuration with all values computed
public struct ResolvedConfig: Sendable {
    public let projectName: String
    public let provider: String
    public let region: String
    public let actors: [ResolvedActorConfig]
    public let stateTableName: String
    public let discoveryNamespace: String

    public init(
        projectName: String,
        provider: String,
        region: String,
        actors: [ResolvedActorConfig],
        stateTableName: String,
        discoveryNamespace: String
    ) {
        self.projectName = projectName
        self.provider = provider
        self.region = region
        self.actors = actors
        self.stateTableName = stateTableName
        self.discoveryNamespace = discoveryNamespace
    }
}

/// Fully resolved actor configuration
public struct ResolvedActorConfig: Sendable {
    public let name: String
    public let memory: Int
    public let timeout: Int
    public let stateful: Bool
    public let isolated: Bool
    public let environment: [String: String]

    public init(
        name: String,
        memory: Int,
        timeout: Int,
        stateful: Bool,
        isolated: Bool,
        environment: [String: String]
    ) {
        self.name = name
        self.memory = memory
        self.timeout = timeout
        self.stateful = stateful
        self.isolated = isolated
        self.environment = environment
    }
}
