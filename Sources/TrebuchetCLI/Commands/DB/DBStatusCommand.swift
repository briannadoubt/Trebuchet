import ArgumentParser
import Foundation

struct DBStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show database storage status and health"
    )

    @Option(name: .long, help: "Database root directory")
    var path: String = ".trebuchet/db"

    @Flag(name: .shortAndLong, help: "Show detailed information")
    var verbose: Bool = false

    mutating func run() async throws {
        let terminal = Terminal()
        let root = resolvePath(path)
        let fm = FileManager.default

        terminal.print("Trebuchet Database Status", style: .header)
        terminal.print("  Root: \(root)", style: .dim)
        terminal.print("", style: .info)

        // Check if initialized
        guard fm.fileExists(atPath: root) else {
            terminal.print("✗ Database not initialized. Run 'trebuchet db init' first.", style: .error)
            return
        }

        // Read topology metadata
        let topologyPath = "\(root)/metadata/topology.json"
        if let data = fm.contents(atPath: topologyPath),
           let topology = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let shardCount = topology["shardCount"] as? Int ?? 0
            let mode = topology["mode"] as? String ?? "unknown"
            terminal.print("  Mode: \(mode)", style: .info)
            terminal.print("  Configured shards: \(shardCount)", style: .info)
        }

        terminal.print("", style: .info)

        // Scan shard directories
        let shardsDir = "\(root)/shards"
        guard fm.fileExists(atPath: shardsDir) else {
            terminal.print("  No shards directory found.", style: .warning)
            return
        }

        let shardDirs = (try? fm.contentsOfDirectory(atPath: shardsDir))?.filter { $0.hasPrefix("shard-") }.sorted() ?? []

        terminal.print("  Shards:", style: .info)
        var totalSize: UInt64 = 0
        var totalWalSize: UInt64 = 0

        for shardName in shardDirs {
            let dbPath = "\(shardsDir)/\(shardName)/main.sqlite"
            let walPath = "\(shardsDir)/\(shardName)/main.sqlite-wal"

            let dbSize = fileSize(dbPath)
            let walSize = fileSize(walPath)
            totalSize += dbSize
            totalWalSize += walSize

            let status = fm.fileExists(atPath: dbPath) ? "✓" : "✗"
            let sizeStr = formatBytes(dbSize)
            let walStr = walSize > 0 ? " (WAL: \(formatBytes(walSize)))" : ""

            terminal.print("    \(status) \(shardName): \(sizeStr)\(walStr)", style: fm.fileExists(atPath: dbPath) ? .success : .error)

            if verbose {
                // Get table count and row counts
                let tableInfo = sqliteQuery(dbPath, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;")
                for table in tableInfo {
                    let countResult = sqliteQuery(dbPath, "SELECT COUNT(*) FROM \"\(table)\";")
                    let count = countResult.first ?? "?"
                    terminal.print("      · \(table): \(count) rows", style: .dim)
                }
            }
        }

        terminal.print("", style: .info)
        terminal.print("  Total: \(formatBytes(totalSize)) data + \(formatBytes(totalWalSize)) WAL", style: .info)

        // Check snapshots
        let snapshotsDir = "\(root)/snapshots"
        if fm.fileExists(atPath: snapshotsDir) {
            let snapshots = (try? fm.contentsOfDirectory(atPath: snapshotsDir))?.sorted() ?? []
            if !snapshots.isEmpty {
                terminal.print("", style: .info)
                terminal.print("  Snapshots: \(snapshots.count)", style: .info)
                if verbose {
                    for snap in snapshots.suffix(5) {
                        let snapPath = "\(snapshotsDir)/\(snap)"
                        let size = fileSize(snapPath)
                        terminal.print("    · \(snap) (\(formatBytes(size)))", style: .dim)
                    }
                }
            }
        }
    }

    private func fileSize(_ path: String) -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? UInt64 ?? 0
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / (1024 * 1024)) }
        return String(format: "%.1f GB", Double(bytes) / (1024 * 1024 * 1024))
    }

    private func sqliteQuery(_ dbPath: String, _ sql: String) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [dbPath, sql]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return output.isEmpty ? [] : output.components(separatedBy: "\n")
        } catch {
            return []
        }
    }

    private func resolvePath(_ path: String) -> String {
        if path.hasPrefix("/") { return path }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(path).standardizedFileURL.path
    }
}
