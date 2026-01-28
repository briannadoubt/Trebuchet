import ArgumentParser
import Foundation

/// Main Trebuchet CLI command structure shared between executable and plugin
public struct TrebuchetCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "trebuchet",
        abstract: "Deploy Swift distributed actors to the cloud",
        version: "0.1.0",
        subcommands: [
            DeployCommand.self,
            StatusCommand.self,
            UndeployCommand.self,
            DevCommand.self,
            InitCommand.self,
            GenerateCommand.self,
        ],
        defaultSubcommand: nil
    )

    public init() {}
}
