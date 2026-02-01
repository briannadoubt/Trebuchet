import Foundation
import Yams

/// Errors that can occur during configuration loading
public enum ConfigError: Error, CustomStringConvertible {
    case fileNotFound(String)
    case parseError(String)
    case validationError(String)

    public var description: String {
        switch self {
        case .fileNotFound(let path):
            return "Configuration file not found: \(path)"
        case .parseError(let message):
            return "Failed to parse configuration: \(message)"
        case .validationError(let message):
            return "Configuration validation failed: \(message)"
        }
    }
}

/// Loads and validates Trebuchet configuration files
public struct ConfigLoader {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Load configuration from a directory
    /// - Parameter directory: The directory to search for trebuchet.yaml
    /// - Returns: Parsed configuration
    public func load(from directory: String) throws -> TrebuchetConfig {
        let configPath = findConfigFile(in: directory)
        guard let path = configPath else {
            throw ConfigError.fileNotFound("trebuchet.yaml not found in \(directory)")
        }
        return try load(file: path)
    }

    /// Load configuration from a specific file
    /// - Parameter path: Path to the configuration file
    /// - Returns: Parsed configuration
    public func load(file path: String) throws -> TrebuchetConfig {
        guard fileManager.fileExists(atPath: path) else {
            throw ConfigError.fileNotFound(path)
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let contents = String(data: data, encoding: .utf8) else {
            throw ConfigError.parseError("Failed to read file as UTF-8")
        }

        return try parse(yaml: contents)
    }

    /// Parse YAML configuration string
    /// - Parameter yaml: The YAML string to parse
    /// - Returns: Parsed configuration
    public func parse(yaml: String) throws -> TrebuchetConfig {
        do {
            let decoder = YAMLDecoder()
            let config = try decoder.decode(TrebuchetConfig.self, from: yaml)
            try validate(config)
            return config
        } catch let error as ConfigError {
            throw error
        } catch {
            throw ConfigError.parseError(error.localizedDescription)
        }
    }

    /// Validate configuration for correctness and compatibility
    /// - Parameter config: The configuration to validate
    /// - Throws: ConfigError.validationError if validation fails
    public func validate(_ config: TrebuchetConfig) throws {
        // Validate provider is implemented
        let implementedProviders = ["aws", "fly", "local"]
        let provider = config.defaults.provider.lowercased()

        guard implementedProviders.contains(provider) else {
            let unimplementedProviders = ["gcp", "azure", "kubernetes"]
            if unimplementedProviders.contains(provider) {
                throw ConfigError.validationError(
                    "Provider '\(provider)' is not yet implemented. " +
                    "Available providers: \(implementedProviders.joined(separator: ", ")). " +
                    "GCP, Azure, and Kubernetes support is planned for a future release."
                )
            } else {
                throw ConfigError.validationError(
                    "Unknown provider '\(provider)'. " +
                    "Available providers: \(implementedProviders.joined(separator: ", "))"
                )
            }
        }

        // Validate provider-specific requirements
        try validateProviderRequirements(provider: provider, config: config)

        // Validate state store compatibility
        if let stateConfig = config.state {
            try validateStateStore(type: stateConfig.type, provider: provider)
        }

        // Validate discovery mechanism compatibility
        if let discoveryConfig = config.discovery {
            try validateDiscovery(type: discoveryConfig.type, provider: provider)
        }

        // Validate resource limits
        try validateResourceLimits(config: config)
    }

    /// Validate provider-specific requirements
    private func validateProviderRequirements(provider: String, config: TrebuchetConfig) throws {
        switch provider {
        case "aws":
            // AWS requires a valid region
            guard !config.defaults.region.isEmpty else {
                throw ConfigError.validationError("AWS provider requires a region to be specified")
            }

            // Validate region format (basic check for AWS region format)
            let regionPattern = "^[a-z]{2}-[a-z]+-\\d{1}$"
            if let regex = try? NSRegularExpression(pattern: regionPattern),
               regex.firstMatch(in: config.defaults.region, range: NSRange(location: 0, length: config.defaults.region.utf16.count)) == nil {
                // Not a fatal error, just a warning pattern
                // AWS regions should be like: us-east-1, eu-west-2, etc.
            }

        case "fly":
            // Fly.io requires a region (3-letter code like iad, lax, etc.)
            guard !config.defaults.region.isEmpty else {
                throw ConfigError.validationError("Fly provider requires a region to be specified")
            }

        case "local":
            // Local provider doesn't have strict requirements
            break

        default:
            break
        }
    }

    /// Validate state store type is compatible with provider
    private func validateStateStore(type: String, provider: String) throws {
        let stateType = type.lowercased()

        switch (provider, stateType) {
        case ("aws", "dynamodb"):
            // Valid combination
            break

        case ("aws", "firestore"):
            throw ConfigError.validationError(
                "State store 'firestore' is not compatible with AWS provider. " +
                "Use 'dynamodb' for AWS deployments."
            )

        case ("aws", "cosmosdb"):
            throw ConfigError.validationError(
                "State store 'cosmosdb' is not compatible with AWS provider. " +
                "Use 'dynamodb' for AWS deployments."
            )

        case ("gcp", "dynamodb"):
            throw ConfigError.validationError(
                "State store 'dynamodb' is not compatible with GCP provider. " +
                "Use 'firestore' for GCP deployments."
            )

        case ("azure", "dynamodb"):
            throw ConfigError.validationError(
                "State store 'dynamodb' is not compatible with Azure provider. " +
                "Use 'cosmosdb' for Azure deployments."
            )

        case ("fly", "postgresql"), ("local", "postgresql"):
            // PostgreSQL is compatible with Fly and local
            break

        case ("fly", _), ("local", _):
            // Fly and local can use most state stores
            break

        default:
            // Unknown combination - allow but could warn
            break
        }
    }

    /// Validate discovery mechanism is compatible with provider
    private func validateDiscovery(type: String, provider: String) throws {
        let discoveryType = type.lowercased()

        switch (provider, discoveryType) {
        case ("aws", "cloudmap"):
            // Valid combination
            break

        case ("aws", "consul"), ("aws", "etcd"):
            // Not AWS-native but could work
            break

        case ("gcp", "cloudmap"):
            throw ConfigError.validationError(
                "Discovery type 'cloudmap' is AWS-specific. " +
                "Use 'servicedirectory' for GCP deployments."
            )

        case ("azure", "cloudmap"):
            throw ConfigError.validationError(
                "Discovery type 'cloudmap' is AWS-specific. " +
                "Use 'servicefabric' for Azure deployments."
            )

        case ("fly", "dns"), ("local", "dns"):
            // DNS-based discovery works for Fly and local
            break

        case ("fly", _), ("local", _):
            // Fly and local are flexible
            break

        default:
            // Unknown combination - allow but could warn
            break
        }
    }

    /// Validate resource limits are reasonable
    private func validateResourceLimits(config: TrebuchetConfig) throws {
        // Validate default memory
        guard config.defaults.memory >= 128 else {
            throw ConfigError.validationError(
                "Memory must be at least 128 MB (got: \(config.defaults.memory) MB)"
            )
        }

        guard config.defaults.memory <= 10240 else {
            throw ConfigError.validationError(
                "Memory must be at most 10240 MB (10 GB) (got: \(config.defaults.memory) MB)"
            )
        }

        // Validate default timeout
        guard config.defaults.timeout >= 1 else {
            throw ConfigError.validationError(
                "Timeout must be at least 1 second (got: \(config.defaults.timeout) seconds)"
            )
        }

        guard config.defaults.timeout <= 900 else {
            throw ConfigError.validationError(
                "Timeout must be at most 900 seconds (15 minutes) (got: \(config.defaults.timeout) seconds)"
            )
        }

        // Validate actor-specific overrides
        for (actorName, actorConfig) in config.actors {
            guard let actorConfig = actorConfig else { continue }

            if let memory = actorConfig.memory {
                guard memory >= 128 && memory <= 10240 else {
                    throw ConfigError.validationError(
                        "Actor '\(actorName)': memory must be between 128 MB and 10240 MB (got: \(memory) MB)"
                    )
                }
            }

            if let timeout = actorConfig.timeout {
                guard timeout >= 1 && timeout <= 900 else {
                    throw ConfigError.validationError(
                        "Actor '\(actorName)': timeout must be between 1 and 900 seconds (got: \(timeout) seconds)"
                    )
                }
            }
        }
    }

    /// Resolve configuration with environment and discovered actors
    /// - Parameters:
    ///   - config: The base configuration
    ///   - environment: Optional environment name to apply
    ///   - discoveredActors: List of discovered actor names
    /// - Returns: Fully resolved configuration
    public func resolve(
        config: TrebuchetConfig,
        environment: String? = nil,
        discoveredActors: [ActorMetadata]
    ) throws -> ResolvedConfig {
        var region = config.defaults.region
        var envVars: [String: String] = [:]

        // Apply environment overrides
        if let envName = environment, let envConfig = config.environments?[envName] {
            if let envRegion = envConfig.region {
                region = envRegion
            }
            if let envEnvVars = envConfig.environment {
                envVars.merge(envEnvVars) { _, new in new }
            }
        }

        // Resolve each actor
        var resolvedActors: [ResolvedActorConfig] = []
        for actorMeta in discoveredActors {
            // Handle optional ActorConfig (nil when YAML has only comments)
            let actorConfig = config.actors[actorMeta.name] ?? nil

            var actorEnv = envVars
            if let actorEnvVars = actorConfig?.environment {
                actorEnv.merge(actorEnvVars) { _, new in new }
            }

            let resolved = ResolvedActorConfig(
                name: actorMeta.name,
                memory: actorConfig?.memory ?? config.defaults.memory,
                timeout: actorConfig?.timeout ?? config.defaults.timeout,
                stateful: actorConfig?.stateful ?? false,
                isolated: actorConfig?.isolated ?? false,
                environment: actorEnv
            )
            resolvedActors.append(resolved)
        }

        // Determine state table name
        let stateTableName = config.state?.tableName ?? "\(config.name)-actor-state"

        // Determine discovery namespace
        let discoveryNamespace = config.discovery?.namespace ?? config.name

        // Get state type
        let stateType = config.state?.type

        return ResolvedConfig(
            projectName: config.name,
            provider: config.defaults.provider,
            region: region,
            actors: resolvedActors,
            stateTableName: stateTableName,
            discoveryNamespace: discoveryNamespace,
            stateType: stateType
        )
    }

    /// Find the configuration file in a directory
    private func findConfigFile(in directory: String) -> String? {
        let names = ["trebuchet.yaml", "trebuchet.yml", "Trebuchetfile"]
        for name in names {
            let path = (directory as NSString).appendingPathComponent(name)
            if fileManager.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// Generate a default configuration file
    public static func generateDefault(projectName: String) -> String {
        """
        name: \(projectName)
        version: "1"

        defaults:
          provider: fly
          region: iad
          memory: 512
          timeout: 30

        actors: {}  # Add your actors here, e.g., MyActor: {}

        environments:
          production:
            region: lax
          staging:
            region: iad

        state:
          type: postgresql

        discovery:
          type: dns
          namespace: \(projectName)

        commands:
          "Run Locally":
            script: trebuchet dev
        """
    }
}
