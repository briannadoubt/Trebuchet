#if os(macOS)
import Foundation

/// Compatibility wrapper that keeps the Compote orchestration API while avoiding a hard CompoteCore dependency.
public struct CompoteOrchestrator: Sendable {
    /// A running container managed by the orchestrator.
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

    /// Resolve dependencies from config/state declarations.
    public func resolveDependencies(config: TrebuchetConfig?) -> [DependencyConfig] {
        guard let config else { return [] }
        let generator = ComposeFileGenerator(config: config)
        let composeFile = generator.generate()

        return composeFile.services.map { name, service in
            DependencyConfig(
                name: name,
                image: service.image ?? "unknown",
                ports: service.ports,
                command: service.command?.asArray,
                environment: service.environment?.asDictionary,
                healthcheck: nil,
                volumes: service.volumes
            )
        }
    }

    /// Start dependencies via Docker orchestration fallback.
    public func startDependencies(_ dependencies: [DependencyConfig]) async throws -> [ManagedContainer] {
        guard !dependencies.isEmpty else { return [] }

        if verbose {
            terminal.print("CompoteCore is decoupled; using Docker dependency orchestrator fallback.", style: .dim)
        }

        let fallback = DependencyOrchestrator(
            terminal: terminal,
            verbose: verbose,
            projectName: projectName
        )
        let containers = try await fallback.startDependencies(dependencies)

        return containers.map { container in
            ManagedContainer(
                name: container.name,
                containerID: container.containerID,
                image: container.image,
                ports: container.ports
            )
        }
    }

    /// Stop all managed containers.
    public func stopContainers(_ containers: [ManagedContainer]) async {
        guard !containers.isEmpty else { return }

        let fallback = DependencyOrchestrator(
            terminal: terminal,
            verbose: verbose,
            projectName: projectName
        )

        let converted = containers.map { container in
            DependencyOrchestrator.ManagedContainer(
                name: container.name,
                containerID: container.containerID,
                image: container.image,
                ports: container.ports
            )
        }

        await fallback.stopContainers(converted)
    }

    func getCurrentConfig() -> TrebuchetConfig? {
        let configLoader = ConfigLoader()
        return try? configLoader.load(from: configDirectory)
    }
}

/// Compatibility errors kept for downstream callers.
public enum CompoteOrchestratorError: Error, CustomStringConvertible {
    case compoteNotAvailable
    case configNotFound

    public var description: String {
        switch self {
        case .compoteNotAvailable:
            return "Compote is not available."
        case .configNotFound:
            return "Could not load trebuchet.yaml configuration."
        }
    }
}
#endif
