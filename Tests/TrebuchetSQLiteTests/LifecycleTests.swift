import Testing
import Foundation
@testable import TrebuchetSQLite

// MARK: - Test Helpers

private func makeTempDir() -> String {
    let path = NSTemporaryDirectory() + "trebuchet-lifecycle-test-\(UUID().uuidString)"
    try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

private func cleanup(_ path: String) {
    try? FileManager.default.removeItem(atPath: path)
}

/// Collects lifecycle events for test assertions.
final class EventCollector: @unchecked Sendable {
    var events: [StorageLifecycleEvent] = []
    func collect(_ event: StorageLifecycleEvent) {
        events.append(event)
    }
}

// MARK: - StorageLifecycleManager Tests

@Suite("StorageLifecycleManager Tests")
struct StorageLifecycleManagerTests {

    @Test("Start lifecycle transitions to active phase")
    func testStartLifecycle() async throws {
        let tmpDir = makeTempDir()
        defer { cleanup(tmpDir) }

        let config = StorageLifecycleConfiguration(
            root: tmpDir,
            shardCount: 2,
            nodeID: "node-1",
            checkpointOnShutdown: false,
            verifyIntegrityOnBootstrap: false
        )
        let storageConfig = SQLiteStorageConfiguration(root: tmpDir, shardCount: 2)
        let manager = SQLiteShardManager(configuration: storageConfig)
        let ownership = ShardOwnershipMap(nodeID: "node-1", metadataPath: "\(tmpDir)/metadata")

        let lifecycle = StorageLifecycleManager(
            configuration: config,
            shardManager: manager,
            ownership: ownership
        )

        try await lifecycle.start()

        let phase = await lifecycle.phase
        #expect(phase == .active)
    }

    @Test("Shutdown lifecycle transitions to shutdown phase")
    func testShutdownLifecycle() async throws {
        let tmpDir = makeTempDir()
        defer { cleanup(tmpDir) }

        let config = StorageLifecycleConfiguration(
            root: tmpDir,
            shardCount: 2,
            nodeID: "node-1",
            checkpointOnShutdown: false,
            verifyIntegrityOnBootstrap: false
        )
        let storageConfig = SQLiteStorageConfiguration(root: tmpDir, shardCount: 2)
        let manager = SQLiteShardManager(configuration: storageConfig)
        let ownership = ShardOwnershipMap(nodeID: "node-1", metadataPath: "\(tmpDir)/metadata")

        let lifecycle = StorageLifecycleManager(
            configuration: config,
            shardManager: manager,
            ownership: ownership
        )

        try await lifecycle.start()
        try await lifecycle.shutdown()

        let phase = await lifecycle.phase
        #expect(phase == .shutdown)
    }

    @Test("Bootstrap creates ownership file when none exists")
    func testBootstrapCreatesOwnership() async throws {
        let tmpDir = makeTempDir()
        defer { cleanup(tmpDir) }

        let metadataPath = "\(tmpDir)/metadata"
        let config = StorageLifecycleConfiguration(
            root: tmpDir,
            shardCount: 4,
            nodeID: "node-1",
            checkpointOnShutdown: false,
            verifyIntegrityOnBootstrap: false
        )
        let storageConfig = SQLiteStorageConfiguration(root: tmpDir, shardCount: 4)
        let manager = SQLiteShardManager(configuration: storageConfig)
        let ownership = ShardOwnershipMap(nodeID: "node-1", metadataPath: metadataPath)

        let lifecycle = StorageLifecycleManager(
            configuration: config,
            shardManager: manager,
            ownership: ownership
        )

        // No ownership.json exists yet
        let ownershipFile = "\(metadataPath)/ownership.json"
        #expect(!FileManager.default.fileExists(atPath: ownershipFile))

        try await lifecycle.start()

        // After bootstrap, ownership should have been saved
        let records = await ownership.allShards()
        #expect(records.count == 4)
        for record in records {
            #expect(record.ownerNodeID == "node-1")
        }
    }

    @Test("Recover shard completes without errors")
    func testRecoverShard() async throws {
        let tmpDir = makeTempDir()
        defer { cleanup(tmpDir) }

        let config = StorageLifecycleConfiguration(
            root: tmpDir,
            shardCount: 2,
            nodeID: "node-1",
            checkpointOnShutdown: false,
            verifyIntegrityOnBootstrap: false
        )
        let storageConfig = SQLiteStorageConfiguration(root: tmpDir, shardCount: 2)
        let manager = SQLiteShardManager(configuration: storageConfig)
        let ownership = ShardOwnershipMap(nodeID: "node-1", metadataPath: "\(tmpDir)/metadata")

        let lifecycle = StorageLifecycleManager(
            configuration: config,
            shardManager: manager,
            ownership: ownership
        )

        try await lifecycle.start()

        // Recover shard 0 — should not throw
        try await lifecycle.recoverShard(0)
    }

    @Test("Lifecycle events are emitted during start and shutdown")
    func testLifecycleEvents() async throws {
        let tmpDir = makeTempDir()
        defer { cleanup(tmpDir) }

        let config = StorageLifecycleConfiguration(
            root: tmpDir,
            shardCount: 1,
            nodeID: "node-1",
            checkpointOnShutdown: false,
            verifyIntegrityOnBootstrap: false
        )
        let storageConfig = SQLiteStorageConfiguration(root: tmpDir, shardCount: 1)
        let manager = SQLiteShardManager(configuration: storageConfig)
        let ownership = ShardOwnershipMap(nodeID: "node-1", metadataPath: "\(tmpDir)/metadata")

        let lifecycle = StorageLifecycleManager(
            configuration: config,
            shardManager: manager,
            ownership: ownership
        )

        let collector = EventCollector()
        await lifecycle.onEvent { event in
            collector.collect(event)
        }

        try await lifecycle.start()
        try await lifecycle.shutdown()

        // Should have phase change events for bootstrapping, active, shuttingDown, shutdown
        let phaseEvents = collector.events.compactMap { event -> (StorageLifecyclePhase, StorageLifecyclePhase)? in
            if case .phaseChanged(let from, let to) = event {
                return (from, to)
            }
            return nil
        }

        #expect(phaseEvents.count >= 3)

        // First phase change should be to bootstrapping
        #expect(phaseEvents[0].1 == .bootstrapping)

        // Should transition to active
        let activatedEvent = phaseEvents.first { $0.1 == .active }
        #expect(activatedEvent != nil)

        // Should transition to shutdown
        let shutdownEvent = phaseEvents.first { $0.1 == .shutdown }
        #expect(shutdownEvent != nil)
    }
}

// MARK: - ShardHealthChecker Tests

@Suite("ShardHealthChecker Tests")
struct ShardHealthCheckerTests {

    @Test("Health check on valid shard returns healthy")
    func testHealthCheckHealthy() async throws {
        let tmpDir = makeTempDir()
        defer { cleanup(tmpDir) }

        let storageConfig = SQLiteStorageConfiguration(root: tmpDir, shardCount: 2)
        let manager = SQLiteShardManager(configuration: storageConfig)
        try await manager.initialize()

        let ownership = ShardOwnershipMap(nodeID: "node-1", metadataPath: "\(tmpDir)/metadata")
        await ownership.initializeDefault(shardCount: 2)

        // Open shard so it exists on disk
        _ = try await manager.openShard(0)

        let checker = ShardHealthChecker(
            shardManager: manager,
            ownership: ownership
        )

        let report = await checker.checkShard(0)
        #expect(report.status == .healthy || report.status == .degraded)
        #expect(report.isOpen == true)
        #expect(report.integrityOK == true)
    }

    @Test("Health check on non-existent shard returns unhealthy")
    func testHealthCheckMissingShard() async throws {
        let tmpDir = makeTempDir()
        defer { cleanup(tmpDir) }

        let storageConfig = SQLiteStorageConfiguration(root: tmpDir, shardCount: 2)
        let manager = SQLiteShardManager(configuration: storageConfig)
        try await manager.initialize()

        let ownership = ShardOwnershipMap(nodeID: "node-1", metadataPath: "\(tmpDir)/metadata")
        await ownership.initializeDefault(shardCount: 2)

        let checker = ShardHealthChecker(
            shardManager: manager,
            ownership: ownership
        )

        // Shard 99 does not exist in ownership map
        let report = await checker.checkShard(99)
        #expect(report.status == .unhealthy)
        #expect(report.isOpen == false)
        #expect(report.integrityOK == false)
    }

    @Test("Overall health report covers all shards")
    func testOverallHealthReport() async throws {
        let tmpDir = makeTempDir()
        defer { cleanup(tmpDir) }

        let storageConfig = SQLiteStorageConfiguration(root: tmpDir, shardCount: 3)
        let manager = SQLiteShardManager(configuration: storageConfig)
        try await manager.initialize()

        let ownership = ShardOwnershipMap(nodeID: "node-1", metadataPath: "\(tmpDir)/metadata")
        await ownership.initializeDefault(shardCount: 3)

        // Open all shards
        for i in 0..<3 {
            _ = try await manager.openShard(i)
        }

        let checker = ShardHealthChecker(
            shardManager: manager,
            ownership: ownership
        )

        let report = await checker.checkHealth()
        #expect(report.totalShards == 3)
        #expect(report.shardReports.count == 3)
        #expect(report.openShards == 3)
        #expect(report.healthyShards >= 1)
        #expect(report.nodeID == "node-1")
    }
}

// MARK: - StorageMetrics Tests

@Suite("StorageMetrics Tests")
struct StorageMetricsTests {

    @Test("Record write latency and verify snapshot stats")
    func testRecordWriteLatency() async {
        let metrics = StorageMetrics()

        await metrics.recordWriteLatency(0.010)
        await metrics.recordWriteLatency(0.020)
        await metrics.recordWriteLatency(0.030)

        let snap = await metrics.snapshot()
        #expect(snap.writeLatency.count == 3)
        #expect(snap.writeLatency.min == 0.010)
        #expect(snap.writeLatency.max == 0.030)
        #expect(abs(snap.writeLatency.mean - 0.020) < 0.001)
    }

    @Test("Record read latency and verify min/max/mean")
    func testRecordReadLatency() async {
        let metrics = StorageMetrics()

        await metrics.recordReadLatency(0.005)
        await metrics.recordReadLatency(0.015)
        await metrics.recordReadLatency(0.025)
        await metrics.recordReadLatency(0.035)

        let snap = await metrics.snapshot()
        #expect(snap.readLatency.count == 4)
        #expect(snap.readLatency.min == 0.005)
        #expect(snap.readLatency.max == 0.035)
        #expect(abs(snap.readLatency.mean - 0.020) < 0.001)
    }

    @Test("Metric counters track checkpoints and snapshots")
    func testMetricCounters() async {
        let metrics = StorageMetrics()

        await metrics.recordCheckpoint()
        await metrics.recordCheckpoint()
        await metrics.recordCheckpoint()
        await metrics.recordSnapshot(duration: 1.5)
        await metrics.recordSnapshot(duration: 2.0)

        let snap = await metrics.snapshot()
        #expect(snap.checkpointCount == 3)
        #expect(snap.snapshotCount == 2)
        #expect(snap.lastSnapshotDuration == 2.0)
    }

    @Test("MetricTimer elapsed is greater than zero after brief wait")
    func testMetricTimer() async throws {
        let timer = MetricTimer()

        // Busy-wait briefly to ensure some time passes
        let start = Date()
        while Date().timeIntervalSince(start) < 0.01 {}

        #expect(timer.elapsed > 0)
    }

    @Test("Rolling window keeps only latest maxSamples")
    func testRollingWindow() async {
        let metrics = StorageMetrics(maxSamples: 5)

        // Record 10 samples (values 1.0 through 10.0)
        for i in 1...10 {
            await metrics.recordWriteLatency(Double(i))
        }

        let snap = await metrics.snapshot()
        // Should only have the latest 5 samples (6.0, 7.0, 8.0, 9.0, 10.0)
        #expect(snap.writeLatency.count == 5)
        #expect(snap.writeLatency.min == 6.0)
        #expect(snap.writeLatency.max == 10.0)
    }

    @Test("Reset clears all metrics")
    func testReset() async {
        let metrics = StorageMetrics()

        await metrics.recordWriteLatency(0.010)
        await metrics.recordReadLatency(0.020)
        await metrics.recordCheckpoint()
        await metrics.recordSnapshot(duration: 1.0)
        await metrics.setOpenShardCount(5)
        await metrics.setTotalWalSize(1024)

        await metrics.reset()

        let snap = await metrics.snapshot()
        #expect(snap.writeLatency.count == 0)
        #expect(snap.readLatency.count == 0)
        #expect(snap.checkpointCount == 0)
        #expect(snap.snapshotCount == 0)
        #expect(snap.openShardCount == 0)
        #expect(snap.totalWalSizeBytes == 0)
        #expect(snap.lastSnapshotDuration == nil)
        #expect(snap.lastRestoreDuration == nil)
    }
}
