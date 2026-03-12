import ArgumentParser
import Foundation

public struct DevCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "dev",
        abstract: "Run a System executable from a Swift package for local development"
    )

    @Argument(help: "Path to the Swift package containing the @main ...: System executable")
    public var projectPath: String = "."

    @Option(name: .shortAndLong, help: "Port to listen on")
    public var port: UInt16 = 8080

    @Option(name: .shortAndLong, help: "Host to bind to")
    public var host: String = "localhost"

    @Flag(name: .shortAndLong, help: "Enable verbose output")
    public var verbose: Bool = false

    @Option(name: .long, help: "Executable product to run")
    public var product: String?

    @Flag(name: .long, help: "Skip automatic dependency management")
    public var noDeps: Bool = false

    @Option(name: .long, help: "Dependency runtime preference (compote on macOS, docker on non-macOS)")
    public var runtime: String = {
        #if os(macOS)
        "compote"
        #else
        "docker"
        #endif
    }()

    public init() {}

    public mutating func run() async throws {
        let terminal = Terminal()
        let projectDirectory = try resolveProjectDirectory(projectPath)

        terminal.print("", style: .info)
        terminal.print("Starting Trebuchet dev runtime...", style: .header)
        terminal.print("", style: .info)

        try ensurePortAvailable(port, terminal: terminal)

        let resolver = SystemProductResolver()
        let resolved = try resolver.resolve(projectPath: projectDirectory, explicitProduct: product)

        terminal.print("Resolved executable product: \(resolved.product)", style: .success)
        if verbose {
            terminal.print("Targets: \(resolved.executableTargets.joined(separator: ", "))", style: .dim)
        }
        terminal.print("", style: .info)

        let runner = SystemExecutableRunner()
        let dependencyRuntime = DevDependencyRuntime(
            terminal: terminal,
            verbose: verbose,
            projectDirectory: projectDirectory,
            runtimePreference: runtime
        )

        var dependencySession: DevDependencySession?
        if !noDeps {
            let plan = try? runner.buildPlan(
                projectPath: projectDirectory,
                product: resolved.product,
                provider: nil,
                environment: nil
            )
            dependencySession = try await dependencyRuntime.start(plan: plan)
            if dependencySession != nil {
                terminal.print("", style: .info)
            }
        }

        do {
            try runner.runDev(
                projectPath: projectDirectory,
                product: resolved.product,
                host: host,
                port: port,
                verbose: verbose
            )
            if let dependencySession {
                await dependencyRuntime.stop(dependencySession)
            }
        } catch {
            if let dependencySession {
                await dependencyRuntime.stop(dependencySession)
            }
            throw error
        }
    }

    private func resolveProjectDirectory(_ path: String) throws -> String {
        let currentDirectory = FileManager.default.currentDirectoryPath
        let expanded = (path as NSString).expandingTildeInPath
        let url: URL

        if expanded.hasPrefix("/") {
            url = URL(fileURLWithPath: expanded).standardizedFileURL
        } else {
            url = URL(fileURLWithPath: currentDirectory)
                .appendingPathComponent(expanded)
                .standardizedFileURL
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CLIError.configurationError("Project path does not exist or is not a directory: \(path)")
        }

        return url.path
    }

    private func ensurePortAvailable(_ port: UInt16, terminal: Terminal) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["lsof", "-i", ":\(port)", "-sTCP:LISTEN"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus != 0 else {
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            terminal.print("Port \(port) is already in use.", style: .error)
            if !output.isEmpty {
                terminal.print(output, style: .dim)
            }
            throw ExitCode.failure
        }
    }
}
