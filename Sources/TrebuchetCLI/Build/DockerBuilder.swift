import Foundation

/// Result from a build operation
public struct BuildResult: Sendable {
    /// Path to the built binary or archive
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

    /// Build the selected executable for Lambda and package it as `bootstrap` zip.
    /// - Parameters:
    ///   - projectPath: Path to the Swift project
    ///   - config: Resolved deployment configuration
    ///   - executableProduct: Swift executable product name to build
    ///   - verbose: Enable verbose output
    ///   - terminal: Terminal for output
    /// - Returns: Build result with package path and size
    public func build(
        projectPath: String,
        config: ResolvedConfig,
        executableProduct: String? = nil,
        verbose: Bool,
        terminal: Terminal
    ) async throws -> BuildResult {
        let startTime = ContinuousClock.now

        let product = executableProduct ?? config.projectName

        let buildDir = "\(projectPath)/.trebuchet/build"
        try fileManager.createDirectory(atPath: buildDir, withIntermediateDirectories: true)

        let dockerfilePath = "\(buildDir)/Dockerfile"
        let dockerfile = generateDockerfile(productName: product)
        try dockerfile.write(toFile: dockerfilePath, atomically: true, encoding: .utf8)

        guard try await isDockerAvailable() else {
            throw CLIError.buildFailed("Docker is not available. Please install Docker to build for Lambda.")
        }

        let imageName = "trebuchet-build-\(UUID().uuidString.prefix(8))"
        terminal.print("  Building Docker image...", style: .dim)
        try await runDocker(
            ["build", "-t", imageName, "-f", dockerfilePath, projectPath],
            verbose: verbose
        )

        terminal.print("  Extracting binary...", style: .dim)
        let containerName = "trebuchet-extract-\(UUID().uuidString.prefix(8))"

        try await runDocker(
            ["create", "--name", containerName, imageName],
            verbose: verbose
        )

        let binaryPath = "\(buildDir)/\(product)"
        do {
            try await runDocker(
                ["cp", "\(containerName):/app/.build/release/\(product)", binaryPath],
                verbose: verbose
            )

            try await makeExecutable(binaryPath)

            terminal.print("  Creating deployment package...", style: .dim)
            let packagePath = "\(buildDir)/lambda-package.zip"
            try await createLambdaPackage(binaryPath: binaryPath, outputPath: packagePath)

            let packageAttributes = try fileManager.attributesOfItem(atPath: packagePath)
            let packageSize = packageAttributes[.size] as? Int64 ?? 0

            try? await runDocker(["rm", "-f", containerName], verbose: true)
            try? await runDocker(["rmi", imageName], verbose: true)

            let duration = ContinuousClock.now - startTime

            return BuildResult(
                binaryPath: packagePath,
                size: packageSize,
                duration: duration
            )
        } catch {
            try? await runDocker(["rm", "-f", containerName], verbose: true)
            try? await runDocker(["rmi", imageName], verbose: true)
            throw error
        }
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

    private func generateDockerfile(productName: String) -> String {
        """
        # Trebuchet Lambda Build Image
        FROM swift:6.2-amazonlinux2 AS builder

        WORKDIR /app
        COPY . .

        RUN swift build -c release --product \(productName) --static-swift-stdlib -Xlinker -s

        # The built product is available at /app/.build/release/\(productName)
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

    private func makeExecutable(_ path: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+x", path]

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw CLIError.buildFailed("Failed to make binary executable at \(path)")
        }
    }

    private func createLambdaPackage(binaryPath: String, outputPath: String) async throws {
        try? fileManager.removeItem(atPath: outputPath)

        let buildDir = (binaryPath as NSString).deletingLastPathComponent
        let bootstrapPath = "\(buildDir)/bootstrap"
        try? fileManager.removeItem(atPath: bootstrapPath)
        try fileManager.copyItem(atPath: binaryPath, toPath: bootstrapPath)

        defer {
            try? fileManager.removeItem(atPath: bootstrapPath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["zip", "-j", outputPath, bootstrapPath]

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw CLIError.buildFailed("Failed to create Lambda package")
        }
    }
}
