import Foundation

// MARK: - ShardMigrationStatus

/// Represents the migration status of a shard.
public enum ShardMigrationStatus: Codable, Sendable, Equatable {
    /// Normal operation — the shard is serving reads and writes.
    case active
    /// The shard is being moved to another node.
    case migrating(targetNodeID: String)
    /// The shard is quiescing writes before a snapshot is taken.
    /// Preserves the target node ID so `completeMigration` can still read it.
    case draining(targetNodeID: String)

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case type
        case targetNodeID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "active":
            self = .active
        case "migrating":
            let target = try container.decode(String.self, forKey: .targetNodeID)
            self = .migrating(targetNodeID: target)
        case "draining":
            let target = try container.decode(String.self, forKey: .targetNodeID)
            self = .draining(targetNodeID: target)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown shard migration status: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .active:
            try container.encode("active", forKey: .type)
        case .migrating(let targetNodeID):
            try container.encode("migrating", forKey: .type)
            try container.encode(targetNodeID, forKey: .targetNodeID)
        case .draining(let targetNodeID):
            try container.encode("draining", forKey: .type)
            try container.encode(targetNodeID, forKey: .targetNodeID)
        }
    }

    /// The target node ID, if this shard is migrating or draining.
    public var targetNodeID: String? {
        switch self {
        case .active: return nil
        case .migrating(let id): return id
        case .draining(let id): return id
        }
    }
}

// MARK: - ShardOwnershipRecord

/// A record describing which node owns a given shard and its current lifecycle status.
public struct ShardOwnershipRecord: Codable, Sendable {
    /// The numeric identifier of the shard.
    public var shardID: Int
    /// The node that currently owns this shard.
    public var ownerNodeID: String
    /// Monotonically increasing epoch that gates routing decisions.
    public var epoch: UInt64
    /// The current migration status of the shard.
    public var status: ShardMigrationStatus
    /// When this record was last modified.
    public var lastUpdated: Date

    public init(
        shardID: Int,
        ownerNodeID: String,
        epoch: UInt64,
        status: ShardMigrationStatus,
        lastUpdated: Date
    ) {
        self.shardID = shardID
        self.ownerNodeID = ownerNodeID
        self.epoch = epoch
        self.status = status
        self.lastUpdated = lastUpdated
    }
}

// MARK: - Persistence Model

/// On-disk representation of the full ownership map (`ownership.json`).
private struct OwnershipFile: Codable {
    var globalEpoch: UInt64
    var shards: [ShardOwnershipRecord]
}

// MARK: - ShardOwnershipMap

