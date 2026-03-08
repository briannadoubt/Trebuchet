import ArgumentParser
import Foundation

struct DBRebalanceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rebalance",
        abstract: "Plan and execute shard rebalancing across nodes"
    )

    @Option(name: .long, help: "Database root directory")
    var dbPath: String = ".trebuchet/db"

    @Option(name: .long, help: "Comma-separated list of target node IDs")
    var nodes: String

    @Flag(name: .long, help: "Show the plan without executing")
    var plan: Bool = false

    @Flag(name: .long, help: "Execute the rebalance plan")
    var apply: Bool = false

    @Flag(name: .shortAndLong, help: "Enable verbose output")
    var verbose: Bool = false

    init() {}

    mutating func run() async throws {
        let terminal = Terminal()
        let metadataPath = "\(dbPath)/metadata"
        let ownershipFile = "\(metadataPath)/ownership.json"

        guard FileManager.default.fileExists(atPath: ownershipFile) else {
            terminal.print("No ownership file found at \(ownershipFile)", style: .error)
            terminal.print("Run 'trebuchet db ownership init' first.", style: .dim)
            throw ExitCode.failure
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: ownershipFile))
        let map = try JSONDecoder().decode(RebalanceOwnershipFile.self, from: data)

        let targetNodes = nodes.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) }

        guard !targetNodes.isEmpty else {
            terminal.print("At least one target node is required (--nodes node1,node2,...)", style: .error)
            throw ExitCode.failure
        }

        // Compute current distribution
        var nodeShards: [String: [Int]] = [:]
        for node in targetNodes {
            nodeShards[node] = []
        }
        for entry in map.shards {
            nodeShards[entry.ownerNodeID, default: []].append(entry.shardID)
        }

        let totalShards = map.shards.count
        let nodeCount = targetNodes.count
        let idealPerNode = totalShards / nodeCount
        let remainder = totalShards % nodeCount

        // Compute target counts
        var targetCounts: [String: Int] = [:]
        let sortedNodes = targetNodes.sorted()
        for (i, node) in sortedNodes.enumerated() {
            targetCounts[node] = idealPerNode + (i < remainder ? 1 : 0)
        }

        // Compute moves
        var moves: [(shardID: Int, source: String, target: String)] = []

        // Find donors and recipients
        var donors: [(String, [Int])] = []
        var recipients: [(String, Int)] = []

        for node in sortedNodes {
            let current = nodeShards[node]?.count ?? 0
            let target = targetCounts[node] ?? idealPerNode
            if current > target {
                let excess = Array((nodeShards[node] ?? []).sorted().suffix(current - target))
                donors.append((node, excess))
            } else if current < target {
                recipients.append((node, target - current))
            }
        }

        // Handle shards on decommissioned nodes
        for (node, shards) in nodeShards where !targetNodes.contains(node) {
            donors.append((node, shards))
        }

        var recipientIdx = 0
        var remainingDeficit = recipients.first?.1 ?? 0

        for (donorNode, excessShards) in donors {
            for shardID in excessShards {
                guard recipientIdx < recipients.count else { break }
                let recipientNode = recipients[recipientIdx].0
                moves.append((shardID: shardID, source: donorNode, target: recipientNode))
                remainingDeficit -= 1
                if remainingDeficit <= 0 {
                    recipientIdx += 1
                    if recipientIdx < recipients.count {
                        remainingDeficit = recipients[recipientIdx].1
                    }
                }
            }
        }

        // Display plan
        terminal.print("", style: .info)
        terminal.print("Rebalance Plan", style: .header)
        terminal.print("  Total shards: \(totalShards)", style: .info)
        terminal.print("  Target nodes: \(targetNodes.joined(separator: ", "))", style: .info)
        terminal.print("  Ideal per node: \(idealPerNode)\(remainder > 0 ? " (+1 for \(remainder) nodes)" : "")", style: .info)
        terminal.print("", style: .info)

        terminal.print("  Current distribution:", style: .info)
        for (node, shards) in nodeShards.sorted(by: { $0.key < $1.key }) {
            terminal.print("    \(node): \(shards.count) shards", style: .dim)
        }
        terminal.print("", style: .info)

        terminal.print("  Target distribution:", style: .info)
        for (node, count) in targetCounts.sorted(by: { $0.key < $1.key }) {
            terminal.print("    \(node): \(count) shards", style: .dim)
        }
        terminal.print("", style: .info)

        if moves.isEmpty {
            terminal.print("  Already balanced. No moves needed.", style: .success)
            return
        }

        terminal.print("  Planned moves (\(moves.count)):", style: .info)
        for move in moves {
            terminal.print("    shard-\(String(format: "%04d", move.shardID)): \(move.source) -> \(move.target)", style: .dim)
        }
        terminal.print("", style: .info)

        if plan || !apply {
            if !apply {
                terminal.print("  Use --apply to execute this plan.", style: .dim)
            }
            return
        }

        // Apply the plan
        terminal.print("Executing rebalance...", style: .header)
        terminal.print("", style: .info)

        var updatedMap = map
        for move in moves {
            guard let idx = updatedMap.shards.firstIndex(where: { $0.shardID == move.shardID }) else {
                terminal.print("  shard-\(String(format: "%04d", move.shardID)): not found in ownership map", style: .error)
                continue
            }

            updatedMap.shards[idx].ownerNodeID = move.target
            updatedMap.shards[idx].epoch = updatedMap.globalEpoch + 1
            updatedMap.shards[idx].lastUpdated = ISO8601DateFormatter().string(from: Date())
            updatedMap.globalEpoch += 1

            terminal.print("  shard-\(String(format: "%04d", move.shardID)): \(move.source) -> \(move.target) (epoch \(updatedMap.globalEpoch))", style: .success)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let updatedData = try encoder.encode(updatedMap)
        try updatedData.write(to: URL(fileURLWithPath: ownershipFile))

        terminal.print("", style: .info)
        terminal.print("Rebalance complete. \(moves.count) shards moved.", style: .success)
        terminal.print("New global epoch: \(updatedMap.globalEpoch)", style: .dim)
    }
}

// Mirror types for CLI (avoids importing TrebuchetSQLite)
private struct RebalanceOwnershipFile: Codable {
    var globalEpoch: UInt64
    var shards: [RebalanceOwnershipEntry]
}

private struct RebalanceOwnershipEntry: Codable {
    var shardID: Int
    var ownerNodeID: String
    var epoch: UInt64
    var status: String
    var lastUpdated: String
}
