import ArgumentParser
import Foundation

struct DBRestoreCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore",
        abstract: "Restore database from a snapshot"
    )

    @Option(name: .long, help: "Database root directory")
    var path: String = ".trebuchet/db"

    @Argument(help: "Snapshot path or name (from snapshots directory)")
    var snapshot: String

    @Flag(name: .long, help: "Overwrite existing shard files without confirmation")
    var force: Bool = false

    mutating func run() async throws {
        let terminal = Terminal()
        let root = resolvePath(path)
        let fm = FileManager.default

        // Resolve snapshot path
        let snapshotPath: String
        if snapshot.hasPrefix("/") {
            snapshotPath = snapshot
        } else {
            snapshotPath = "\(root)/snapshots/\(snapshot)"
        }

        guard fm.fileExists(atPath: snapshotPath) else {
            terminal.print("✗ Snapshot not found at \(snapshotPath)", style: .error)

            // List available snapshots
            let snapshotsDir = "\(root)/snapshots"
            if let available = try? fm.contentsOfDirectory(atPath: snapshotsDir).sorted() {
                terminal.print("", style: .info)
                terminal.print("Available snapshots:", style: .info)
                for snap in available {
                    terminal.print("  · \(snap)", style: .dim)
                }
            }
            return
        }

        terminal.print("Restoring from snapshot...", style: .header)
        terminal.print("  Source: \(snapshotPath)", style: .dim)
        terminal.print("  Target: \(root)/shards/", style: .dim)
        terminal.print("", style: .info)

        let shardsDir = "\(root)/shards"

        // Find shard directories in snapshot
        let snapshotShards = ((try? fm.contentsOfDirectory(atPath: snapshotPath))?.filter { $0.hasPrefix("shard-") }.sorted()) ?? []

        guard !snapshotShards.isEmpty else {
            terminal.print("✗ No shard directories found in snapshot.", style: .error)
            return
        }

        for shardName in snapshotShards {
            let srcPath = "\(snapshotPath)/\(shardName)/main.sqlite"
            let destDir = "\(shardsDir)/\(shardName)"
            let destPath = "\(destDir)/main.sqlite"

            guard fm.fileExists(atPath: srcPath) else {
                terminal.print("  ✗ \(shardName): no main.sqlite in snapshot", style: .error)
                continue
            }

            try fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)

            // Remove existing files
            for ext in ["", "-wal", "-shm"] {
                let existing = destPath + ext
                if fm.fileExists(atPath: existing) {
                    try fm.removeItem(atPath: existing)
                }
            }

            try fm.copyItem(atPath: srcPath, toPath: destPath)
            terminal.print("  ✓ \(shardName): restored", style: .success)
        }

        terminal.print("", style: .info)
        terminal.print("✓ Restore complete. Run 'trebuchet db doctor' to verify.", style: .success)
    }

    private func resolvePath(_ path: String) -> String {
        if path.hasPrefix("/") { return path }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(path).standardizedFileURL.path
    }
}
