import ArgumentParser
import Foundation

struct DBDoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Validate and diagnose database health"
    )

    @Option(name: .long, help: "Database root directory")
    var path: String = ".trebuchet/db"

    mutating func run() async throws {
        let terminal = Terminal()
        let root = resolvePath(path)
        let fm = FileManager.default
        var issues: [String] = []
        var warnings: [String] = []

        terminal.print("Trebuchet Database Doctor", style: .header)
        terminal.print("  Root: \(root)", style: .dim)
        terminal.print("", style: .info)

        // Check directory exists
        guard fm.fileExists(atPath: root) else {
            terminal.print("✗ Database root not found at \(root)", style: .error)
            terminal.print("  Run 'trebuchet db init --path \(path)' to initialize.", style: .dim)
            return
        }

        // Check metadata
        let topologyPath = "\(root)/metadata/topology.json"
        if fm.fileExists(atPath: topologyPath) {
            terminal.print("  ✓ Topology metadata found", style: .success)
        } else {
            warnings.append("No topology.json found in metadata/")
        }

        // Check shards
        let shardsDir = "\(root)/shards"
        guard fm.fileExists(atPath: shardsDir) else {
            issues.append("No shards/ directory found")
            printSummary(terminal: terminal, issues: issues, warnings: warnings)
            return
        }

        let shardDirs = (try? fm.contentsOfDirectory(atPath: shardsDir))?.filter { $0.hasPrefix("shard-") }.sorted() ?? []

        if shardDirs.isEmpty {
            issues.append("No shard directories found in shards/")
        }

        for shardName in shardDirs {
            let dbPath = "\(shardsDir)/\(shardName)/main.sqlite"

            // Check file exists
            guard fm.fileExists(atPath: dbPath) else {
                issues.append("\(shardName): main.sqlite missing")
                continue
            }

            // Check integrity
            let integrityResult = sqliteQuery(dbPath, "PRAGMA integrity_check;")
            if integrityResult.first == "ok" {
                terminal.print("  ✓ \(shardName): integrity OK", style: .success)
            } else {
                issues.append("\(shardName): integrity check failed: \(integrityResult.joined(separator: ", "))")
            }

            // Check journal mode
            let journalMode = sqliteQuery(dbPath, "PRAGMA journal_mode;")
            if journalMode.first != "wal" {
                warnings.append("\(shardName): journal_mode is '\(journalMode.first ?? "unknown")' (expected 'wal')")
            }

            // Check WAL size
            let walPath = dbPath + "-wal"
            if let attrs = try? fm.attributesOfItem(atPath: walPath),
               let walSize = attrs[.size] as? UInt64, walSize > 50 * 1024 * 1024 {
                warnings.append("\(shardName): WAL file is \(walSize / (1024 * 1024))MB - consider running 'trebuchet db compact'")
            }

            // Check foreign keys
            let fkCheck = sqliteQuery(dbPath, "PRAGMA foreign_key_check;")
            if !fkCheck.isEmpty {
                warnings.append("\(shardName): foreign key violations detected (\(fkCheck.count) issues)")
            }
        }

        // Check snapshots directory
        let snapshotsDir = "\(root)/snapshots"
        if fm.fileExists(atPath: snapshotsDir) {
            terminal.print("  ✓ Snapshots directory exists", style: .success)
        } else {
            terminal.print("  · No snapshots directory (optional)", style: .dim)
        }

        printSummary(terminal: terminal, issues: issues, warnings: warnings)
    }

    private func printSummary(terminal: Terminal, issues: [String], warnings: [String]) {
        terminal.print("", style: .info)

        if !warnings.isEmpty {
            terminal.print("Warnings:", style: .warning)
            for w in warnings {
                terminal.print("  ⚠ \(w)", style: .warning)
            }
            terminal.print("", style: .info)
        }

        if !issues.isEmpty {
            terminal.print("Issues:", style: .error)
            for issue in issues {
                terminal.print("  ✗ \(issue)", style: .error)
            }
        } else {
            terminal.print("✓ No issues detected.", style: .success)
        }
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
