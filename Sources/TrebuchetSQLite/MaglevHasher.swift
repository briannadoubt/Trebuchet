import Foundation

/// Maglev consistent hashing implementation for shard routing.
///
/// Maglev hashing builds a fixed-size lookup table where each slot maps to a shard.
/// When the shard count changes, only ~1/(N+1) of keys remap (vs ~75%+ with modulo).
/// This makes shard expansion operationally feasible without full data migration.
///
/// Algorithm reference: "Maglev: A Fast and Reliable Software Network Load Balancer"
/// (Google, 2016).
public struct MaglevHasher: Sendable {
    /// The lookup table mapping hash slots to shard indices.
    public let lookupTable: [Int]

    /// The prime size of the lookup table.
    public let tableSize: Int

    /// The number of shards.
    public let shardCount: Int

    /// Ordered shard names used to build the table.
    public let shardNames: [String]

    /// Creates a Maglev hasher for the given shard names.
    ///
    /// - Parameters:
    ///   - shardNames: Ordered shard identifiers. The order matters for determinism.
    ///   - tableSize: Prime number for table size. Default 65537 gives good distribution.
    public init(shardNames: [String], tableSize: Int = 65537) {
        precondition(!shardNames.isEmpty, "At least one shard is required")
        precondition(tableSize > 0, "Table size must be positive")

        self.shardNames = shardNames
        self.shardCount = shardNames.count
        self.tableSize = tableSize
        self.lookupTable = Self.buildTable(shardNames: shardNames, tableSize: tableSize)
    }

    /// Look up which shard a key maps to.
    ///
    /// - Parameter key: The key to route (e.g., an actor ID).
    /// - Returns: The shard index (0-based) that owns this key.
    public func shardIndex(for key: String) -> Int {
        let hash = SQLiteShardManager.fnv1a(key)
        let slot = Int(hash % UInt64(tableSize))
        return lookupTable[slot]
    }

    // MARK: - Table Construction

    private static func buildTable(shardNames: [String], tableSize: Int) -> [Int] {
        let n = shardNames.count
        let m = tableSize

        // Compute per-shard permutation parameters
        var offsets = [Int]()
        var skips = [Int]()
        offsets.reserveCapacity(n)
        skips.reserveCapacity(n)

        for name in shardNames {
            let h1 = SQLiteShardManager.fnv1a(name)
            let h2 = Self.djb2(name)
            offsets.append(Int(h1 % UInt64(m)))
            skips.append(Int(h2 % UInt64(m - 1)) + 1)
        }

        // Build lookup table via round-robin population
        var table = [Int](repeating: -1, count: m)
        var next = [Int](repeating: 0, count: n)
        var filled = 0

        while filled < m {
            for i in 0..<n {
                // Find this shard's next preferred unclaimed slot
                var candidate = (offsets[i] + next[i] &* skips[i]) % m
                while table[candidate] != -1 {
                    next[i] += 1
                    candidate = (offsets[i] + next[i] &* skips[i]) % m
                }
                table[candidate] = i
                next[i] += 1
                filled += 1
                if filled == m { break }
            }
        }

        return table
    }

    // MARK: - DJB2 Hash

    /// DJB2 hash — stable, deterministic, independent from FNV-1a.
    /// Used as the second hash function for Maglev permutation generation.
    internal static func djb2(_ string: String) -> UInt64 {
        var hash: UInt64 = 5381
        for byte in string.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)  // hash * 33 + byte
        }
        return hash
    }
}