/// Manages the complete shard-ownership state for a single node.
///
/// Ownership records are persisted to `{metadataPath}/ownership.json` and loaded
/// back on startup. Every mutation bumps the relevant record's epoch and updates
/// the timestamp so downstream routers can detect stale assignments.
public actor ShardOwnershipMap {

    /// The identifier of this node.
    public let nodeID: String

    /// In-memory ownership table keyed by shard ID.
    public private(set) var records: [Int: ShardOwnershipRecord]

    /// Cluster-wide epoch that is bumped on every ownership change.
    public private(set) var globalEpoch: UInt64

    /// Alias for `globalEpoch` used by the migration coordinator.
    public var currentEpoch: UInt64 { globalEpoch }

    /// Filesystem directory where `ownership.json` is stored.
    public let metadataPath: String

    // MARK: Initializer

    public init(nodeID: String, metadataPath: String) {
        self.nodeID = nodeID
        self.metadataPath = metadataPath
        self.records = [:]
        self.globalEpoch = 0
    }

    // MARK: Persistence

    private var ownershipFileURL: URL {
        URL(fileURLWithPath: metadataPath)
            .appendingPathComponent("ownership.json")
    }

    /// Loads ownership state from `ownership.json` in `metadataPath`.
    public func load() throws {
        let data = try Data(contentsOf: ownershipFileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(OwnershipFile.self, from: data)
        self.records = file.shards.reduce(into: [:]) { map, record in
            map[record.shardID] = record
        }
        self.globalEpoch = file.globalEpoch
    }

    /// Writes the current ownership state to `ownership.json` in `metadataPath`.
    public func save() throws {
        let file = OwnershipFile(
            globalEpoch: globalEpoch,
            shards: records.values.sorted { $0.shardID < $1.shardID }
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)

        let directoryURL = URL(fileURLWithPath: metadataPath)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try data.write(to: ownershipFileURL, options: .atomic)
    }

    // MARK: Queries

    /// Returns the node ID that owns the given shard, or `nil` if unassigned.
    public func ownerNode(for shardID: Int) -> String? {
        records[shardID]?.ownerNodeID
    }

    /// Returns `true` when this node owns the given shard.
    public func isLocallyOwned(_ shardID: Int) -> Bool {
        records[shardID]?.ownerNodeID == nodeID
    }

    /// Returns all ownership records, ordered by shard ID.
    public func allShards() -> [ShardOwnershipRecord] {
        records.values.sorted { $0.shardID < $1.shardID }
    }

    /// Returns all ownership records where the owner matches `nodeID`.
    public func shardsOnNode(_ nodeID: String) -> [ShardOwnershipRecord] {
        records.values
            .filter { $0.ownerNodeID == nodeID }
            .sorted { $0.shardID < $1.shardID }
    }

    // MARK: Mutations

    /// Assigns `shardID` to `nodeID`, setting status to `.active` and bumping the epoch.
    public func assignShard(_ shardID: Int, to nodeID: String) throws {
        globalEpoch += 1
        records[shardID] = ShardOwnershipRecord(
            shardID: shardID,
            ownerNodeID: nodeID,
            epoch: globalEpoch,
            status: .active,
            lastUpdated: Date()
        )
    }

    /// Transitions the shard to `.migrating` toward `targetNodeID`.
    ///
    /// - Throws: If the shard does not exist.
    public func beginMigration(shardID: Int, targetNodeID: String) throws {
        guard var record = records[shardID] else {
            throw ShardOwnershipError.shardNotFound(shardID)
        }
        record.status = .migrating(targetNodeID: targetNodeID)
        record.lastUpdated = Date()
        records[shardID] = record
    }

    /// Transitions the shard to `.draining` so writes can quiesce before a snapshot.
    /// Preserves the migration target node ID from the `.migrating` state.
    ///
    /// - Throws: If the shard does not exist or is not currently migrating.
    public func beginDrain(shardID: Int) throws {
        guard var record = records[shardID] else {
            throw ShardOwnershipError.shardNotFound(shardID)
        }
        guard case .migrating(let targetNodeID) = record.status else {
            throw ShardOwnershipError.notMigrating(shardID)
        }
        record.status = .draining(targetNodeID: targetNodeID)
        record.lastUpdated = Date()
        records[shardID] = record
    }

    /// Completes a migration by flipping the owner to the target node, resetting
    /// status to `.active`, and bumping the global epoch.
    ///
    /// Accepts shards in either `.migrating` or `.draining` state.
    ///
    /// - Throws: If the shard does not exist or is not in a migration-related state.
    public func completeMigration(shardID: Int) throws {
        guard var record = records[shardID] else {
            throw ShardOwnershipError.shardNotFound(shardID)
        }
        guard let targetNodeID = record.status.targetNodeID else {
            throw ShardOwnershipError.notMigrating(shardID)
        }
        globalEpoch += 1
        record.ownerNodeID = targetNodeID
        record.epoch = globalEpoch
        record.status = .active
        record.lastUpdated = Date()
        records[shardID] = record
    }

    /// Rolls back a migration, returning the shard to `.active` on its current owner.
    ///
    /// - Throws: If the shard does not exist.
    public func rollbackMigration(shardID: Int) throws {
        guard var record = records[shardID] else {
            throw ShardOwnershipError.shardNotFound(shardID)
        }
        record.status = .active
        record.lastUpdated = Date()
        records[shardID] = record
    }

    // MARK: Bootstrap

    /// Creates a default ownership map assigning all shards to this node with epoch 0.
    public func initializeDefault(shardCount: Int) {
        globalEpoch = 0
        let now = Date()
        records = (0..<shardCount).reduce(into: [:]) { map, id in
            map[id] = ShardOwnershipRecord(
                shardID: id,
                ownerNodeID: nodeID,
                epoch: 0,
                status: .active,
                lastUpdated: now
            )
        }
    }
}

// MARK: - Errors

/// Errors raised by `ShardOwnershipMap` mutations.
public enum ShardOwnershipError: Error, LocalizedError {
    case shardNotFound(Int)
    case notMigrating(Int)

    public var errorDescription: String? {
        switch self {
        case .shardNotFound(let id):
            return "Shard \(id) not found in the ownership map."
        case .notMigrating(let id):
            return "Shard \(id) is not in a migrating state."
        }
    }
}
