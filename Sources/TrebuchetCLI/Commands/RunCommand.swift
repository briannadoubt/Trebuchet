import ArgumentParser
import Foundation

public struct RunCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run a command defined in trebuchet.yaml"
    )

    @Argument(help: "Command verb to run (as defined in trebuchet.yaml commands section, e.g. 'runLocally')")
    public var name: String

    @Option(name: .long, help: "Path to trebuchet.yaml")
    public var config: String?

    public init() {}

    public mutating func run() async throws {
        let terminal = Terminal()
        let cwd = FileManager.default.currentDirectoryPath

        // Load configuration
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
            terminal.print("No commands defined in trebuchet.yaml.", style: .error)
            throw ExitCode.failure
        }

        guard let command = commands[name] else {
            terminal.print("Unknown command: '\(name)'", style: .error)
            terminal.print("")
            terminal.print("Available commands:", style: .info)
            for (verb, cmdConfig) in commands.sorted(by: { $0.key < $1.key }) {
                terminal.print("  \(verb) (\(cmdConfig.title)) → \(cmdConfig.script)", style: .dim)
            }
            throw ExitCode.failure
        }

        terminal.print("Running '\(command.title)'...", style: .header)
        terminal.print("  \(command.script)", style: .dim)
        terminal.print("")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command.script]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)

        var environment = ProcessInfo.processInfo.environment
        environment["TREBUCHET_PACKAGE_DIR"] = cwd
        process.environment = environment

        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        process.standardInput = FileHandle.standardInput

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            terminal.print("")
            terminal.print("Command '\(name)' failed with exit code \(process.terminationStatus).", style: .error)
            throw ExitCode(process.terminationStatus)
        }
    }
}
