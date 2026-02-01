import ArgumentParser
import Foundation

public struct GenerateCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "generate",
        abstract: "Generate deployment artifacts",
        subcommands: [GenerateServerCommand.self, GenerateCommandsCommand.self]
    )

    public init() {}
}


public struct GenerateServerCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "server",
        abstract: "Generate a server package from your actors"
    )

    @Option(name: .long, help: "Path to trebuchet.yaml")
    public var config: String?

    @Option(name: .long, help: "Output directory for generated server")
    public var output: String?

    @Flag(name: .shortAndLong, help: "Enable verbose output")
    public var verbose: Bool = false

    @Flag(name: .long, help: "Force regeneration even if server exists")
    public var force: Bool = false

    public init() {}

    public mutating func run() async throws {
        let terminal = Terminal()
        let cwd = FileManager.default.currentDirectoryPath

        // Load configuration
        terminal.print("Loading configuration...", style: .dim)
        let configLoader = ConfigLoader()
        let trebuchetConfig: TrebuchetConfig

        do {
            if let configPath = config {
                trebuchetConfig = try configLoader.load(file: configPath)
            } else {
                trebuchetConfig = try configLoader.load(from: cwd)
            }
        } catch ConfigError.fileNotFound {
            terminal.print("No trebuchet.yaml found. Run 'trebuchet init' to create one.", style: .error)
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
        let outputDir = output ?? "\(cwd)/.trebuchet/server"

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
            config: trebuchetConfig,
            actors: actors,
            projectPath: cwd,
            outputPath: outputDir,
            verbose: verbose
        )

        terminal.print("")
        terminal.print("✓ Server package generated at \(outputDir)", style: .success)
        terminal.print("")
        terminal.print("To deploy:", style: .dim)
        terminal.print("  trebuchet deploy", style: .dim)
        terminal.print("")
        terminal.print("To run locally:", style: .dim)
        terminal.print("  cd \(outputDir)", style: .dim)
        terminal.print("  swift run", style: .dim)
    }
}


public struct GenerateCommandsCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "commands",
        abstract: "Generate Swift Package Command Plugins from trebuchet.yaml commands"
    )

    @Option(name: .long, help: "Path to trebuchet.yaml")
    public var config: String?

    @Option(name: .long, help: "Output directory for generated plugins (defaults to current directory)")
    public var output: String?

    @Flag(name: .shortAndLong, help: "Enable verbose output")
    public var verbose: Bool = false

    @Flag(name: .long, help: "Force regeneration even if plugins exist")
    public var force: Bool = false

    public init() {}

    public mutating func run() async throws {
        let terminal = Terminal()
        let cwd = FileManager.default.currentDirectoryPath

        // Load configuration
        terminal.print("Loading configuration...", style: .dim)
        let configLoader = ConfigLoader()
        let trebuchetConfig: TrebuchetConfig

        do {
            if let configPath = config {
                trebuchetConfig = try configLoader.load(file: configPath)
            } else {
                trebuchetConfig = try configLoader.load(from: cwd)
            }
        } catch ConfigError.fileNotFound {
            terminal.print("No trebuchet.yaml found. Run 'trebuchet init' to create one.", style: .error)
            throw ExitCode.failure
        }

        guard let commands = trebuchetConfig.commands, !commands.isEmpty else {
            terminal.print("No commands defined in trebuchet.yaml.", style: .warning)
            terminal.print("Add a commands section to your configuration:", style: .dim)
            terminal.print("", style: .dim)
            terminal.print("  commands:", style: .dim)
            terminal.print("    runLocally:", style: .dim)
            terminal.print("      title: \"Run Locally\"", style: .dim)
            terminal.print("      script: trebuchet dev", style: .dim)
            throw ExitCode.failure
        }

        let outputDir = output ?? cwd

        // Check if plugins already exist
        let pluginsDir = "\(outputDir)/Plugins"
        if FileManager.default.fileExists(atPath: pluginsDir) && !force {
            // Check if any of our plugins already exist
            let existingPlugins = commands.keys.filter { name in
                let targetName = CommandPluginGenerator.pluginTargetName(from: name)
                return FileManager.default.fileExists(atPath: "\(pluginsDir)/\(targetName)")
            }
            if !existingPlugins.isEmpty {
                terminal.print("Command plugins already exist in \(pluginsDir)", style: .warning)
                terminal.print("Use --force to regenerate", style: .dim)
                throw ExitCode.failure
            }
        }

        // Generate plugins
        terminal.print("")
        terminal.print("Generating command plugins...", style: .header)
        terminal.print("")

        let generator = CommandPluginGenerator(terminal: terminal)
        let plugins = try generator.generate(
            config: trebuchetConfig,
            outputPath: outputDir,
            verbose: verbose
        )

        terminal.print("")
        for plugin in plugins {
            terminal.print("  ✓ \(plugin.name) → swift package \(plugin.verb)", style: .success)
        }

        terminal.print("")
        terminal.print("✓ Generated \(plugins.count) command plugin(s) in \(pluginsDir)", style: .success)
        terminal.print("")

        // Show Package.swift snippet
        terminal.print("Add the following to your Package.swift:", style: .header)
        terminal.print("")
        let snippet = generator.generatePackageSnippet(plugins: plugins)
        terminal.print(snippet, style: .dim)
    }
}
