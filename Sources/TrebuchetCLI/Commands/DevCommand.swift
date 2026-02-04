import ArgumentParser
import Foundation

public struct DevCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "dev",
        abstract: "Run actors locally for development"
    )

    @Option(name: .shortAndLong, help: "Port to listen on")
    public var port: UInt16 = 8080

    @Option(name: .shortAndLong, help: "Host to bind to")
    public var host: String = "localhost"

    @Flag(name: .shortAndLong, help: "Enable verbose output")
    public var verbose: Bool = false

    @Option(name: .long, help: "Path to local Trebuchet for development (e.g., ~/dev/Trebuchet)")
    public var local: String?

    @Flag(name: .long, help: "Skip automatic dependency management (Docker containers)")
    public var noDeps: Bool = false

    @Option(name: .long, help: "Container runtime to use (auto, compote, docker)")
    public var runtime: String = "auto"

    public init() {}

    public mutating func run() async throws {
        let terminal = Terminal()
        let cwd = FileManager.default.currentDirectoryPath

        terminal.print("")
        terminal.print("Starting local development server...", style: .header)
        terminal.print("")

        // Check if port is already in use
        let portCheckProcess = Process()
        portCheckProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        portCheckProcess.arguments = ["lsof", "-i", ":\(port)"]

        let pipe = Pipe()
        portCheckProcess.standardOutput = pipe
        portCheckProcess.standardError = FileHandle.nullDevice

        try portCheckProcess.run()
        portCheckProcess.waitUntilExit()

        if portCheckProcess.terminationStatus == 0 {
            // Port is in use
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            terminal.print("Error: Port \(port) is already in use.", style: .error)
            terminal.print("")
            terminal.print("Process using the port:", style: .info)
            terminal.print(output, style: .dim)
            terminal.print("")
            terminal.print("To review the process:", style: .info)
            terminal.print("  lsof -i:\(port)", style: .dim)
            terminal.print("")
            terminal.print("To kill the process and try again:", style: .info)
            terminal.print("  lsof -ti:\(port) | xargs kill -9", style: .dim)
            terminal.print("")

            throw ExitCode.failure
        }

        // Try to load config
        let configLoader = ConfigLoader()
        let config: TrebuchetConfig?
        do {
            config = try configLoader.load(from: cwd)
            if verbose {
                terminal.print("✓ Loaded trebuchet.yaml", style: .dim)
            }
        } catch {
            config = nil
            if verbose {
                terminal.print("No trebuchet.yaml found: \(error)", style: .dim)
            }
        }

        // Get package name from config, or use default
        let packageName = config?.packageName ?? "LocalRunner"

        // Get output directory from config, or use default
        let outputDirectory = config?.outputDirectory ?? ".trebuchet"

        // Discover all actors
        terminal.print("Discovering actors in \(cwd)...", style: .dim)
        let discovery = ActorDiscovery()
        let allActors: [ActorMetadata]
        do {
            allActors = try discovery.discover(in: cwd)
            terminal.print("Found \(allActors.count) actors", style: .dim)
        } catch {
            terminal.print("Error during discovery: \(error)", style: .error)
            throw error
        }

        if allActors.isEmpty {
            terminal.print("No distributed actors found.", style: .warning)
            throw ExitCode.failure
        }

        // Filter actors based on config if available
        let actors: [ActorMetadata]
        if let config = config, !config.actors.isEmpty {
            let configuredActorNames = Set(config.actors.keys)
            actors = allActors.filter { configuredActorNames.contains($0.name) }

            if actors.isEmpty {
                terminal.print("No actors from trebuchet.yaml found in project.", style: .warning)
                terminal.print("Configured actors: \(configuredActorNames.joined(separator: ", "))", style: .dim)
                terminal.print("Available actors: \(allActors.map { $0.name }.joined(separator: ", "))", style: .dim)
                throw ExitCode.failure
            }

            terminal.print("Using actors from trebuchet.yaml:", style: .info)
        } else {
            actors = allActors
            if config == nil {
                terminal.print("No trebuchet.yaml found, using all discovered actors:", style: .info)
            } else {
                terminal.print("No actors configured in trebuchet.yaml, using all discovered actors:", style: .info)
            }
        }

        for actor in actors {
            terminal.print("  • \(actor.name)", style: .dim)
        }
        terminal.print("")

        // Start dependencies if needed
        enum ContainerRuntime {
            case compote(CompoteOrchestrator)
            case docker(DependencyOrchestrator)
        }

        // Determine which runtime to use
        let containerRuntime: ContainerRuntime
        let runtimeProjectName = config?.name ?? "trebuchet"

        switch runtime.lowercased() {
        case "compote":
            // Force Compote
            containerRuntime = .compote(CompoteOrchestrator(
                terminal: terminal,
                verbose: verbose,
                projectName: runtimeProjectName
            ))
            if verbose {
                terminal.print("Using Compote runtime (forced)", style: .dim)
            }

        case "docker":
            // Force Docker
            containerRuntime = .docker(DependencyOrchestrator(
                terminal: terminal,
                verbose: verbose,
                projectName: runtimeProjectName
            ))
            if verbose {
                terminal.print("Using Docker runtime (forced)", style: .dim)
            }

        default: // "auto"
            // Try Compote first, fallback to Docker
            if #available(macOS 15.0, *) {
                containerRuntime = .compote(CompoteOrchestrator(
                    terminal: terminal,
                    verbose: verbose,
                    projectName: runtimeProjectName
                ))
                if verbose {
                    terminal.print("Using Compote runtime (macOS 15+)", style: .dim)
                }
            } else {
                containerRuntime = .docker(DependencyOrchestrator(
                    terminal: terminal,
                    verbose: verbose,
                    projectName: runtimeProjectName
                ))
                if verbose {
                    terminal.print("Using Docker runtime (macOS < 15)", style: .dim)
                }
            }
        }

        var managedContainers: [(name: String, containerID: String, image: String, ports: [String])] = []
        if !noDeps {
            // Resolve and start dependencies
            let dependencies: [DependencyConfig]
            switch containerRuntime {
            case .compote(let orch):
                dependencies = orch.resolveDependencies(config: config)
            case .docker(let orch):
                dependencies = orch.resolveDependencies(config: config)
            }

            if !dependencies.isEmpty {
                terminal.print("Analyzing dependencies...", style: .dim)
                if let stateType = config?.state?.type {
                    terminal.print("  Detected state store: \(stateType)", style: .dim)
                }
                if let deps = config?.dependencies, !deps.isEmpty {
                    terminal.print("  Custom dependencies: \(deps.map(\.name).joined(separator: ", "))", style: .dim)
                }
                terminal.print("")

                do {
                    switch containerRuntime {
                    case .compote(let orch):
                        let containers = try await orch.startDependencies(dependencies)
                        managedContainers = containers.map { ($0.name, $0.containerID, $0.image, $0.ports) }
                    case .docker(let orch):
                        let containers = try await orch.startDependencies(dependencies)
                        managedContainers = containers.map { ($0.name, $0.containerID, $0.image, $0.ports) }
                    }
                } catch {
                    terminal.print("Failed to start dependencies: \(error)", style: .error)
                    terminal.print("Use --no-deps to skip dependency management.", style: .dim)
                    terminal.print("")
                    throw ExitCode.failure
                }
            }
        }

        // Get project and module names
        let projectName = try getProjectName(from: cwd, terminal: terminal)
        let parentPackageName = try getParentPackageName(from: cwd) ?? projectName
        let moduleName = inferModuleName(from: actors, projectName: projectName)

        // Detect if parent is an Xcode project (vs Swift Package)
        let isXcodeProject = detectXcodeProject(in: cwd)

        // Generate and run local bootstrap
        if !isXcodeProject {
            terminal.print("Building project...", style: .dim)
        } else {
            terminal.print("Detected Xcode project, will copy actor sources...", style: .dim)
        }

        // Only build if it's a Swift Package
        if !isXcodeProject {
            let buildProcess = Process()
            buildProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            buildProcess.arguments = ["swift", "build"]
            buildProcess.currentDirectoryURL = URL(fileURLWithPath: cwd)

            let outputPipe = Pipe()
            let errorPipe = Pipe()

            if verbose {
                buildProcess.standardOutput = FileHandle.standardOutput
                buildProcess.standardError = FileHandle.standardError
            } else {
                buildProcess.standardOutput = outputPipe
                buildProcess.standardError = errorPipe
            }

            try buildProcess.run()

            // Wait with timeout to prevent hanging indefinitely
            let buildTimeout: TimeInterval = 300 // 5 minutes
            let timedOut = try await withThrowingTaskGroup(of: Bool.self) { group in
                // Task to wait for process completion
                group.addTask {
                    await Task.detached {
                        buildProcess.waitUntilExit()
                    }.value
                    return false
                }

                // Timeout task
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(buildTimeout * 1_000_000_000))
                    return true
                }

                // Return result of whichever completes first
                let result = try await group.next() ?? false
                group.cancelAll()
                return result
            }

            if timedOut {
                buildProcess.terminate()
                terminal.print("")
                terminal.print("Project build timed out after \(Int(buildTimeout)) seconds", style: .error)
                terminal.print("The build process may be hanging. Try:", style: .dim)
                terminal.print("  • Running with --verbose to see build progress", style: .dim)
                terminal.print("  • Checking for build errors in your project", style: .dim)
                terminal.print("  • Running 'swift build' directly to diagnose the issue", style: .dim)
                terminal.print("")
                // Stop containers based on runtime
                switch containerRuntime {
                case .compote(let orch):
                    let containers = managedContainers.map { CompoteOrchestrator.ManagedContainer(name: $0.name, containerID: $0.containerID, image: $0.image, ports: $0.ports) }
                    await orch.stopContainers(containers)
                case .docker(let orch):
                    let containers = managedContainers.map { DependencyOrchestrator.ManagedContainer(name: $0.name, containerID: $0.containerID, image: $0.image, ports: $0.ports) }
                    await orch.stopContainers(containers)
                }
                throw ExitCode.failure
            }

            guard buildProcess.terminationStatus == 0 else {
                terminal.print("")
                terminal.print("Project build failed:", style: .error)
                terminal.print("")

                // Show the captured error output
                if !verbose {
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    if let errorOutput = String(data: errorData, encoding: .utf8), !errorOutput.isEmpty {
                        print(errorOutput)
                    }

                    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    if let output = String(data: outputData, encoding: .utf8), !output.isEmpty {
                        print(output)
                    }
                }

                // Stop containers based on runtime
                switch containerRuntime {
                case .compote(let orch):
                    let containers = managedContainers.map { CompoteOrchestrator.ManagedContainer(name: $0.name, containerID: $0.containerID, image: $0.image, ports: $0.ports) }
                    await orch.stopContainers(containers)
                case .docker(let orch):
                    let containers = managedContainers.map { DependencyOrchestrator.ManagedContainer(name: $0.name, containerID: $0.containerID, image: $0.image, ports: $0.ports) }
                    await orch.stopContainers(containers)
                }
                throw ExitCode.failure
            }

            terminal.print("✓ Build succeeded", style: .success)
            terminal.print("")
        }

        // Generate development runner package
        terminal.print("Generating development server...", style: .dim)

        let devPath = "\(cwd)/\(outputDirectory)"

        // Clean output directory to avoid stale dependency issues
        // TODO: Optimize to only clean sources once dependency resolution is stable
        if FileManager.default.fileExists(atPath: devPath) {
            if verbose {
                terminal.print("  Cleaning old \(outputDirectory) directory...", style: .dim)
            }
            try FileManager.default.removeItem(atPath: devPath)
        }

        try FileManager.default.createDirectory(
            atPath: devPath,
            withIntermediateDirectories: true
        )

        // Generate Package.swift
        let packageManifest: String
        let actualModuleName: String

        if isXcodeProject {
            // For Xcode projects, copy actor sources and don't depend on parent
            // Use the project's actual module name to ensure type identity matches between client and server
            packageManifest = generateXcodeProjectPackageManifest(
                packageName: packageName,
                moduleName: moduleName,
                localTrebuchetPath: local,
                config: config
            )
            actualModuleName = moduleName

            // Copy actor source files into .trebuchet/Sources/{ModuleName}/
            let actorSourcesPath = "\(devPath)/Sources/\(moduleName)"
            try FileManager.default.createDirectory(
                atPath: actorSourcesPath,
                withIntermediateDirectories: true
            )

            try copyActorSources(actors: actors, to: actorSourcesPath, terminal: terminal, verbose: verbose)
        } else {
            // For Swift Packages, use existing approach
            packageManifest = generatePackageManifest(
                packageName: packageName,
                projectName: moduleName,
                parentPackageName: parentPackageName,
                localTrebuchetPath: local,
                config: config
            )
            actualModuleName = moduleName
        }

        try packageManifest.write(
            toFile: "\(devPath)/Package.swift",
            atomically: true,
            encoding: .utf8
        )

        // Generate main.swift
        let sourcesPath = "\(devPath)/Sources/\(packageName)"
        try FileManager.default.createDirectory(
            atPath: sourcesPath,
            withIntermediateDirectories: true
        )

        let mainScript = generateLocalRunner(
            actors: actors,
            moduleName: actualModuleName,
            host: host,
            port: port,
            config: config
        )
        try mainScript.write(
            toFile: "\(sourcesPath)/main.swift",
            atomically: true,
            encoding: .utf8
        )

        terminal.print("✓ Runner generated", style: .success)
        terminal.print("")

        // Build first (capture output to show only on error)
        if !verbose {
            terminal.print("Building server...", style: .dim)
        }

        let buildProcess = Process()
        buildProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        buildProcess.arguments = ["swift", "build", "--package-path", devPath]
        buildProcess.currentDirectoryURL = URL(fileURLWithPath: cwd)

        let outputPipe = Pipe()
        let errorPipe = Pipe()

        if verbose {
            buildProcess.standardOutput = FileHandle.standardOutput
            buildProcess.standardError = FileHandle.standardError
        } else {
            buildProcess.standardOutput = outputPipe
            buildProcess.standardError = errorPipe
        }

        try buildProcess.run()

        // Wait with timeout to prevent hanging indefinitely
        let serverBuildTimeout: TimeInterval = 300 // 5 minutes
        let timedOut = try await withThrowingTaskGroup(of: Bool.self) { group in
            // Task to wait for process completion
            group.addTask {
                await Task.detached {
                    buildProcess.waitUntilExit()
                }.value
                return false
            }

            // Timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(serverBuildTimeout * 1_000_000_000))
                return true
            }

            // Return result of whichever completes first
            let result = try await group.next() ?? false
            group.cancelAll()
            return result
        }

        if timedOut {
            buildProcess.terminate()
            terminal.print("")
            terminal.print("Server build timed out after \(Int(serverBuildTimeout)) seconds", style: .error)
            terminal.print("The build process may be hanging. Try:", style: .dim)
            terminal.print("  • Running with --verbose to see build progress", style: .dim)
            terminal.print("  • Checking the generated package at: \(devPath)", style: .dim)
            terminal.print("  • Running 'swift build --package-path \(devPath)' directly", style: .dim)
            terminal.print("")
            // Stop containers based on runtime
            switch containerRuntime {
            case .compote(let orch):
                let containers = managedContainers.map { CompoteOrchestrator.ManagedContainer(name: $0.name, containerID: $0.containerID, image: $0.image, ports: $0.ports) }
                await orch.stopContainers(containers)
            case .docker(let orch):
                let containers = managedContainers.map { DependencyOrchestrator.ManagedContainer(name: $0.name, containerID: $0.containerID, image: $0.image, ports: $0.ports) }
                await orch.stopContainers(containers)
            }
            throw ExitCode.failure
        }

        guard buildProcess.terminationStatus == 0 else {
            terminal.print("")
            terminal.print("Server build failed:", style: .error)
            terminal.print("")

            // Show the captured error output
            if !verbose {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                if let errorOutput = String(data: errorData, encoding: .utf8), !errorOutput.isEmpty {
                    print(errorOutput)
                }

                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: outputData, encoding: .utf8), !output.isEmpty {
                    print(output)
                }
            }

            // Stop containers based on runtime
            switch containerRuntime {
            case .compote(let orch):
                let containers = managedContainers.map { CompoteOrchestrator.ManagedContainer(name: $0.name, containerID: $0.containerID, image: $0.image, ports: $0.ports) }
                await orch.stopContainers(containers)
            case .docker(let orch):
                let containers = managedContainers.map { DependencyOrchestrator.ManagedContainer(name: $0.name, containerID: $0.containerID, image: $0.image, ports: $0.ports) }
                await orch.stopContainers(containers)
            }
            throw ExitCode.failure
        }

        if !verbose {
            terminal.print("✓ Build succeeded", style: .success)
        }

        // Start the local server
        terminal.print("Starting server on \(host):\(port)...", style: .info)
        terminal.print("")

        // Determine the binary path
        // The .build/debug symlink works for both Xcode projects and Swift Packages
        let serverBinaryName = "\(projectName)Server"
        let binaryPath = "\(devPath)/.build/debug/\(serverBinaryName)"

        let runProcess = Process()
        runProcess.executableURL = URL(fileURLWithPath: binaryPath)
        runProcess.arguments = []
        runProcess.currentDirectoryURL = URL(fileURLWithPath: cwd)

        // Always show server output - explicitly set to ensure inheritance
        runProcess.standardOutput = FileHandle.standardOutput
        runProcess.standardError = FileHandle.standardError

        // Set up signal handling for graceful shutdown
        // Container cleanup happens after waitUntilExit returns (lines below)
        let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signalSource.setEventHandler {
            print("\nShutting down...")
            runProcess.terminate()
            signalSource.cancel()
        }
        signalSource.resume()

        // Block SIGINT from default handler so our DispatchSource can handle it
        signal(SIGINT, SIG_IGN)

        try runProcess.run()
        runProcess.waitUntilExit()

        // Clean up signal handler
        signalSource.cancel()
        signal(SIGINT, SIG_DFL)

        // Stop managed containers on normal exit too
        if !managedContainers.isEmpty {
            terminal.print("")
            terminal.print("Stopping dependencies...", style: .dim)
            // Stop containers based on runtime
            switch containerRuntime {
            case .compote(let orch):
                let containers = managedContainers.map { CompoteOrchestrator.ManagedContainer(name: $0.name, containerID: $0.containerID, image: $0.image, ports: $0.ports) }
                await orch.stopContainers(containers)
            case .docker(let orch):
                let containers = managedContainers.map { DependencyOrchestrator.ManagedContainer(name: $0.name, containerID: $0.containerID, image: $0.image, ports: $0.ports) }
                await orch.stopContainers(containers)
            }
        }

        // If the process exits (e.g., Ctrl+C), clean up
        if runProcess.terminationStatus != 0 {
            terminal.print("")
            terminal.print("Server stopped.", style: .warning)
        }
    }

    private func sanitizeSwiftIdentifier(_ name: String) -> String {
        var result = name

        // Replace invalid characters with underscores
        let invalidChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).inverted
        result = result.components(separatedBy: invalidChars).joined(separator: "_")

        // Remove consecutive underscores
        while result.contains("__") {
            result = result.replacingOccurrences(of: "__", with: "_")
        }

        // Ensure it starts with letter or underscore (not a number)
        if let first = result.first, first.isNumber {
            result = "_" + result
        }

        // If empty after sanitization, use fallback
        if result.isEmpty {
            result = "Project"
        }

        return result
    }

    private func getProjectName(from directory: String, terminal: Terminal) throws -> String {
        // Try to load from trebuchet.yaml first
        let configLoader = ConfigLoader()
        if let config = try? configLoader.load(from: directory) {
            return sanitizeSwiftIdentifier(config.name)
        }

        // Otherwise, try to parse Package.swift
        let packagePath = "\(directory)/Package.swift"
        if FileManager.default.fileExists(atPath: packagePath),
           let contents = try? String(contentsOfFile: packagePath) {
            // Simple regex to extract package name
            if let range = contents.range(of: #"name:\s*"([^"]+)""#, options: .regularExpression) {
                let match = String(contents[range])
                if let nameRange = match.range(of: #""([^"]+)""#, options: .regularExpression) {
                    let nameMatch = String(match[nameRange])
                    let name = nameMatch.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    return sanitizeSwiftIdentifier(name)
                }
            }
        }

        // Fallback to directory name
        terminal.print("Could not determine project name, using directory name", style: .warning)
        let dirName = URL(fileURLWithPath: directory).lastPathComponent
        return sanitizeSwiftIdentifier(dirName)
    }

    private func generatePackageManifest(packageName: String, projectName: String, parentPackageName: String, localTrebuchetPath: String?, config: TrebuchetConfig?) -> String {
        let trebuchetDependency: String
        if let localPath = localTrebuchetPath {
            // Expand ~ in path
            let expandedPath = (localPath as NSString).expandingTildeInPath
            trebuchetDependency = ".package(path: \"\(expandedPath)\")"
        } else {
            trebuchetDependency = ".package(url: \"https://github.com/briannadoubt/Trebuchet.git\", .upToNextMajor(from: \"0.3.0\"))"
        }

        // Add state store dependencies based on config
        var stateDependencies: [String] = []
        if let stateType = config?.state?.type.lowercased() {
            switch stateType {
            case "surrealdb":
                stateDependencies.append(".product(name: \"TrebuchetSurrealDB\", package: \"Trebuchet\")")
            case "postgresql":
                stateDependencies.append(".product(name: \"TrebuchetPostgreSQL\", package: \"Trebuchet\")")
            case "dynamodb":
                stateDependencies.append(".product(name: \"TrebuchetAWS\", package: \"Trebuchet\")")
            default:
                break
            }
        }

        let allDependencies = ([
            ".product(name: \"Trebuchet\", package: \"Trebuchet\")",
            ".product(name: \"\(projectName)\", package: \"\(parentPackageName)\")"
        ] + stateDependencies).joined(separator: ",\n                        ")

        return """
        // swift-tools-version: 6.0
        // Auto-generated Package.swift for local development server
        // Generated by: trebuchet dev

        import PackageDescription

        let package = Package(
            name: "\(packageName)",
            platforms: [.macOS(.v14)],
            dependencies: [
                .package(path: ".."),
                \(trebuchetDependency)
            ],
            targets: [
                .executableTarget(
                    name: "\(packageName)",
                    dependencies: [
                        \(allDependencies)
                    ]
                )
            ]
        )
        """
    }

    private func getParentPackageName(from directory: String) throws -> String? {
        let packagePath = "\(directory)/Package.swift"
        guard FileManager.default.fileExists(atPath: packagePath),
              let contents = try? String(contentsOfFile: packagePath) else {
            return nil
        }

        // Extract package name from Package.swift
        if let range = contents.range(of: #"name:\s*"([^"]+)""#, options: .regularExpression) {
            let match = String(contents[range])
            if let nameRange = match.range(of: #""([^"]+)""#, options: .regularExpression) {
                let nameMatch = String(match[nameRange])
                return nameMatch.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }

        return nil
    }

    private func inferModuleName(from actors: [ActorMetadata], projectName: String) -> String {
        // Try to infer module name from actor file paths
        // Format is typically: Sources/ModuleName/File.swift
        for actor in actors {
            let components = actor.filePath.components(separatedBy: "/")
            if let sourcesIndex = components.firstIndex(of: "Sources"),
               sourcesIndex + 1 < components.count {
                let moduleName = components[sourcesIndex + 1]
                // Skip test and example targets
                if !moduleName.contains("Test") && !moduleName.contains("Example") {
                    // Sanitize in case of unusual target names
                    return sanitizeSwiftIdentifier(moduleName)
                }
            }
        }

        // Fall back to project name if we can't infer
        // projectName is already sanitized
        return projectName
    }

    private func generateLocalRunner(
        actors: [ActorMetadata],
        moduleName: String,
        host: String,
        port: UInt16,
        config: TrebuchetConfig?
    ) -> String {
        // Generate streaming handler configuration for actors with streaming methods
        let streamingConfigs = actors.compactMap { actor -> String? in
            // Detect @StreamedState properties by reading the source file
            guard let sourceContent = try? String(contentsOfFile: actor.filePath, encoding: .utf8) else {
                return nil
            }

            // Find @StreamedState properties
            let streamedStatePattern = "@StreamedState\\s+public\\s+var\\s+([a-zA-Z_][a-zA-Z0-9_]*):"
            guard let regex = try? NSRegularExpression(pattern: streamedStatePattern, options: []) else {
                return nil
            }

            let nsString = sourceContent as NSString
            let matches = regex.matches(in: sourceContent, options: [], range: NSRange(location: 0, length: nsString.length))

            var streamedProperties: [String] = []
            for match in matches {
                guard match.numberOfRanges >= 2 else { continue }
                let propertyNameRange = match.range(at: 1)
                guard propertyNameRange.location != NSNotFound else { continue }
                let propertyName = nsString.substring(with: propertyNameRange)
                streamedProperties.append(propertyName)
            }

            guard !streamedProperties.isEmpty else { return nil }

            // Generate observe method registrations using streaming protocol
            let protocolName = "\(actor.name)Streaming"
            let methodRegistrations = streamedProperties.map { propertyName in
                let capitalizedName = propertyName.prefix(1).uppercased() + propertyName.dropFirst()
                let methodName = "observe\(capitalizedName)"
                return """
                await server.configureStreaming(
                    for: \(protocolName).self,
                    method: "\(methodName)"
                ) { (actor: \(protocolName)) in await actor.\(methodName)() }
                """
            }.joined(separator: "\n")

            return """
                // Configure streaming for \(actor.name)
            \(methodRegistrations)
            """
        }.joined(separator: "\n\n                ")

        let streamingSetup = streamingConfigs.isEmpty ? "" : """

                // Configure streaming handlers
                \(streamingConfigs)

        """

        // Generate state store imports and initialization based on config
        let stateStoreImport: String
        let stateStoreInit: String
        let stateStoreCapture: String

        if let stateType = config?.state?.type.lowercased() {
            switch stateType {
            case "surrealdb":
                stateStoreImport = "import TrebuchetSurrealDB"
                stateStoreInit = """
// Initialize SurrealDB state store
let stateStore = try await SurrealDBStateStore(
    configuration: .init(
        host: "localhost",
        port: 8000,
        namespace: "\(config?.name ?? "dev")",
        database: "\(config?.name ?? "dev")",
        username: "root",
        password: "root"
    )
)
print("✓ Connected to SurrealDB on localhost:8000")
print("")
"""
                stateStoreCapture = ", stateStore: stateStore"

            case "postgresql":
                stateStoreImport = "import TrebuchetPostgreSQL"
                stateStoreInit = """
// Initialize PostgreSQL state store
let stateStore = try await PostgreSQLStateStore(
    configuration: .init(
        host: "localhost",
        port: 5432,
        database: "trebuchet_dev",
        username: "trebuchet",
        password: "trebuchet"
    )
)
print("✓ Connected to PostgreSQL on localhost:5432")
print("")
"""
                stateStoreCapture = ", stateStore: stateStore"

            case "dynamodb":
                stateStoreImport = "import TrebuchetAWS"
                stateStoreInit = """
// Initialize DynamoDB state store (LocalStack)
let stateStore = try await DynamoDBStateStore(
    tableName: "\(config?.state?.tableName ?? (config?.name ?? "dev") + "-state")",
    region: "us-east-1",
    endpoint: "http://localhost:4566"  // LocalStack
)
print("✓ Connected to DynamoDB (LocalStack) on localhost:4566")
print("")
"""
                stateStoreCapture = ", stateStore: stateStore"

            default:
                stateStoreImport = ""
                stateStoreInit = ""
                stateStoreCapture = ""
            }
        } else {
            stateStoreImport = ""
            stateStoreInit = ""
            stateStoreCapture = ""
        }

        // Generate dynamic actor creation cases with state store injection
        let dynamicActorCasesWithState = actors.map { actor in
            let actorNameLower = actor.name.lowercased()
            return """
                    case let id where id == "\(actorNameLower)" || id.hasPrefix("\(actorNameLower)-"):
                        let actor = \(actor.name)(actorSystem: server.actorSystem\(stateStoreCapture))
                        await server.expose(actor, as: actorID.id)
                        print("  ✓ Created: \(actor.name) (\\(actorID.id))")
            """
        }.joined(separator: "\n")

        let additionalImports = stateStoreImport.isEmpty ? "" : "\n\(stateStoreImport)"
        // Add proper indentation (16 spaces) to each line of state store init
        let stateStoreSetup: String
        if stateStoreInit.isEmpty {
            stateStoreSetup = ""
        } else {
            let lines = stateStoreInit.split(separator: "\n", omittingEmptySubsequences: false)
            stateStoreSetup = lines.map { "                \($0)" }.joined(separator: "\n")
        }

        return """
        // Auto-generated local development runner
        // Generated by: trebuchet dev

        import Foundation
        import Trebuchet
        import \(moduleName)\(additionalImports)

        @main
        struct LocalRunner {
            static func main() async throws {
                // Disable stdout buffering to ensure logs appear immediately
                setbuf(stdout, nil)
                setbuf(stderr, nil)

                print("Starting local development server...")
                print("")

                \(stateStoreSetup)
                let server = TrebuchetServer(
                    transport: .webSocket(host: "\(host)", port: \(port))
                )

                // Enable verbose logging
                server.actorSystem.onInvocation = { actorID, method in
                    let timestamp = ISO8601DateFormatter().string(from: Date())
                    print("[\\(timestamp)] 📞 \\(actorID).\\(method)")
                }

                server.actorSystem.onStreamStart = { actorID, method in
                    let timestamp = ISO8601DateFormatter().string(from: Date())
                    print("[\\(timestamp)] 🌊 Stream started: \\(actorID).\\(method)")
                }

                server.actorSystem.onStreamEnd = { actorID, method in
                    let timestamp = ISO8601DateFormatter().string(from: Date())
                    print("[\\(timestamp)] 🏁 Stream ended: \\(actorID).\\(method)")
                }
                \(streamingSetup)
                // Dynamic actor creation
                server.onActorRequest = { actorID in
                    switch actorID.id {
        \(dynamicActorCasesWithState)
                    default:
                        print("⚠️  Unknown actor type requested: \\(actorID.id)")
                    }
                }

                print("")
                print("Server running on ws://\(host):\(port)")
                print("Dynamic actor creation enabled")
                print("Logging all activity...")
                print("Press Ctrl+C to stop")
                print("")

                try await server.run()
            }
        }
        """
    }

    private func detectXcodeProject(in directory: String) -> Bool {
        let fileManager = FileManager.default

        // Check if directory contains .xcodeproj
        guard let contents = try? fileManager.contentsOfDirectory(atPath: directory) else {
            return false
        }

        return contents.contains { $0.hasSuffix(".xcodeproj") }
    }

    private func generateXcodeProjectPackageManifest(
        packageName: String,
        moduleName: String,
        localTrebuchetPath: String?,
        config: TrebuchetConfig?
    ) -> String {
        let trebuchetDependency: String
        if let localPath = localTrebuchetPath {
            // Expand ~ in path
            let expandedPath = (localPath as NSString).expandingTildeInPath
            trebuchetDependency = ".package(path: \"\(expandedPath)\")"
        } else {
            trebuchetDependency = ".package(url: \"https://github.com/briannadoubt/Trebuchet.git\", .upToNextMajor(from: \"0.3.0\"))"
        }

        // Add state store dependencies based on config
        var moduleStateDependencies: [String] = []
        var executableStateDependencies: [String] = []
        if let stateType = config?.state?.type.lowercased() {
            switch stateType {
            case "surrealdb":
                moduleStateDependencies.append(".product(name: \"TrebuchetSurrealDB\", package: \"Trebuchet\")")
                executableStateDependencies.append(".product(name: \"TrebuchetSurrealDB\", package: \"Trebuchet\")")
            case "postgresql":
                moduleStateDependencies.append(".product(name: \"TrebuchetPostgreSQL\", package: \"Trebuchet\")")
                executableStateDependencies.append(".product(name: \"TrebuchetPostgreSQL\", package: \"Trebuchet\")")
            case "dynamodb":
                moduleStateDependencies.append(".product(name: \"TrebuchetAWS\", package: \"Trebuchet\")")
                executableStateDependencies.append(".product(name: \"TrebuchetAWS\", package: \"Trebuchet\")")
            default:
                break
            }
        }

        let moduleDependencies = ([
            ".product(name: \"Trebuchet\", package: \"Trebuchet\")"
        ] + moduleStateDependencies).joined(separator: ",\n                        ")

        let executableDependencies = ([
            ".product(name: \"Trebuchet\", package: \"Trebuchet\")",
            "\"\(moduleName)\""
        ] + executableStateDependencies).joined(separator: ",\n                        ")

        return """
        // swift-tools-version: 6.0
        // Auto-generated Package.swift for local development server
        // Generated by: trebuchet dev (Xcode project mode)
        // Module name: \(moduleName) (matches Xcode project for type identity)

        import PackageDescription

        let package = Package(
            name: "\(packageName)",
            platforms: [.macOS(.v14), .iOS(.v17)],
            dependencies: [
                \(trebuchetDependency)
            ],
            targets: [
                .target(
                    name: "\(moduleName)",
                    dependencies: [
                        \(moduleDependencies)
                    ]
                ),
                .executableTarget(
                    name: "\(packageName)",
                    dependencies: [
                        \(executableDependencies)
                    ]
                )
            ]
        )
        """
    }

    private func copyActorSources(
        actors: [ActorMetadata],
        to targetPath: String,
        terminal: Terminal,
        verbose: Bool
    ) throws {
        // Track which files we've already copied to avoid duplicates
        var copiedFiles = Set<String>()

        for actor in actors {
            let sourceFile = actor.filePath
            let fileName = URL(fileURLWithPath: sourceFile).lastPathComponent

            // Skip if already copied
            guard !copiedFiles.contains(fileName) else {
                continue
            }

            let targetFile = "\(targetPath)/\(fileName)"

            // Copy source file as-is - macros will expand during build
            try FileManager.default.copyItem(atPath: sourceFile, toPath: targetFile)
            copiedFiles.insert(fileName)

            if verbose {
                terminal.print("  Copied: \(fileName)", style: .dim)
            }

            // Also copy streaming protocol file if it exists
            let actorBaseName = fileName.replacingOccurrences(of: ".swift", with: "")
            let streamingProtocolName = "\(actorBaseName)Streaming.swift"
            let sourceDir = URL(fileURLWithPath: sourceFile).deletingLastPathComponent().path
            let streamingProtocolPath = "\(sourceDir)/\(streamingProtocolName)"

            if FileManager.default.fileExists(atPath: streamingProtocolPath),
               !copiedFiles.contains(streamingProtocolName) {
                let targetStreamingFile = "\(targetPath)/\(streamingProtocolName)"
                try FileManager.default.copyItem(atPath: streamingProtocolPath, toPath: targetStreamingFile)
                copiedFiles.insert(streamingProtocolName)

                if verbose {
                    terminal.print("  Copied: \(streamingProtocolName)", style: .dim)
                }
            }
        }

        terminal.print("✓ Copied \(copiedFiles.count) actor source file(s)", style: .success)
    }
}
