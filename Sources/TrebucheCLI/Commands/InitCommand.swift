import ArgumentParser
import Foundation

struct InitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Initialize a new Trebuche configuration"
    )

    @Option(name: .shortAndLong, help: "Project name")
    var name: String?

    @Option(name: .shortAndLong, help: "Cloud provider (aws, gcp, azure)")
    var provider: String = "aws"

    @Option(name: .shortAndLong, help: "Default region")
    var region: String = "us-east-1"

    @Flag(name: .long, help: "Overwrite existing configuration")
    var force: Bool = false

    mutating func run() async throws {
        let terminal = Terminal()
        let cwd = FileManager.default.currentDirectoryPath

        let configPath = "\(cwd)/trebuche.yaml"

        if FileManager.default.fileExists(atPath: configPath) && !force {
            terminal.print("trebuche.yaml already exists. Use --force to overwrite.", style: .error)
            throw ExitCode.failure
        }

        // Determine project name from directory if not provided
        let projectName = name ?? URL(fileURLWithPath: cwd).lastPathComponent

        terminal.print("")
        terminal.print("Initializing Trebuche configuration...", style: .header)
        terminal.print("")

        // Discover existing actors
        let discovery = ActorDiscovery()
        let actors = try discovery.discover(in: cwd)

        // Generate configuration
        var config = TrebucheConfig(
            name: projectName,
            defaults: DefaultSettings(
                provider: provider,
                region: region
            )
        )

        // Add discovered actors to config
        for actor in actors {
            config.actors[actor.name] = ActorConfig(
                stateful: actor.isStateful
            )
        }

        // Add state and discovery config
        config.state = StateConfig(type: "dynamodb")
        config.discovery = DiscoveryConfig(type: "cloudmap", namespace: projectName)

        // Generate YAML
        let yamlContent = generateYAML(config: config, actors: actors)
        try yamlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

        terminal.print("✓ Created trebuche.yaml", style: .success)
        terminal.print("")

        if !actors.isEmpty {
            terminal.print("Discovered actors:", style: .info)
            for actor in actors {
                terminal.print("  • \(actor.name)", style: .dim)
            }
            terminal.print("")
        }

        terminal.print("Next steps:", style: .header)
        terminal.print("  1. Edit trebuche.yaml to customize settings", style: .dim)
        terminal.print("  2. Run 'trebuche deploy --dry-run' to preview", style: .dim)
        terminal.print("  3. Run 'trebuche deploy' to deploy", style: .dim)
    }

    private func generateYAML(config: TrebucheConfig, actors: [ActorMetadata]) -> String {
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
                yaml += "  \(actor.name):\n"
                if actor.isStateful {
                    yaml += "    stateful: true\n"
                }
                yaml += "    # memory: 512\n"
                yaml += "    # timeout: 30\n"
                yaml += "    # isolated: false\n"
            }
            yaml += "\n"
        } else {
            yaml += "actors: {}\n\n"
        }

        yaml += """
        environments:
          production:
            region: us-west-2
          staging:
            region: us-east-1

        state:
          type: dynamodb

        discovery:
          type: cloudmap
          namespace: \(config.name)
        """

        return yaml
    }
}
