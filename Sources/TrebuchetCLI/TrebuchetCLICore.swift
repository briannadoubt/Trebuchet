import ArgumentParser
import Foundation

/// Main Trebuchet CLI command structure shared between executable and plugin
public struct TrebuchetCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "trebuchet",
        abstract: "Run and deploy Swift System executables with Trebuchet",
        version: "0.1.0",
        subcommands: [
            DeployCommand.self,
            StatusCommand.self,
            UndeployCommand.self,
            DevCommand.self,
            XcodeCommand.self,
            DoctorCommand.self,
        ],
        defaultSubcommand: nil
    )

    public init() {}
}
