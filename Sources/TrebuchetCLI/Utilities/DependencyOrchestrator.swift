import Foundation

/// Manages Docker container dependencies for local development
public struct DependencyOrchestrator: Sendable {
    /// A running container managed by the orchestrator
    public struct ManagedContainer: Sendable {
        public let name: String
        public let containerID: String
        public let image: String
        public let ports: [String]
    }

    private let terminal: Terminal
    private let verbose: Bool
    private let projectName: String

    public init(terminal: Terminal, verbose: Bool, projectName: String) {
        self.terminal = terminal
        self.verbose = verbose
        self.projectName = projectName
    }

    // MARK: - Public API

    /// Resolve all dependencies that need to be started, combining auto-detected and explicit ones
    public func resolveDependencies(config: TrebuchetConfig?) -> [DependencyConfig] {
        var dependencies: [DependencyConfig] = []
        var addedNames = Set<String>()

        // Auto-detect dependencies from state store configuration
        if let stateType = config?.state?.type.lowercased() {
            if let dep = autoDetectedDependency(for: stateType), !addedNames.contains(dep.name) {
                dependencies.append(dep)
                addedNames.insert(dep.name)
            }
        }

        // Add explicit dependencies from config
        if let explicit = config?.dependencies {
            for dep in explicit {
                if !addedNames.contains(dep.name) {
                    dependencies.append(dep)
                    addedNames.insert(dep.name)
                }
            }
        }

        return dependencies
    }

    /// Start all resolved dependencies
    /// Returns the list of managed containers that were started
    public func startDependencies(_ dependencies: [DependencyConfig]) async throws -> [ManagedContainer] {
        guard !dependencies.isEmpty else { return [] }

        // Check Docker availability
        guard try await isDockerAvailable() else {
            terminal.print("Docker is not available. Skipping dependency startup.", style: .warning)
            terminal.print("Install Docker to enable automatic dependency management.", style: .dim)
            terminal.print("", style: .info)
            return []
        }

        terminal.print("Starting dependencies...", style: .info)

        var containers: [ManagedContainer] = []

        for dep in dependencies {
            do {
                let container = try await startContainer(dep)
                containers.append(container)
                terminal.print("  ✓ \(dep.name) ready", style: .success)

                // Show connection info
                if let ports = dep.ports, let firstPort = ports.first {
                    let hostPort = firstPort.split(separator: ":").first ?? Substring(firstPort)
                    terminal.print("    └─ localhost:\(hostPort)", style: .dim)
                }
            } catch {
                // Clean up any containers we already started
                terminal.print("  ✗ Failed to start \(dep.name): \(error)", style: .error)
                await stopContainers(containers)
                throw error
            }
        }

        terminal.print("", style: .info)
        return containers
    }

    /// Stop all managed containers
    public func stopContainers(_ containers: [ManagedContainer]) async {
        guard !containers.isEmpty else { return }

        for container in containers.reversed() {
            do {
                try await stopContainer(container)
                terminal.print("  ✓ Stopped \(container.name)", style: .success)
            } catch {
                terminal.print("  ✗ Failed to stop \(container.name): \(error)", style: .warning)
            }
        }
    }

    // MARK: - Auto-Detection

    /// Returns a default DependencyConfig for known state store types
    private func autoDetectedDependency(for stateType: String) -> DependencyConfig? {
        switch stateType {
        case "surrealdb":
            return DependencyConfig(
                name: "surrealdb",
                image: "surrealdb/surrealdb:latest",
                ports: ["8000:8000"],
                command: "start --log info --user root --pass root memory",
                healthcheck: HealthCheckConfig(
                    port: 8000,
                    interval: 2,
                    retries: 15
                )
            )

        case "postgresql":
            return DependencyConfig(
                name: "postgresql",
                image: "postgres:16-alpine",
                ports: ["5432:5432"],
                environment: [
                    "POSTGRES_USER": "trebuchet",
                    "POSTGRES_PASSWORD": "trebuchet",
                    "POSTGRES_DB": "trebuchet_dev"
                ],
                healthcheck: HealthCheckConfig(
                    port: 5432,
                    interval: 2,
                    retries: 15
                )
            )

        case "dynamodb":
            return DependencyConfig(
                name: "localstack",
                image: "localstack/localstack:3.0",
                ports: ["4566:4566"],
                environment: [
                    "SERVICES": "dynamodb,dynamodbstreams,cloudmap,iam,lambda,apigateway",
                    "DEFAULT_REGION": "us-east-1"
                ],
                healthcheck: HealthCheckConfig(
                    url: "http://localhost:4566/_localstack/health",
                    interval: 3,
                    retries: 20
                )
            )

        default:
            return nil
        }
    }

    // MARK: - Container Lifecycle

