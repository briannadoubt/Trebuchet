#if os(macOS)
import Foundation
import CompoteCore
import Logging

/// Wrapper around Compote's Orchestrator to match DependencyOrchestrator interface
public struct CompoteOrchestrator: Sendable {
    /// A running container managed by Compote
    public struct ManagedContainer: Sendable {
        public let name: String
        public let containerID: String
        public let image: String
        public let ports: [String]
    }

    private let terminal: Terminal
    private let verbose: Bool
    private let projectName: String
    private let configDirectory: String

    public init(terminal: Terminal, verbose: Bool, projectName: String, configDirectory: String) {
        self.terminal = terminal
        self.verbose = verbose
        self.projectName = projectName
        self.configDirectory = configDirectory
    }

    // MARK: - Public API

    /// Resolve all dependencies that need to be started
    public func resolveDependencies(config: TrebuchetConfig?) -> [DependencyConfig] {
        // Generate compose file from config
        guard let config = config else { return [] }

        let generator = ComposeFileGenerator(config: config)
        let composeFile = generator.generate()

        // Convert back to DependencyConfig for compatibility
        return composeFile.services.map { name, service in
            DependencyConfig(
                name: name,
                image: service.image ?? "unknown",
                ports: service.ports,
                command: service.command?.asArray,
                environment: service.environment?.asDictionary,
                healthcheck: nil, // Compote handles health checks internally
                volumes: service.volumes
            )
        }
    }

    /// Start all resolved dependencies using Compote
    public func startDependencies(_ dependencies: [DependencyConfig]) async throws -> [ManagedContainer] {
        guard !dependencies.isEmpty else { return [] }

        // Check if Compote is available
        guard isCompoteAvailable() else {
            throw CompoteOrchestratorError.compoteNotAvailable
        }

        terminal.print("Starting dependencies with Compote...", style: .info)

        // Generate compose file
        guard let config = getCurrentConfig() else {
            throw CompoteOrchestratorError.configNotFound
        }

        let generator = ComposeFileGenerator(config: config)
        let composeFile = generator.generate()

        // Create logger
        var logger = Logger(label: "compote")
        logger.logLevel = verbose ? .debug : .info

        // Create orchestrator
        let orchestrator = try Orchestrator(
            composeFile: composeFile,
            projectName: projectName,
            logger: logger
        )

        // Start services
        try await orchestrator.up(detach: true)

        terminal.print("✓ Dependencies started", style: .info)

        // Return managed containers info
        return composeFile.services.map { name, service in
            ManagedContainer(
                name: "\(projectName)-\(name)",
                containerID: name, // Compote manages IDs internally
                image: service.image ?? "unknown",
                ports: service.ports ?? []
            )
        }
    }

    /// Stop all managed containers
    public func stopContainers(_ containers: [ManagedContainer]) async {
        guard !containers.isEmpty else { return }

        do {
            // Create logger
            var logger = Logger(label: "compote")
            logger.logLevel = verbose ? .debug : .info

            // Get current config
            guard let config = getCurrentConfig() else {
                terminal.print("Failed to load config for cleanup", style: .warning)
                return
            }

            // Generate compose file
            let generator = ComposeFileGenerator(config: config)
            let composeFile = generator.generate()

            // Create orchestrator
            let orchestrator = try Orchestrator(
                composeFile: composeFile,
                projectName: projectName,
                logger: logger
            )

            // Stop services
            try await orchestrator.down(removeVolumes: false)

            for container in containers {
                terminal.print("  ✓ Stopped \(container.name)", style: .success)
            }
        } catch {
            terminal.print("  ✗ Failed to stop containers: \(error)", style: .warning)
        }
    }

    // MARK: - Private Helpers

    private func isCompoteAvailable() -> Bool {
        // Check if we're on macOS 15+
        if #available(macOS 15.0, *) {
            return true
        }
        return false
    }

    func getCurrentConfig() -> TrebuchetConfig? {
        let configLoader = ConfigLoader()
        return try? configLoader.load(from: configDirectory)
    }
}

/// Errors specific to Compote orchestration
public enum CompoteOrchestratorError: Error, CustomStringConvertible {
    case compoteNotAvailable
    case configNotFound

    public var description: String {
        switch self {
        case .compoteNotAvailable:
            return "Compote is not available. Requires macOS 15 or later."
        case .configNotFound:
            return "Could not load trebuchet.yaml configuration."
        }
    }
}

// MARK: - Environment Extensions

private extension Environment {
    var asDictionary: [String: String]? {
        switch self {
        case .dictionary(let dict):
            return dict
        case .array(let array):
            // Parse KEY=VALUE format
            var dict: [String: String] = [:]
            for item in array {
                let parts = item.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    dict[String(parts[0])] = String(parts[1])
                }
            }
            return dict
        }
    }
}
#endif
