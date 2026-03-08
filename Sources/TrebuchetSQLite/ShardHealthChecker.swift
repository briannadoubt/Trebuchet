import Foundation
import GRDB

/// Overall health status
public enum HealthStatus: String, Sendable, Codable {
    case healthy
    case degraded
    case unhealthy
}

/// Health report for a single shard
public struct ShardHealthReport: Sendable {
    public let shardID: Int
    public let status: HealthStatus
    public let isOpen: Bool
    public let fileSizeBytes: UInt64
    public let walSizeBytes: UInt64
    public let integrityOK: Bool
    public let walModeCorrect: Bool
    public let foreignKeysOK: Bool
    public let migrationStatus: String  // "active", "migrating", "draining"
    public let warnings: [String]

    public init(
        shardID: Int,
        status: HealthStatus,
        isOpen: Bool,
        fileSizeBytes: UInt64,
        walSizeBytes: UInt64,
        integrityOK: Bool,
        walModeCorrect: Bool,
        foreignKeysOK: Bool,
        migrationStatus: String,
        warnings: [String]
    ) {
        self.shardID = shardID
        self.status = status
        self.isOpen = isOpen
        self.fileSizeBytes = fileSizeBytes
        self.walSizeBytes = walSizeBytes
        self.integrityOK = integrityOK
        self.walModeCorrect = walModeCorrect
        self.foreignKeysOK = foreignKeysOK
        self.migrationStatus = migrationStatus
        self.warnings = warnings
    }
}

/// Cluster-wide health report
public struct StorageHealthReport: Sendable {
    public let nodeID: String
    public let overallStatus: HealthStatus
    public let shardReports: [ShardHealthReport]
    public let totalShards: Int
    public let openShards: Int
    public let healthyShards: Int
    public let totalFileSizeBytes: UInt64
    public let totalWalSizeBytes: UInt64
    public let checkedAt: Date

    public init(
        nodeID: String,
        overallStatus: HealthStatus,
        shardReports: [ShardHealthReport],
        totalShards: Int,
        openShards: Int,
        healthyShards: Int,
        totalFileSizeBytes: UInt64,
        totalWalSizeBytes: UInt64,
        checkedAt: Date
    ) {
        self.nodeID = nodeID
        self.overallStatus = overallStatus
        self.shardReports = shardReports
        self.totalShards = totalShards
        self.openShards = openShards
        self.healthyShards = healthyShards
        self.totalFileSizeBytes = totalFileSizeBytes
        self.totalWalSizeBytes = totalWalSizeBytes
        self.checkedAt = checkedAt
    }
}

