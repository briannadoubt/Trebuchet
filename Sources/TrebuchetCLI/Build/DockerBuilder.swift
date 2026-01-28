import Foundation

/// Result from a build operation
public struct BuildResult: Sendable {
    /// Path to the built binary
    public let binaryPath: String

    /// Size in bytes
    public let size: Int64

    /// Build duration
    public let duration: Duration

    /// Human-readable size description
    public var sizeDescription: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
}

/// Builds Swift projects for Lambda deployment using Docker
public struct DockerBuilder {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Build the project for Lambda
    /// - Parameters:
    ///   - projectPath: Path to the Swift project
    ///   - config: Resolved configuration
    ///   - verbose: Enable verbose output
    ///   - terminal: Terminal for output
    /// - Returns: Build result with binary path and size
    public func build(
        projectPath: String,
        config: ResolvedConfig,
        verbose: Bool,
        terminal: Terminal
    ) async throws -> BuildResult {
        let startTime = ContinuousClock.now

        // Create build directory
        let buildDir = "\(projectPath)/.trebuchet/build"
        try fileManager.createDirectory(atPath: buildDir, withIntermediateDirectories: true)

        // Generate Dockerfile
        let dockerfilePath = "\(buildDir)/Dockerfile"
        let dockerfile = generateDockerfile(projectName: config.projectName)
        try dockerfile.write(toFile: dockerfilePath, atomically: true, encoding: .utf8)

        // Generate bootstrap
        let bootstrapPath = "\(buildDir)/bootstrap.swift"
        let bootstrap = generateBootstrap(config: config)
        try bootstrap.write(toFile: bootstrapPath, atomically: true, encoding: .utf8)

        // Check if Docker is available
        guard try await isDockerAvailable() else {
            throw CLIError.buildFailed("Docker is not available. Please install Docker to build for Lambda.")
        }

        // Build Docker image
        terminal.print("  Building Docker image...", style: .dim)
        try await runDocker(
            ["build", "-t", "trebuchet-build-\(config.projectName)", "-f", dockerfilePath, projectPath],
            verbose: verbose
        )

        // Extract binary from container
        terminal.print("  Extracting binary...", style: .dim)
        let containerName = "trebuchet-extract-\(UUID().uuidString.prefix(8))"

        // Create container
        try await runDocker(
            ["create", "--name", containerName, "trebuchet-build-\(config.projectName)"],
            verbose: verbose
        )

        // Copy binary out
        let outputPath = "\(buildDir)/bootstrap"
        try await runDocker(
            ["cp", "\(containerName):/app/.build/release/\(config.projectName)", outputPath],
            verbose: verbose
        )

        // Remove container
        try await runDocker(["rm", containerName], verbose: verbose)

        // Get binary size
        let attributes = try fileManager.attributesOfItem(atPath: outputPath)
        let size = attributes[.size] as? Int64 ?? 0

        // Create Lambda package
        terminal.print("  Creating deployment package...", style: .dim)
        let packagePath = "\(buildDir)/lambda-package.zip"
        try await createLambdaPackage(binaryPath: outputPath, outputPath: packagePath)

        let packageAttributes = try fileManager.attributesOfItem(atPath: packagePath)
        let packageSize = packageAttributes[.size] as? Int64 ?? 0

        let duration = ContinuousClock.now - startTime

        return BuildResult(
            binaryPath: packagePath,
            size: packageSize,
            duration: duration
        )
    }

    /// Build locally (no Docker) for development
    public func buildLocal(
        projectPath: String,
        verbose: Bool
    ) async throws -> BuildResult {
        let startTime = ContinuousClock.now

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", "build", "-c", "release"]
        process.currentDirectoryURL = URL(fileURLWithPath: projectPath)

        if !verbose {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw CLIError.buildFailed("Swift build failed with status \(process.terminationStatus)")
        }

        let binaryPath = "\(projectPath)/.build/release"
        let duration = ContinuousClock.now - startTime

        return BuildResult(
            binaryPath: binaryPath,
            size: 0,
            duration: duration
        )
    }

    // MARK: - Private

