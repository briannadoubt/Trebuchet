import ArgumentParser
import Foundation

struct DBShellCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shell",
        abstract: "Open an interactive SQLite shell for a shard"
    )

    @Option(name: .long, help: "Database root directory")
    var path: String = ".trebuchet/db"

    @Option(name: .long, help: "Shard number to open")
    var shard: Int = 0

    @Flag(name: .long, help: "Open in read-write mode (default is read-only)")
    var readWrite: Bool = false

    @Argument(help: "Direct path to a SQLite database file (overrides --path and --shard)")
    var dbFile: String?

    mutating func run() async throws {
        let terminal = Terminal()

        let dbPath: String
        if let directPath = dbFile {
            dbPath = resolvePath(directPath)
        } else {
            let root = resolvePath(path)
            let shardName = "shard-\(String(format: "%04d", shard))"
            dbPath = "\(root)/shards/\(shardName)/main.sqlite"
        }

        guard FileManager.default.fileExists(atPath: dbPath) else {
            terminal.print("✗ Database not found at \(dbPath)", style: .error)
            return
        }

        terminal.print("Opening SQLite shell...", style: .header)
        terminal.print("  Database: \(dbPath)", style: .dim)
        terminal.print("  Mode: \(readWrite ? "read-write" : "read-only")", style: .dim)
        terminal.print("  Type .quit to exit", style: .dim)
        terminal.print("", style: .info)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")

        var args: [String] = []
        if !readWrite {
            args.append("-readonly")
        }
        args.append(dbPath)
        args.append("-header")
        args.append("-column")
        process.arguments = args

        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        try process.run()
        process.waitUntilExit()
    }

    private func resolvePath(_ path: String) -> String {
        if path.hasPrefix("/") { return path }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(path).standardizedFileURL.path
    }
}
