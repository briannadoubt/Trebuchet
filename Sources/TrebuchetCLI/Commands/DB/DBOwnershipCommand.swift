import ArgumentParser
import Foundation

struct DBOwnershipCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ownership",
        abstract: "View and manage shard ownership",
        subcommands: [ShowSubcommand.self, SetSubcommand.self, InitSubcommand.self],
        defaultSubcommand: ShowSubcommand.self
    )

    init() {}

    struct ShowSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "show", abstract: "Show current shard ownership map")

        @Option(name: .long, help: "Database root directory")
        var dbPath: String = ".trebuchet/db"

        @Flag(name: .shortAndLong, help: "Show detailed information")
        var verbose: Bool = false

        init() {}

        mutating func run() async throws {
            let terminal = Terminal()
            let metadataPath = "\(dbPath)/metadata"
            let ownershipFile = "\(metadataPath)/ownership.json"

            guard FileManager.default.fileExists(atPath: ownershipFile) else {
                terminal.print("No ownership file found at \(ownershipFile)", style: .warning)
                terminal.print("Run 'trebuchet db ownership init' to create one.", style: .dim)
                return
            }

            let data = try Data(contentsOf: URL(fileURLWithPath: ownershipFile))
            let map = try JSONDecoder().decode(OwnershipFile.self, from: data)

            terminal.print("", style: .info)
            terminal.print("Shard Ownership Map", style: .header)
            terminal.print("  Global epoch: \(map.globalEpoch)", style: .info)
            terminal.print("", style: .info)

            // Group by node
            var nodeShards: [String: [OwnershipEntry]] = [:]
            for entry in map.shards {
                nodeShards[entry.ownerNodeID, default: []].append(entry)
            }

            for (node, shards) in nodeShards.sorted(by: { $0.key < $1.key }) {
                let shardIDs = shards.map { String($0.shardID) }.joined(separator: ", ")
                terminal.print("  Node \(node): \(shards.count) shards [\(shardIDs)]", style: .info)

                if verbose {
                    for shard in shards.sorted(by: { $0.shardID < $1.shardID }) {
                        let statusStr: String
                        switch shard.status {
                        case "active": statusStr = "active"
                        case let s where s.hasPrefix("migrating"): statusStr = s
                        case "draining": statusStr = "draining"
                        default: statusStr = shard.status
                        }
                        terminal.print("    shard-\(String(format: "%04d", shard.shardID)): epoch=\(shard.epoch) status=\(statusStr)", style: .dim)
                    }
                }
            }

            // Show any migrating shards
            let migrating = map.shards.filter { $0.status != "active" }
            if !migrating.isEmpty {
                terminal.print("", style: .info)
                terminal.print("In-flight migrations:", style: .warning)
                for shard in migrating {
                    terminal.print("  shard-\(String(format: "%04d", shard.shardID)): \(shard.status)", style: .warning)
                }
            }

            terminal.print("", style: .info)
        }
    }

    struct SetSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "set", abstract: "Manually assign a shard to a node")

        @Option(name: .long, help: "Database root directory")
        var dbPath: String = ".trebuchet/db"

        @Argument(help: "Shard ID to reassign")
        var shardID: Int

        @Argument(help: "Target node ID")
        var nodeID: String

        init() {}

        mutating func run() async throws {
            let terminal = Terminal()
            let metadataPath = "\(dbPath)/metadata"
            let ownershipFile = "\(metadataPath)/ownership.json"

            guard FileManager.default.fileExists(atPath: ownershipFile) else {
                terminal.print("No ownership file found. Run 'trebuchet db ownership init' first.", style: .error)
                throw ExitCode.failure
            }

            var data = try Data(contentsOf: URL(fileURLWithPath: ownershipFile))
            var map = try JSONDecoder().decode(OwnershipFile.self, from: data)

            guard let idx = map.shards.firstIndex(where: { $0.shardID == shardID }) else {
                terminal.print("Shard \(shardID) not found in ownership map.", style: .error)
                throw ExitCode.failure
            }

            let oldOwner = map.shards[idx].ownerNodeID
            map.shards[idx].ownerNodeID = nodeID
            map.shards[idx].epoch = map.globalEpoch + 1
            map.shards[idx].status = "active"
            map.shards[idx].lastUpdated = ISO8601DateFormatter().string(from: Date())
            map.globalEpoch += 1

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(map)
            try data.write(to: URL(fileURLWithPath: ownershipFile))

            terminal.print("Reassigned shard \(shardID): \(oldOwner) -> \(nodeID) (epoch \(map.globalEpoch))", style: .success)
        }
    }

    struct InitSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "init", abstract: "Initialize ownership map for all shards")

        @Option(name: .long, help: "Database root directory")
        var dbPath: String = ".trebuchet/db"

        @Option(name: .long, help: "Node ID to assign all shards to")
        var nodeID: String = "local"

        @Option(name: .long, help: "Number of shards")
        var shardCount: Int = 1

        init() {}

        mutating func run() async throws {
            let terminal = Terminal()
            let metadataPath = "\(dbPath)/metadata"
            let ownershipFile = "\(metadataPath)/ownership.json"

            try FileManager.default.createDirectory(atPath: metadataPath, withIntermediateDirectories: true)

            // Detect shard count from existing directory if available
            let shardsDir = "\(dbPath)/shards"
            var detectedCount = shardCount
            if FileManager.default.fileExists(atPath: shardsDir) {
                let contents = try FileManager.default.contentsOfDirectory(atPath: shardsDir)
                let shardDirs = contents.filter { $0.hasPrefix("shard-") }
                if !shardDirs.isEmpty {
                    detectedCount = shardDirs.count
                    terminal.print("Detected \(detectedCount) existing shards.", style: .dim)
                }
            }

            let now = ISO8601DateFormatter().string(from: Date())
            var shards: [OwnershipEntry] = []
            for i in 0..<detectedCount {
                shards.append(OwnershipEntry(
                    shardID: i,
                    ownerNodeID: nodeID,
                    epoch: 0,
                    status: "active",
                    lastUpdated: now
                ))
            }

            let map = OwnershipFile(globalEpoch: 0, shards: shards)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(map)
            try data.write(to: URL(fileURLWithPath: ownershipFile))

            terminal.print("Initialized ownership map: \(detectedCount) shards assigned to '\(nodeID)'", style: .success)
        }
    }
}

// MARK: - Codable types for reading/writing ownership.json from CLI
// (These mirror the TrebuchetSQLite types but avoid importing the module)

private struct OwnershipFile: Codable {
    var globalEpoch: UInt64
    var shards: [OwnershipEntry]
}

private struct OwnershipEntry: Codable {
    var shardID: Int
    var ownerNodeID: String
    var epoch: UInt64
    var status: String
    var lastUpdated: String
}
