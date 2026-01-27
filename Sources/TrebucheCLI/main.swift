import ArgumentParser
import Foundation

@main
struct TrebucheCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "trebuche",
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
}
