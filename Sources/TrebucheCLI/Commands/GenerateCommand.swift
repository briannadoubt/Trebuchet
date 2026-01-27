import ArgumentParser
import Foundation

struct GenerateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "generate",
        abstract: "Generate deployment artifacts",
        subcommands: [GenerateServerCommand.self]
    )
}

struct GenerateServerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "server",
        abstract: "Generate a server package from your actors"
    )

    @Option(name: .long, help: "Path to trebuche.yaml")
    var config: String?

    @Option(name: .long, help: "Output directory for generated server")
    var output: String?

    @Flag(name: .shortAndLong, help: "Enable verbose output")
    var verbose: Bool = false

    @Flag(name: .long, help: "Force regeneration even if server exists")
    var force: Bool = false

    mutating func run() async throws {
        let terminal = Terminal()
        let cwd = FileManager.default.currentDirectoryPath

        // Load configuration
        terminal.print("Loading configuration...", style: .dim)
        let configLoader = ConfigLoader()
        let trebucheConfig: TrebucheConfig

        do {
            if let configPath = config {
                trebucheConfig = try configLoader.load(file: configPath)
            } else {
                trebucheConfig = try configLoader.load(from: cwd)
            }
        } catch ConfigError.fileNotFound {
            terminal.print("No trebuche.yaml found. Run 'trebuche init' to create one.", style: .error)
            throw ExitCode.failure
        }

        // Discover actors
        terminal.print("")
        terminal.print("Discovering actors...", style: .header)

        let discovery = ActorDiscovery()
        let actors = try discovery.discover(in: cwd)

        if actors.isEmpty {
            terminal.print("No distributed actors found.", style: .warning)
            terminal.print("Make sure your actors use @Trebuchet macro or TrebuchetActorSystem typealias.", style: .dim)
            throw ExitCode.failure
        }

        for actor in actors {
            terminal.print("  ✓ \(actor.name)", style: .success)
            if verbose {
                for method in actor.methods {
                    terminal.print("      → \(method.signature)", style: .dim)
                }
            }
        }

        terminal.print("")

        // Determine output directory
        let outputDir = output ?? "\(cwd)/.trebuche/server"

        // Check if server already exists
        if FileManager.default.fileExists(atPath: outputDir) && !force {
            terminal.print("Server package already exists at \(outputDir)", style: .warning)
            terminal.print("Use --force to regenerate", style: .dim)
            throw ExitCode.failure
        }

        // Generate server
        terminal.print("Generating server package...", style: .header)

        let generator = ServerGenerator(terminal: terminal)
        try generator.generate(
            config: trebucheConfig,
            actors: actors,
            projectPath: cwd,
            outputPath: outputDir,
            verbose: verbose
        )

        terminal.print("")
        terminal.print("✓ Server package generated at \(outputDir)", style: .success)
        terminal.print("")
        terminal.print("To deploy:", style: .dim)
        terminal.print("  trebuche deploy", style: .dim)
        terminal.print("")
        terminal.print("To run locally:", style: .dim)
        terminal.print("  cd \(outputDir)", style: .dim)
        terminal.print("  swift run", style: .dim)
    }
}
