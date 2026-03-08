import ArgumentParser
import Foundation

struct DBCompactCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compact",
        abstract: "Compact database files (VACUUM and WAL checkpoint)"
    )

    @Option(name: .long, help: "Database root directory")
    var path: String = ".trebuchet/db"

    @Option(name: .long, help: "Specific shard to compact (default: all)")
    var shard: Int?

    @Flag(name: .long, help: "Run VACUUM (reclaims disk space, takes longer)")
    var vacuum: Bool = false

    mutating func run() async throws {
        let terminal = Terminal()
        let root = resolvePath(path)
        let fm = FileManager.default

        terminal.print("Compacting database...", style: .header)

        let shardsDir = "\(root)/shards"
        guard fm.fileExists(atPath: shardsDir) else {
            terminal.print("✗ No shards directory found.", style: .error)
            return
        }

        let shardDirs: [String]
        if let specificShard = shard {
            shardDirs = ["shard-\(String(format: "%04d", specificShard))"]
        } else {
            shardDirs = ((try? fm.contentsOfDirectory(atPath: shardsDir))?.filter { $0.hasPrefix("shard-") }.sorted()) ?? []
        }

        for shardName in shardDirs {
            let dbPath = "\(shardsDir)/\(shardName)/main.sqlite"
            guard fm.fileExists(atPath: dbPath) else {
                terminal.print("  ✗ \(shardName): no database file", style: .error)
                continue
            }

            let sizeBefore = fileSize(dbPath) + fileSize(dbPath + "-wal")

            // WAL checkpoint
            _ = sqliteExec(dbPath, "PRAGMA wal_checkpoint(TRUNCATE);")

            if vacuum {
                _ = sqliteExec(dbPath, "VACUUM;")
            }

            let sizeAfter = fileSize(dbPath) + fileSize(dbPath + "-wal")
            let saved = sizeBefore > sizeAfter ? sizeBefore - sizeAfter : 0

            terminal.print("  ✓ \(shardName): \(formatBytes(sizeBefore)) → \(formatBytes(sizeAfter)) (saved \(formatBytes(saved)))", style: .success)
        }

        terminal.print("", style: .info)
        terminal.print("✓ Compaction complete.", style: .success)
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