    private func startContainer(_ dep: DependencyConfig) async throws -> ManagedContainer {
        let containerName = "trebuchet-\(projectName)-\(dep.name)"

        // Check if container already exists and remove it
        try await removeExistingContainer(named: containerName)

        // Check for port conflicts before starting
        if let ports = dep.ports {
            for portMapping in ports {
                let hostPort = String(portMapping.split(separator: ":").first ?? Substring(portMapping))
                if let port = UInt16(hostPort) {
                    let inUse = try await isPortInUse(port)
                    if inUse {
                        throw OrchestratorError.portConflict(
                            port: port,
                            dependency: dep.name
                        )
                    }
                }
            }
        }

        // Build docker run arguments
        var args = ["run", "-d", "--name", containerName]

        // Add port mappings
        if let ports = dep.ports {
            for port in ports {
                args += ["-p", port]
            }
        }

        // Add environment variables
        if let environment = dep.environment {
            for (key, value) in environment.sorted(by: { $0.key < $1.key }) {
                args += ["-e", "\(key)=\(value)"]
            }
        }

        // Add volumes
        if let volumes = dep.volumes {
            for volume in volumes {
                args += ["-v", volume]
            }
        }

        // Add image
        args.append(dep.image)

        // Add command if specified
        if let command = dep.command {
            args += command.split(separator: " ").map(String.init)
        }

        // Pull image first (in case it's not available locally)
        if verbose {
            terminal.print("  Pulling \(dep.image)...", style: .dim)
        }
        try await runDocker(["pull", dep.image])

        // Start the container
        if verbose {
            terminal.print("  Starting container \(containerName)...", style: .dim)
        }
        let containerID = try await runDockerCapture(args)

        let container = ManagedContainer(
            name: containerName,
            containerID: String(containerID.prefix(12)),
            image: dep.image,
            ports: dep.ports ?? []
        )

        // Wait for health check
        if let healthcheck = dep.healthcheck {
            try await waitForHealthy(
                dep: dep,
                healthcheck: healthcheck,
                containerName: containerName
            )
        }

        return container
    }

    private func stopContainer(_ container: ManagedContainer) async throws {
        try await runDocker(["stop", container.name])
        try await runDocker(["rm", "-f", container.name])
    }

    private func removeExistingContainer(named name: String) async throws {
        // Try to remove - ignore errors (container may not exist)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["docker", "rm", "-f", name]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()
        // Ignore exit code - container may not exist
    }

    // MARK: - Health Checks

    private func waitForHealthy(
        dep: DependencyConfig,
        healthcheck: HealthCheckConfig,
        containerName: String
    ) async throws {
        let interval = healthcheck.interval ?? 2
        let maxRetries = healthcheck.retries ?? 15

        if verbose {
            terminal.print("  Waiting for \(dep.name) to be ready...", style: .dim)
        }

        for attempt in 1...maxRetries {
            // Check if container is still running
            let running = try await isContainerRunning(containerName)
            guard running else {
                // Get container logs for debugging
                let logs = try? await getContainerLogs(containerName, lines: 20)
                var message = "Container '\(dep.name)' exited unexpectedly."
                if let logs = logs, !logs.isEmpty {
                    message += "\nLogs:\n\(logs)"
                }
                throw OrchestratorError.containerExited(dependency: dep.name, message: message)
            }

            // Try health check
            let healthy: Bool
            if let url = healthcheck.url {
                healthy = await checkHTTPHealth(url: url)
            } else if let port = healthcheck.port {
                healthy = await checkTCPHealth(port: port)
            } else {
                // No health check configured, assume healthy after start
                healthy = true
            }

            if healthy {
                return
            }

            if verbose {
                terminal.print("  Attempt \(attempt)/\(maxRetries) for \(dep.name)...", style: .dim)
            }

            try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
        }

        throw OrchestratorError.healthCheckFailed(
            dependency: dep.name,
            attempts: maxRetries
        )
    }

    private func checkHTTPHealth(url: String) async -> Bool {
        guard let url = URL(string: url) else { return false }

        // Use curl for HTTP health checks (cross-platform, no Foundation networking issues)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["curl", "-sf", "-o", "/dev/null", "-w", "%{http_code}", url.absoluteString]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func checkTCPHealth(port: UInt16) async -> Bool {
        // Use bash to test TCP connectivity
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["bash", "-c", "echo > /dev/tcp/localhost/\(port)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Docker Helpers

    private func isDockerAvailable() async throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["docker", "version"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        return process.terminationStatus == 0
    }

    private func isPortInUse(_ port: UInt16) async throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["lsof", "-i", ":\(port)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        // lsof exits 0 if port is in use, non-zero if not
        return process.terminationStatus == 0
    }

    private func isContainerRunning(_ name: String) async throws -> Bool {
        let output = try await runDockerCapture(
            ["inspect", "--format", "{{.State.Running}}", name]
        )
        return output.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    private func getContainerLogs(_ name: String, lines: Int) async throws -> String {
        return try await runDockerCapture(["logs", "--tail", "\(lines)", name])
    }

    private func runDocker(_ args: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["docker"] + args

        if !verbose {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw OrchestratorError.dockerCommandFailed(
                command: "docker \(args.joined(separator: " "))",
                exitCode: process.terminationStatus
            )
        }
    }

    private func runDockerCapture(_ args: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["docker"] + args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw OrchestratorError.dockerCommandFailed(
                command: "docker \(args.joined(separator: " "))",
                exitCode: process.terminationStatus
            )
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

// MARK: - Errors

/// Errors that can occur during dependency orchestration
public enum OrchestratorError: Error, CustomStringConvertible {
    case dockerNotAvailable
    case portConflict(port: UInt16, dependency: String)
    case healthCheckFailed(dependency: String, attempts: Int)
    case containerExited(dependency: String, message: String)
    case dockerCommandFailed(command: String, exitCode: Int32)

    public var description: String {
        switch self {
        case .dockerNotAvailable:
            return "Docker is not installed or not running. Install Docker to use automatic dependency management."
        case .portConflict(let port, let dependency):
            return "Port \(port) is already in use (needed by \(dependency)). " +
                   "Stop the conflicting process or change the port in trebuchet.yaml."
        case .healthCheckFailed(let dependency, let attempts):
            return "\(dependency) failed to become ready after \(attempts) attempts. " +
                   "Check if the service starts correctly with 'docker run' manually."
        case .containerExited(let dependency, let message):
            return "\(dependency) container exited unexpectedly. \(message)"
        case .dockerCommandFailed(let command, let exitCode):
            return "Docker command failed (exit \(exitCode)): \(command)"
        }
    }
}
