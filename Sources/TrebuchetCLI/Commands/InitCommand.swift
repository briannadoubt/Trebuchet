import ArgumentParser
import Foundation

public struct InitCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Initialize a new Trebuchet configuration"
    )

    @Option(name: .shortAndLong, help: "Project name")
    public var name: String?

    @Option(name: .shortAndLong, help: "Cloud provider (fly, aws, gcp, azure)")
    public var provider: String = "fly"

    @Option(name: .shortAndLong, help: "Default region")
    public var region: String?

    @Flag(name: .long, help: "Overwrite existing configuration")
    public var force: Bool = false

    public init() {}

    public mutating func run() async throws {
        let terminal = Terminal()
        let cwd = FileManager.default.currentDirectoryPath

        let configPath = "\(cwd)/trebuchet.yaml"

        if FileManager.default.fileExists(atPath: configPath) && !force {
            terminal.print("trebuchet.yaml already exists. Use --force to overwrite.", style: .error)
            throw ExitCode.failure
        }

        // Normalize provider: fly.io -> fly
        let normalizedProvider = provider.lowercased() == "fly.io" ? "fly" : provider

        // Set default region based on provider if not specified
        let defaultRegion = region ?? (normalizedProvider == "fly" ? "iad" : "us-east-1")

        // Determine project name from directory if not provided
        let projectName = name ?? URL(fileURLWithPath: cwd).lastPathComponent

        terminal.print("")
        terminal.print("Initializing Trebuchet configuration...", style: .header)
        terminal.print("")

        // Discover existing actors
        let discovery = ActorDiscovery()
        let actors = try discovery.discover(in: cwd)

        // Generate configuration
        var config = TrebuchetConfig(
            name: projectName,
            defaults: DefaultSettings(
                provider: normalizedProvider,
                region: defaultRegion
            )
        )

        // Add discovered actors to config
        for actor in actors {
            config.actors[actor.name] = ActorConfig(
                stateful: actor.isStateful
            )
        }

        // Add state and discovery config based on provider
        if normalizedProvider == "fly" {
            // Use memory for free tier - users can upgrade to postgresql if they have a paid account
            config.state = StateConfig(type: "memory")
            config.discovery = DiscoveryConfig(type: "dns", namespace: projectName)
        } else {
            config.state = StateConfig(type: "dynamodb")
            config.discovery = DiscoveryConfig(type: "cloudmap", namespace: projectName)
        }

        // Generate YAML
        let yamlContent = generateYAML(config: config, actors: actors)
        try yamlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

        terminal.print("✓ Created trebuchet.yaml", style: .success)
        terminal.print("")

        if !actors.isEmpty {
            terminal.print("Discovered actors:", style: .info)
            for actor in actors {
                terminal.print("  • \(actor.name)", style: .dim)
            }
            terminal.print("")
        }

        terminal.print("Next steps:", style: .header)
        terminal.print("  1. Edit trebuchet.yaml to customize settings", style: .dim)
        terminal.print("  2. Run 'trebuchet deploy --dry-run' to preview", style: .dim)
        terminal.print("  3. Run 'trebuchet deploy' to deploy", style: .dim)
    }

    private func generateYAML(config: TrebuchetConfig, actors: [ActorMetadata]) -> String {
        var yaml = """
        name: \(config.name)
        version: "1"

        defaults:
          provider: \(config.defaults.provider)
          region: \(config.defaults.region)
          memory: \(config.defaults.memory)
          timeout: \(config.defaults.timeout)


        """

        if !actors.isEmpty {
            yaml += "actors:\n"
            for actor in actors {
                if actor.isStateful {
                    yaml += "  \(actor.name):\n"
                    yaml += "    stateful: true\n"
                    yaml += "    # memory: 512\n"
                    yaml += "    # timeout: 30\n"
                    yaml += "    # isolated: false\n"
                } else {
                    yaml += "  \(actor.name): {}  # memory: 512, timeout: 30, isolated: false\n"
                }
            }
            yaml += "\n"
        } else {
            yaml += "actors: {}\n\n"
        }

        // Environment regions based on provider
        let (prodRegion, stagingRegion) = config.defaults.provider == "fly"
            ? ("lax", "iad")
            : ("us-west-2", "us-east-1")

        yaml += """
        environments:
          production:
            region: \(prodRegion)
          staging:
            region: \(stagingRegion)

        state:
          type: \(config.state?.type ?? "dynamodb")
        """

        // Add helpful comment for Fly.io about upgrading to postgresql
        if config.defaults.provider == "fly" && config.state?.type == "memory" {
            yaml += "  # For persistent state, upgrade to: type: postgresql (requires paid Fly.io account)\n"
        }

        yaml += """

        discovery:
          type: \(config.discovery?.type ?? "cloudmap")
          namespace: \(config.name)
        """

        return yaml
    }
}