/// Checks health of all shards and produces reports.
public actor ShardHealthChecker {
    private let shardManager: SQLiteShardManager
    private let ownership: ShardOwnershipMap
    private let walSizeWarningThreshold: UInt64

    public init(
        shardManager: SQLiteShardManager,
        ownership: ShardOwnershipMap,
        walSizeWarningThreshold: UInt64 = 50 * 1024 * 1024  // 50 MB
    ) {
        self.shardManager = shardManager
        self.ownership = ownership
        self.walSizeWarningThreshold = walSizeWarningThreshold
    }

    /// Run a full health check across all owned shards.
    public func checkHealth() async -> StorageHealthReport {
        let nodeID = await ownership.nodeID
        let allShards = await ownership.allShards()
        var shardReports: [ShardHealthReport] = []

        for record in allShards {
            let report = await checkShard(record)
            shardReports.append(report)
        }

        let openCount = shardReports.filter { $0.isOpen }.count
        let healthyCount = shardReports.filter { $0.status == .healthy }.count
        let totalFile = shardReports.reduce(UInt64(0)) { $0 + $1.fileSizeBytes }
        let totalWal = shardReports.reduce(UInt64(0)) { $0 + $1.walSizeBytes }

        let overall: HealthStatus
        if healthyCount == shardReports.count {
            overall = .healthy
        } else if healthyCount > 0 {
            overall = .degraded
        } else {
            overall = .unhealthy
        }

        return StorageHealthReport(
            nodeID: nodeID,
            overallStatus: overall,
            shardReports: shardReports,
            totalShards: allShards.count,
            openShards: openCount,
            healthyShards: healthyCount,
            totalFileSizeBytes: totalFile,
            totalWalSizeBytes: totalWal,
            checkedAt: Date()
        )
    }

    /// Check health of a single shard.
    public func checkShard(_ shardID: Int) async -> ShardHealthReport {
        let allShards = await ownership.allShards()
        guard let record = allShards.first(where: { $0.shardID == shardID }) else {
            return ShardHealthReport(
                shardID: shardID,
                status: .unhealthy,
                isOpen: false,
                fileSizeBytes: 0,
                walSizeBytes: 0,
                integrityOK: false,
                walModeCorrect: false,
                foreignKeysOK: false,
                migrationStatus: "unknown",
                warnings: ["Shard not found in ownership map"]
            )
        }
        return await checkShard(record)
    }

    // MARK: - Private

    private func checkShard(_ record: ShardOwnershipRecord) async -> ShardHealthReport {
        let shardID = record.shardID
        var warnings: [String] = []
        var integrityOK = true
        var walModeCorrect = true
        var foreignKeysOK = true
        var isOpen = false

        // Get file sizes
        let path = await shardManager.shardPath(shardID)
        let fm = FileManager.default
        let fileSizeBytes = (try? fm.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
        let walPath = path + "-wal"
        let walSizeBytes = (try? fm.attributesOfItem(atPath: walPath)[.size] as? UInt64) ?? 0

        // Check WAL size
        if walSizeBytes > walSizeWarningThreshold {
            warnings.append("WAL size (\(walSizeBytes) bytes) exceeds threshold (\(walSizeWarningThreshold) bytes)")
        }

        // Migration status
        let migrationStatus: String
        switch record.status {
        case .active: migrationStatus = "active"
        case .migrating(let target):
            migrationStatus = "migrating(\(target))"
            warnings.append("Shard is being migrated to \(target)")
        case .draining(let target):
            migrationStatus = "draining(\(target))"
            warnings.append("Shard is draining (writes quiesced, target: \(target))")
        }

        // Try to open and check integrity
        if let pool = try? await shardManager.openShard(shardID) {
            isOpen = true

            do {
                let checkResult = try await pool.read { db -> (integrity: String?, journal: String?, fk: Int?) in
                    let integrity = try String.fetchOne(db, sql: "PRAGMA integrity_check(1)")
                    let journal = try String.fetchOne(db, sql: "PRAGMA journal_mode")
                    let fk = try Int.fetchOne(db, sql: "PRAGMA foreign_keys")
                    return (integrity, journal, fk)
                }

                if checkResult.integrity != "ok" {
                    integrityOK = false
                    warnings.append("Integrity check failed: \(checkResult.integrity ?? "unknown")")
                }
                if checkResult.journal != "wal" {
                    walModeCorrect = false
                    warnings.append("Expected WAL mode, found: \(checkResult.journal ?? "unknown")")
                }
                if checkResult.fk != 1 {
                    foreignKeysOK = false
                    warnings.append("Foreign keys not enabled")
                }
            } catch {
                integrityOK = false
                warnings.append("Failed to read shard: \(error.localizedDescription)")
            }
        } else {
            warnings.append("Could not open shard database")
        }

        // Determine overall status
        let status: HealthStatus
        if !integrityOK {
            status = .unhealthy
        } else if !warnings.isEmpty {
            status = .degraded
        } else {
            status = .healthy
        }

        return ShardHealthReport(
            shardID: shardID,
            status: status,
            isOpen: isOpen,
            fileSizeBytes: fileSizeBytes,
            walSizeBytes: walSizeBytes,
            integrityOK: integrityOK,
            walModeCorrect: walModeCorrect,
            foreignKeysOK: foreignKeysOK,
            migrationStatus: migrationStatus,
            warnings: warnings
        )
    }
}
