import ArgumentParser
import Foundation

struct DBSnapshotCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snapshot",
        abstract: "Create a snapshot of shard database files"
    )

    @Option(name: .long, help: "Database root directory")
    var path: String = ".trebuchet/db"

    @Option(name: .long, help: "Specific shard to snapshot (default: all)")
    var shard: Int?

    mutating func run() async throws {
        let terminal = Terminal()
        let root = resolvePath(path)
        let fm = FileManager.default

        terminal.print("Creating database snapshot...", style: .header)

        let shardsDir = "\(root)/shards"
        guard fm.fileExists(atPath: shardsDir) else {
            terminal.print("✗ No shards directory found.", style: .error)
            return
        }

        let snapshotsDir = "\(root)/snapshots"
        try fm.createDirectory(atPath: snapshotsDir, withIntermediateDirectories: true)

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let snapshotDir = "\(snapshotsDir)/\(timestamp)"
        try fm.createDirectory(atPath: snapshotDir, withIntermediateDirectories: true)

        let shardDirs: [String]
        if let specificShard = shard {
            let name = "shard-\(String(format: "%04d", specificShard))"
            shardDirs = [name]
        } else {
            shardDirs = ((try? fm.contentsOfDirectory(atPath: shardsDir))?.filter { $0.hasPrefix("shard-") }.sorted()) ?? []
        }

        for shardName in shardDirs {
            let dbPath = "\(shardsDir)/\(shardName)/main.sqlite"
            guard fm.fileExists(atPath: dbPath) else {
                terminal.print("  ✗ \(shardName): no database file", style: .error)
                continue
            }

            // Checkpoint WAL before snapshot
            _ = sqliteExec(dbPath, "PRAGMA wal_checkpoint(TRUNCATE);")

            // Copy the database file
            let destDir = "\(snapshotDir)/\(shardName)"
            try fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)
            let destPath = "\(destDir)/main.sqlite"

            // Use sqlite3 .backup for a consistent copy
            let backupResult = sqliteExec(dbPath, ".backup '\(destPath)'")
            if backupResult {
                let size = fileSize(destPath)
                terminal.print("  ✓ \(shardName): \(formatBytes(size))", style: .success)
            } else {
                // Fallback to file copy
                try fm.copyItem(atPath: dbPath, toPath: destPath)
                terminal.print("  ✓ \(shardName): copied (file-level)", style: .success)
            }
        }

        terminal.print("", style: .info)
        terminal.print("✓ Snapshot saved to \(snapshotDir)", style: .success)
    }

    private func sqliteExec(_ dbPath: String, _ sql: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [dbPath, sql]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func fileSize(_ path: String) -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? UInt64 ?? 0
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    private func resolvePath(_ path: String) -> String {
        if path.hasPrefix("/") { return path }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(path).standardizedFileURL.path
    }
}
