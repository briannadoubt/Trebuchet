import Foundation

/// Configuration for a Trebuchet deployment
public struct TrebuchetConfig: Codable, Sendable {
    /// Project name
    public var name: String

    /// Configuration version
    public var version: String

    /// Custom package name for generated servers (optional)
    /// Defaults to "LocalRunner" for dev, "TrebuchetAutoServer" for generated servers
    public var packageName: String?

    /// Custom directory name for generated dev server (optional)
    /// Defaults to ".trebuchet" (hidden). Use a non-hidden name to add to Xcode workspace.
    /// Example: "TrebuchetServer", "DevServer", etc.
    public var outputDirectory: String?

    /// Default settings
    public var defaults: DefaultSettings

    /// Actor-specific configurations
    public var actors: [String: ActorConfig?]

    /// Environment configurations
    public var environments: [String: EnvironmentConfig]?

    /// State storage configuration
    public var state: StateConfig?

    /// Service discovery configuration
    public var discovery: DiscoveryConfig?

    /// Custom development dependencies (Docker containers)
    public var dependencies: [DependencyConfig]?

    /// Custom commands that generate Swift Package Command Plugins
    public var commands: [String: CommandConfig]?

    public init(
        name: String,
        version: String = "1",
        packageName: String? = nil,
        outputDirectory: String? = nil,
        defaults: DefaultSettings = DefaultSettings(),
        actors: [String: ActorConfig?] = [:],
        environments: [String: EnvironmentConfig]? = nil,
        state: StateConfig? = nil,
        discovery: DiscoveryConfig? = nil,
        dependencies: [DependencyConfig]? = nil,
        commands: [String: CommandConfig]? = nil
    ) {
        self.name = name
        self.version = version
        self.packageName = packageName
        self.outputDirectory = outputDirectory
        self.defaults = defaults
        self.actors = actors
        self.environments = environments
        self.state = state
        self.discovery = discovery
        self.dependencies = dependencies
        self.commands = commands
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
        provider: String = "fly",
        region: String = "iad",
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

/// Configuration for a development dependency (Docker container)
public struct DependencyConfig: Codable, Sendable {
    /// Name of the dependency (used for container naming)
    public var name: String

    /// Docker image to use
    public var image: String

    /// Port mappings (host:container format, e.g., "8000:8000")
    public var ports: [String]?

    /// Command arguments to pass to the container (e.g., ["start", "--log", "info"])
    public var command: [String]?

    /// Environment variables for the container
    public var environment: [String: String]?

    /// Health check configuration
    public var healthcheck: HealthCheckConfig?

    /// Docker volumes (host:container format)
    public var volumes: [String]?

    public init(
        name: String,
        image: String,
        ports: [String]? = nil,
        command: [String]? = nil,
        environment: [String: String]? = nil,
        healthcheck: HealthCheckConfig? = nil,
        volumes: [String]? = nil
    ) {
        self.name = name
        self.image = image
        self.ports = ports
        self.command = command
        self.environment = environment
        self.healthcheck = healthcheck
        self.volumes = volumes
    }
}

/// Health check configuration for a dependency
public struct HealthCheckConfig: Codable, Sendable {
    /// URL to check for readiness (HTTP GET, expects 2xx)
    public var url: String?

    /// TCP port to check for readiness (on localhost)
    public var port: UInt16?

    /// Seconds between health check attempts
    public var interval: Int?

    /// Maximum number of retry attempts
    public var retries: Int?

    public init(
        url: String? = nil,
        port: UInt16? = nil,
        interval: Int? = nil,
        retries: Int? = nil
    ) {
        self.url = url
        self.port = port
        self.interval = interval
        self.retries = retries
    }
}

/// Configuration for a custom command (generates a Swift Package Command Plugin)
///
/// The dictionary key in `commands` is the verb used for CLI invocation
/// (e.g. `swift package runLocally`), while `title` is the human-readable name.
public struct CommandConfig: Codable, Sendable {
    /// Human-readable display name for the command
    public var title: String

    /// The shell script to execute when this command is run
    public var script: String

    public init(title: String, script: String) {
        self.title = title
        self.script = script
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
    public let stateType: String?

    public init(
        projectName: String,
        provider: String,
        region: String,
        actors: [ResolvedActorConfig],
        stateTableName: String,
        discoveryNamespace: String,
        stateType: String? = nil
    ) {
        self.projectName = projectName
        self.provider = provider
        self.region = region
        self.actors = actors
        self.stateTableName = stateTableName
        self.discoveryNamespace = discoveryNamespace
        self.stateType = stateType
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
