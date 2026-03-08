import ArgumentParser
import Foundation

public struct DBCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "db",
        abstract: "Manage Trebuchet SQLite database storage",
        subcommands: [
            DBInitCommand.self,
            DBStatusCommand.self,
            DBInspectCommand.self,
            DBDoctorCommand.self,
            DBMigrateCommand.self,
            DBSnapshotCommand.self,
            DBRestoreCommand.self,
            DBCompactCommand.self,
            DBShellCommand.self,
            DBOwnershipCommand.self,
            DBRebalanceCommand.self,
        ]
    )

    public init() {}
}
