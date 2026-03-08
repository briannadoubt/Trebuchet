import Foundation

/// A single metric measurement
public struct MetricSample: Sendable {
    public let value: Double
    public let timestamp: Date

    public init(value: Double, timestamp: Date = Date()) {
        self.value = value
        self.timestamp = timestamp
    }
}

/// Aggregated metric statistics
public struct MetricStats: Sendable {
    public let count: Int
    public let min: Double
    public let max: Double
    public let mean: Double
    public let p50: Double
    public let p99: Double

    public init(count: Int, min: Double, max: Double, mean: Double, p50: Double, p99: Double) {
        self.count = count
        self.min = min
        self.max = max
        self.mean = mean
        self.p50 = p50
        self.p99 = p99
    }
}

/// Snapshot of all current metrics
public struct StorageMetricsSnapshot: Sendable {
    public let writeLatency: MetricStats
    public let readLatency: MetricStats
    public let openShardCount: Int
    public let totalWalSizeBytes: UInt64
    public let checkpointCount: UInt64
    public let snapshotCount: UInt64
    public let lastSnapshotDuration: TimeInterval?
    public let lastRestoreDuration: TimeInterval?
    public let timestamp: Date

    public init(
        writeLatency: MetricStats,
        readLatency: MetricStats,
        openShardCount: Int,
        totalWalSizeBytes: UInt64,
        checkpointCount: UInt64,
        snapshotCount: UInt64,
        lastSnapshotDuration: TimeInterval?,
        lastRestoreDuration: TimeInterval?,
        timestamp: Date
    ) {
        self.writeLatency = writeLatency
        self.readLatency = readLatency
        self.openShardCount = openShardCount
        self.totalWalSizeBytes = totalWalSizeBytes
        self.checkpointCount = checkpointCount
        self.snapshotCount = snapshotCount
        self.lastSnapshotDuration = lastSnapshotDuration
        self.lastRestoreDuration = lastRestoreDuration
        self.timestamp = timestamp
    }
}

/// Collects and reports storage metrics for the SQLite layer.
///
/// Thread-safe actor that records latency samples, counters, and gauges.
/// Maintains a rolling window of samples (default 1000) to compute statistics.
public actor StorageMetrics {
    private var writeSamples: [Double] = []
    private var readSamples: [Double] = []
    private let maxSamples: Int

    private var _openShardCount: Int = 0
    private var _totalWalSizeBytes: UInt64 = 0
    private var _checkpointCount: UInt64 = 0
    private var _snapshotCount: UInt64 = 0
    private var _lastSnapshotDuration: TimeInterval?
    private var _lastRestoreDuration: TimeInterval?

    public init(maxSamples: Int = 1000) {
        self.maxSamples = maxSamples
    }

    // MARK: - Recording

    /// Record a write operation latency in seconds.
    public func recordWriteLatency(_ seconds: TimeInterval) {
        writeSamples.append(seconds)
        if writeSamples.count > maxSamples {
            writeSamples.removeFirst(writeSamples.count - maxSamples)
        }
    }

    /// Record a read operation latency in seconds.
    public func recordReadLatency(_ seconds: TimeInterval) {
        readSamples.append(seconds)
        if readSamples.count > maxSamples {
            readSamples.removeFirst(readSamples.count - maxSamples)
        }
    }

    /// Record a WAL checkpoint event.
    public func recordCheckpoint() {
        _checkpointCount += 1
    }

    /// Record a snapshot with its duration.
    public func recordSnapshot(duration: TimeInterval) {
        _snapshotCount += 1
        _lastSnapshotDuration = duration
    }

    /// Record a restore with its duration.
    public func recordRestore(duration: TimeInterval) {
        _lastRestoreDuration = duration
    }

    /// Update the current open shard count gauge.
    public func setOpenShardCount(_ count: Int) {
        _openShardCount = count
    }

    /// Update the total WAL size gauge.
    public func setTotalWalSize(_ bytes: UInt64) {
        _totalWalSizeBytes = bytes
    }

    // MARK: - Reporting

    /// Get a snapshot of all current metrics.
    public func snapshot() -> StorageMetricsSnapshot {
        StorageMetricsSnapshot(
            writeLatency: computeStats(writeSamples),
            readLatency: computeStats(readSamples),
            openShardCount: _openShardCount,
            totalWalSizeBytes: _totalWalSizeBytes,
            checkpointCount: _checkpointCount,
            snapshotCount: _snapshotCount,
            lastSnapshotDuration: _lastSnapshotDuration,
            lastRestoreDuration: _lastRestoreDuration,
            timestamp: Date()
        )
    }

    /// Reset all collected metrics.
    public func reset() {
        writeSamples.removeAll()
        readSamples.removeAll()
        _openShardCount = 0
        _totalWalSizeBytes = 0
        _checkpointCount = 0
        _snapshotCount = 0
        _lastSnapshotDuration = nil
        _lastRestoreDuration = nil
    }

    // MARK: - Private

    private func computeStats(_ samples: [Double]) -> MetricStats {
        guard !samples.isEmpty else {
            return MetricStats(count: 0, min: 0, max: 0, mean: 0, p50: 0, p99: 0)
        }

        let sorted = samples.sorted()
        let count = sorted.count
        let sum = sorted.reduce(0, +)
        let mean = sum / Double(count)
        let p50Index = min(count - 1, count / 2)
        let p99Index = min(count - 1, Int(Double(count) * 0.99))

        return MetricStats(
            count: count,
            min: sorted.first ?? 0,
            max: sorted.last ?? 0,
            mean: mean,
            p50: sorted[p50Index],
            p99: sorted[p99Index]
        )
    }
}

/// Convenience for timing operations and recording to metrics.
public struct MetricTimer: Sendable {
    public let startTime: Date

    public init() {
        self.startTime = Date()
    }

    /// Elapsed time since the timer was created.
    public var elapsed: TimeInterval {
        Date().timeIntervalSince(startTime)
    }
}
