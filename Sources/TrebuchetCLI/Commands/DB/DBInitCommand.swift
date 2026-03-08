import ArgumentParser
import Foundation

struct DBInitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Initialize database directory layout and shard files"
    )

    @Option(name: .long, help: "Database root directory")
    var path: String = ".trebuchet/db"

    @Option(name: .long, help: "Number of shards to create")
    var shards: Int = 1

    mutating func run() async throws {
        let terminal = Terminal()
        let root = resolvePath(path)

        terminal.print("Initializing Trebuchet database...", style: .header)
        terminal.print("  Root: \(root)", style: .dim)
        terminal.print("  Shards: \(shards)", style: .dim)
        terminal.print("", style: .info)

        let fm = FileManager.default
        let shardsDir = "\(root)/shards"
        let metadataDir = "\(root)/metadata"
        let snapshotsDir = "\(root)/snapshots"

        // Create directory structure
        for dir in [shardsDir, metadataDir, snapshotsDir] {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        // Create shard directories and empty SQLite files
        for i in 0..<shards {
            let shardDir = "\(shardsDir)/shard-\(String(format: "%04d", i))"
            try fm.createDirectory(atPath: shardDir, withIntermediateDirectories: true)

            let dbPath = "\(shardDir)/main.sqlite"
            if !fm.fileExists(atPath: dbPath) {
                // Create empty SQLite database with WAL mode
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
                process.arguments = [dbPath, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;"]
                try process.run()
                process.waitUntilExit()
                terminal.print("  ✓ Created shard-\(String(format: "%04d", i))", style: .success)
            } else {
                terminal.print("  · Shard-\(String(format: "%04d", i)) already exists", style: .dim)
            }
        }

        // Write topology metadata
        let topology: [String: Any] = [
            "shardCount": shards,
            "mode": "persistentNodes",
            "createdAt": ISO8601DateFormatter().string(from: Date()),
        ]
        let topologyData = try JSONSerialization.data(withJSONObject: topology, options: [.prettyPrinted, .sortedKeys])
        let topologyPath = "\(metadataDir)/topology.json"
        try topologyData.write(to: URL(fileURLWithPath: topologyPath))

        terminal.print("", style: .info)
        terminal.print("✓ Database initialized at \(root)", style: .success)
    }

    private func resolvePath(_ path: String) -> String {
        if path.hasPrefix("/") { return path }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(path).standardizedFileURL.path
    }
}