    private func generateDockerfile(projectName: String) -> String {
        """
        # Trebuchet Lambda Build Image
        FROM swift:6.0-amazonlinux2 AS builder

        WORKDIR /app

        # Copy package files first for caching
        COPY Package.swift Package.resolved* ./

        # Copy source files
        COPY Sources/ Sources/
        COPY Tests/ Tests/

        # Build for release
        RUN swift build -c release \\
            --static-swift-stdlib \\
            -Xlinker -s

        # Copy the bootstrap generator
        COPY .trebuchet/build/bootstrap.swift /app/

        # The output will be copied out of the container
        """
    }

    private func generateBootstrap(config: ResolvedConfig) -> String {
        // Generate actor registrations
        var registrations = ""
        for actor in config.actors {
            registrations += """
                    // Register \(actor.name)
                    let \(actor.name.lowercased()) = \(actor.name)(actorSystem: gateway.system)
                    try await gateway.expose(\(actor.name.lowercased()), as: "\(actor.name.lowercased())")

            """
        }

        return """
        // Auto-generated Lambda bootstrap for \(config.projectName)
        // Generated by trebuchet CLI

        import Foundation
        import Trebuchet
        import TrebuchetCloud
        import TrebuchetAWS
        import AWSLambdaRuntime
        import AWSLambdaEvents

        @main
        struct ActorLambdaHandler: LambdaHandler {
            typealias Event = APIGatewayV2Request
            typealias Output = APIGatewayV2Response

            let gateway: CloudGateway

            init(context: LambdaInitializationContext) async throws {
                // Configure state store
                let stateStore = DynamoDBStateStore(
                    tableName: ProcessInfo.processInfo.environment["STATE_TABLE"] ?? "\(config.stateTableName)"
                )

                // Configure service registry
                let registry = CloudMapRegistry(
                    namespace: ProcessInfo.processInfo.environment["NAMESPACE"] ?? "\(config.discoveryNamespace)"
                )

                // Initialize gateway
                gateway = CloudGateway(configuration: .init(
                    stateStore: stateStore,
                    registry: registry
                ))

        \(registrations)
                context.logger.info("Lambda handler initialized with \\(gateway) actors")
            }

            func handle(_ event: APIGatewayV2Request, context: LambdaContext) async throws -> APIGatewayV2Response {
                do {
                    // Parse invocation envelope from request body
                    guard let body = event.body,
                          let data = body.data(using: .utf8) else {
                        return APIGatewayV2Response(
                            statusCode: .badRequest,
                            body: "{\\"error\\": \\"Missing request body\\"}"
                        )
                    }

                    let envelope = try JSONDecoder().decode(InvocationEnvelope.self, from: data)

                    // Create response handler
                    let response = await gateway.handleInvocation(envelope)

                    let responseData = try JSONEncoder().encode(response)
                    let responseBody = String(data: responseData, encoding: .utf8) ?? "{}"

                    return APIGatewayV2Response(
                        statusCode: response.isSuccess ? .ok : .internalServerError,
                        headers: ["Content-Type": "application/json"],
                        body: responseBody
                    )
                } catch {
                    return APIGatewayV2Response(
                        statusCode: .internalServerError,
                        body: "{\\"error\\": \\"\\(error)\\"}"
                    )
                }
            }
        }

        // Extension to handle invocations
        extension CloudGateway {
            func handleInvocation(_ envelope: InvocationEnvelope) async -> ResponseEnvelope {
                // This would use the internal message handling
                // For now, return a placeholder
                return ResponseEnvelope.failure(
                    callID: envelope.callID,
                    error: "Not implemented"
                )
            }
        }
        """
    }

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

    private func runDocker(_ args: [String], verbose: Bool) async throws {
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
            throw CLIError.buildFailed("Docker command failed: docker \(args.joined(separator: " "))")
        }
    }

    private func createLambdaPackage(binaryPath: String, outputPath: String) async throws {
        // Remove existing package
        try? fileManager.removeItem(atPath: outputPath)

        // Create zip with bootstrap as the binary name (Lambda requirement)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["zip", "-j", outputPath, binaryPath]

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw CLIError.buildFailed("Failed to create Lambda package")
        }
    }
}
