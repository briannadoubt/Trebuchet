import ArgumentParser
import Foundation

struct DevCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dev",
        abstract: "Run actors locally for development"
    )

    @Option(name: .shortAndLong, help: "Port to listen on")
    var port: UInt16 = 8080

    @Option(name: .shortAndLong, help: "Host to bind to")
    var host: String = "localhost"

    @Flag(name: .shortAndLong, help: "Enable verbose output")
    var verbose: Bool = false

    mutating func run() async throws {
        let terminal = Terminal()
        let cwd = FileManager.default.currentDirectoryPath

        terminal.print("")
        terminal.print("Starting local development server...", style: .header)
        terminal.print("")

        // Discover actors
        let discovery = ActorDiscovery()
        let actors = try discovery.discover(in: cwd)

        if actors.isEmpty {
            terminal.print("No distributed actors found.", style: .warning)
            throw ExitCode.failure
        }

        terminal.print("Found actors:", style: .info)
        for actor in actors {
            terminal.print("  • \(actor.name)", style: .dim)
        }
        terminal.print("")

        // Get project and module names
        let projectName = try getProjectName(from: cwd, terminal: terminal)
        let parentPackageName = try getParentPackageName(from: cwd) ?? projectName
        let moduleName = inferModuleName(from: actors, projectName: projectName)

        // Generate and run local bootstrap
        terminal.print("Building project...", style: .dim)

        let buildProcess = Process()
        buildProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        buildProcess.arguments = ["swift", "build"]
        buildProcess.currentDirectoryURL = URL(fileURLWithPath: cwd)

        if !verbose {
            buildProcess.standardOutput = FileHandle.nullDevice
            buildProcess.standardError = FileHandle.nullDevice
        }

        try buildProcess.run()
        buildProcess.waitUntilExit()

        guard buildProcess.terminationStatus == 0 else {
            terminal.print("Build failed.", style: .error)
            throw ExitCode.failure
        }

        terminal.print("✓ Build succeeded", style: .success)
        terminal.print("")

        // Generate development runner package
        terminal.print("Generating development server...", style: .dim)

        let devPath = "\(cwd)/.trebuchet"
        try FileManager.default.createDirectory(
            atPath: devPath,
            withIntermediateDirectories: true
        )

        // Generate Package.swift
        let packageManifest = generatePackageManifest(
            projectName: moduleName,
            parentPackageName: parentPackageName
        )
        try packageManifest.write(
            toFile: "\(devPath)/Package.swift",
            atomically: true,
            encoding: .utf8
        )

        // Generate main.swift
        let sourcesPath = "\(devPath)/Sources/LocalRunner"
        try FileManager.default.createDirectory(
            atPath: sourcesPath,
            withIntermediateDirectories: true
        )

        let mainScript = generateLocalRunner(
            actors: actors,
            moduleName: moduleName,
            host: host,
            port: port
        )
        try mainScript.write(
            toFile: "\(sourcesPath)/main.swift",
            atomically: true,
            encoding: .utf8
        )

        terminal.print("✓ Runner generated", style: .success)
        terminal.print("")

        // Start the local server
        terminal.print("Starting server on \(host):\(port)...", style: .info)
        terminal.print("")

        let runProcess = Process()
        runProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        runProcess.arguments = ["swift", "run", "--package-path", devPath]
        runProcess.currentDirectoryURL = URL(fileURLWithPath: cwd)

        // Always show server output
        runProcess.standardOutput = FileHandle.standardOutput
        runProcess.standardError = FileHandle.standardError

        try runProcess.run()
        runProcess.waitUntilExit()

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

    private func generatePackageManifest(projectName: String, parentPackageName: String) -> String {
        """
        // swift-tools-version: 6.0
        // Auto-generated Package.swift for local development server
        // Generated by: trebuchet dev

        import PackageDescription

        let package = Package(
            name: "LocalRunner",
            platforms: [.macOS(.v14)],
            dependencies: [
                .package(path: ".."),
                .package(url: "https://github.com/briannadoubt/Trebuchet.git", from: "1.0.0")
            ],
            targets: [
                .executableTarget(
                    name: "LocalRunner",
                    dependencies: [
                        .product(name: "Trebuchet", package: "Trebuchet"),
                        .product(name: "TrebuchetCloud", package: "Trebuchet"),
                        .product(name: "\(projectName)", package: "\(parentPackageName)")
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
        port: UInt16
    ) -> String {
        // Use shared code generation helpers
        let actorInits = BootstrapGenerator.generateActorInitializations(
            actors: actors,
            indent: 8,
            systemVariable: "gateway.system"
        )

        let actorRegistrations = BootstrapGenerator.generateActorRegistrations(
            actors: actors,
            indent: 8,
            logStatement: #"print("  ✓ Exposed: %ACTOR%")"#
        )

        return """
        // Auto-generated local development runner
        // Generated by: trebuchet dev

        import Foundation
        import Trebuchet
        import TrebuchetCloud
        import \(moduleName)

        @main
        struct LocalRunner {
            static func main() async throws {
                print("Starting local development server...")
                print("")

                let gateway = CloudGateway.development(
                    host: "\(host)",
                    port: \(port)
                )

                // Initialize actors
        \(actorInits)

                // Register actors
        \(actorRegistrations)

                print("")
                print("Server running on http://\(host):\(port)")
                print("Health check: http://\(host):\(port)/health")
                print("Invocation endpoint: http://\(host):\(port)/invoke")
                print("")
                print("Press Ctrl+C to stop")
                print("")

                try await gateway.run()
            }
        }
        """
    }
}
