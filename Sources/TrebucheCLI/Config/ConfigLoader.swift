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

/// Loads and validates Trebuche configuration files
public struct ConfigLoader {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Load configuration from a directory
    /// - Parameter directory: The directory to search for trebuche.yaml
    /// - Returns: Parsed configuration
    public func load(from directory: String) throws -> TrebucheConfig {
        let configPath = findConfigFile(in: directory)
        guard let path = configPath else {
            throw ConfigError.fileNotFound("trebuche.yaml not found in \(directory)")
        }
        return try load(file: path)
    }

    /// Load configuration from a specific file
    /// - Parameter path: Path to the configuration file
    /// - Returns: Parsed configuration
    public func load(file path: String) throws -> TrebucheConfig {
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
    public func parse(yaml: String) throws -> TrebucheConfig {
        do {
            let decoder = YAMLDecoder()
            return try decoder.decode(TrebucheConfig.self, from: yaml)
        } catch {
            throw ConfigError.parseError(error.localizedDescription)
        }
    }

    /// Resolve configuration with environment and discovered actors
    /// - Parameters:
    ///   - config: The base configuration
    ///   - environment: Optional environment name to apply
    ///   - discoveredActors: List of discovered actor names
    /// - Returns: Fully resolved configuration
    public func resolve(
        config: TrebucheConfig,
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
            let actorConfig = config.actors[actorMeta.name]

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

        return ResolvedConfig(
            projectName: config.name,
            provider: config.defaults.provider,
            region: region,
            actors: resolvedActors,
            stateTableName: stateTableName,
            discoveryNamespace: discoveryNamespace
        )
    }

    /// Find the configuration file in a directory
    private func findConfigFile(in directory: String) -> String? {
        let names = ["trebuche.yaml", "trebuche.yml", "Trebuchefile"]
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
          provider: aws
          region: us-east-1
          memory: 512
          timeout: 30

        actors: {}

        environments:
          production:
            region: us-west-2
          staging:
            region: us-east-1

        state:
          type: dynamodb

        discovery:
          type: cloudmap
          namespace: \(projectName)
        """
    }
}
