import Foundation

/// A planned move of a shard from one node to another
public struct ShardMove: Sendable, Codable {
    public let shardID: Int
    public let sourceNodeID: String
    public let targetNodeID: String

    public init(shardID: Int, sourceNodeID: String, targetNodeID: String) {
        self.shardID = shardID
        self.sourceNodeID = sourceNodeID
        self.targetNodeID = targetNodeID
    }
}

/// A complete rebalance plan
public struct RebalancePlan: Sendable, Codable {
    public let moves: [ShardMove]
    public let nodeShardCounts: [String: Int]  // target distribution
    public let currentDistribution: [String: Int]  // before rebalance

    public var moveCount: Int { moves.count }
    public var isEmpty: Bool { moves.isEmpty }

    public init(moves: [ShardMove], nodeShardCounts: [String: Int], currentDistribution: [String: Int]) {
        self.moves = moves
        self.nodeShardCounts = nodeShardCounts
        self.currentDistribution = currentDistribution
    }
}

/// Computes optimal shard distribution and generates migration plans
public struct RebalancePlanner: Sendable {

    public init() {}

    /// Compute a rebalance plan given current ownership and desired node set.
    ///
    /// Algorithm: greedy leveling
    /// 1. Compute ideal shards-per-node = totalShards / nodeCount
    /// 2. Nodes with more than ideal+1 are "overloaded" (donors)
    /// 3. Nodes with fewer than ideal are "underloaded" (recipients)
    /// 4. Move shards from donors to recipients until balanced
    ///
    /// The plan minimizes total moves while achieving even distribution.
    public func plan(
        currentOwnership: [ShardOwnershipRecord],
        targetNodes: [String]
    ) -> RebalancePlan {
        guard !targetNodes.isEmpty, !currentOwnership.isEmpty else {
            return RebalancePlan(moves: [], nodeShardCounts: [:], currentDistribution: [:])
        }

        let totalShards = currentOwnership.count
        let nodeCount = targetNodes.count
        let idealPerNode = totalShards / nodeCount
        let remainder = totalShards % nodeCount

        // Current distribution
        var nodeShards: [String: [Int]] = [:]
        for node in targetNodes {
            nodeShards[node] = []
        }
        for record in currentOwnership {
            nodeShards[record.ownerNodeID, default: []].append(record.shardID)
        }

        let currentDistribution = nodeShards.mapValues { $0.count }

        // Target counts: first `remainder` nodes get idealPerNode+1, rest get idealPerNode
        var targetCounts: [String: Int] = [:]
        let sortedNodes = targetNodes.sorted()
        for (i, node) in sortedNodes.enumerated() {
            targetCounts[node] = idealPerNode + (i < remainder ? 1 : 0)
        }

        // Compute moves using greedy leveling
        var moves: [ShardMove] = []

        // Find donors (nodes with too many shards) and recipients (too few)
        var donors: [(String, [Int])] = []  // (nodeID, excess shardIDs)
        var recipients: [(String, Int)] = []  // (nodeID, deficit count)

        for node in sortedNodes {
            let current = nodeShards[node]?.count ?? 0
            let target = targetCounts[node] ?? idealPerNode
            if current > target {
                // This node has excess shards to give away
                let excess = Array((nodeShards[node] ?? []).suffix(current - target))
                donors.append((node, excess))
            } else if current < target {
                recipients.append((node, target - current))
            }
        }

        // Also handle shards on nodes not in targetNodes (decommissioned nodes)
        for (node, shards) in nodeShards where !targetNodes.contains(node) {
            donors.append((node, shards))
        }

        // Match donors to recipients
        var recipientIdx = 0
        var remainingDeficit = recipients.first?.1 ?? 0

        for (donorNode, excessShards) in donors {
            for shardID in excessShards {
                guard recipientIdx < recipients.count else { break }
                let recipientNode = recipients[recipientIdx].0

                moves.append(ShardMove(
                    shardID: shardID,
                    sourceNodeID: donorNode,
                    targetNodeID: recipientNode
                ))

                remainingDeficit -= 1
                if remainingDeficit <= 0 {
                    recipientIdx += 1
                    if recipientIdx < recipients.count {
                        remainingDeficit = recipients[recipientIdx].1
                    }
                }
            }
        }

        return RebalancePlan(
            moves: moves,
            nodeShardCounts: targetCounts,
            currentDistribution: currentDistribution
        )
    }

    /// Plan for adding a new node to the cluster
    public func planNodeAddition(
        currentOwnership: [ShardOwnershipRecord],
        existingNodes: [String],
        newNodeID: String
    ) -> RebalancePlan {
        var allNodes = existingNodes
        if !allNodes.contains(newNodeID) {
            allNodes.append(newNodeID)
        }
        return plan(currentOwnership: currentOwnership, targetNodes: allNodes)
    }

    /// Plan for removing a node from the cluster
    public func planNodeRemoval(
        currentOwnership: [ShardOwnershipRecord],
        allNodes: [String],
        removedNodeID: String
    ) -> RebalancePlan {
        let remainingNodes = allNodes.filter { $0 != removedNodeID }
        return plan(currentOwnership: currentOwnership, targetNodes: remainingNodes)
    }
}
