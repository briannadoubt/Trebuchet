// CloudWatchReporter.swift
// AWS CloudWatch metrics reporter

import Foundation

/// Configuration for CloudWatch metrics reporting
public struct CloudWatchConfiguration: Sendable {
    /// CloudWatch namespace for metrics
    public let namespace: String

    /// AWS region
    public let region: String

    /// Flush interval for batching metrics
    public let flushInterval: Duration

    /// Maximum batch size
    public let maxBatchSize: Int

    /// Creates a new CloudWatch configuration
    /// - Parameters:
    ///   - namespace: CloudWatch namespace (e.g., "Trebuche/Production")
    ///   - region: AWS region (e.g., "us-east-1")
    ///   - flushInterval: How often to flush metrics (default: 60 seconds)
    ///   - maxBatchSize: Maximum metrics per batch (default: 20, CloudWatch limit)
    public init(
        namespace: String,
        region: String = "us-east-1",
        flushInterval: Duration = .seconds(60),
        maxBatchSize: Int = 20
    ) {
        self.namespace = namespace
        self.region = region
        self.flushInterval = flushInterval
        self.maxBatchSize = maxBatchSize
    }
}

/// CloudWatch metrics reporter
///
/// This reporter sends metrics to AWS CloudWatch. It batches metrics
/// and flushes them periodically to minimize API calls.
///
/// Note: This is a placeholder implementation. In production, you would
/// use the AWS SDK to actually send metrics to CloudWatch.
public actor CloudWatchReporter: MetricsCollector {
    private let configuration: CloudWatchConfiguration
    private var pendingMetrics: [CloudWatchMetric] = []
    private var flushTask: Task<Void, Never>?

    /// Creates a new CloudWatch reporter
    /// - Parameter configuration: CloudWatch configuration
    public init(configuration: CloudWatchConfiguration) {
        self.configuration = configuration
        // Start flush loop after initialization
        Task {
            await self.startFlushLoop()
        }
    }

    public func incrementCounter(_ name: String, by value: Int, tags: [String: String]) {
        let metric = CloudWatchMetric(
            name: name,
            value: Double(value),
            unit: .count,
            dimensions: tags.map { CloudWatchDimension(name: $0.key, value: $0.value) }
        )
        pendingMetrics.append(metric)
    }

    public func recordGauge(_ name: String, value: Double, tags: [String: String]) {
        let metric = CloudWatchMetric(
            name: name,
            value: value,
            unit: .none,
            dimensions: tags.map { CloudWatchDimension(name: $0.key, value: $0.value) }
        )
        pendingMetrics.append(metric)
    }

    public func recordHistogram(_ name: String, value: Duration, tags: [String: String]) {
        let milliseconds = Double(value.components.seconds) * 1000.0 +
                          Double(value.components.attoseconds) / 1_000_000_000_000_000.0

        let metric = CloudWatchMetric(
            name: name,
            value: milliseconds,
            unit: .milliseconds,
            dimensions: tags.map { CloudWatchDimension(name: $0.key, value: $0.value) }
        )
        pendingMetrics.append(metric)
    }

    public func flush() async throws {
        guard !pendingMetrics.isEmpty else { return }

        let metricsToFlush = pendingMetrics
        pendingMetrics.removeAll()

        // Batch metrics
        let batches = stride(from: 0, to: metricsToFlush.count, by: configuration.maxBatchSize).map {
            Array(metricsToFlush[$0..<min($0 + configuration.maxBatchSize, metricsToFlush.count)])
        }

        // Send each batch
        for batch in batches {
            try await sendBatch(batch)
        }
    }

    private func startFlushLoop() async {
        flushTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: configuration.flushInterval)
                try? await flush()
            }
        }
    }

    private func sendBatch(_ metrics: [CloudWatchMetric]) async throws {
        // In a real implementation, this would use the AWS SDK to call PutMetricData
        // For now, we'll just log the metrics that would be sent

        #if DEBUG
        print("[CloudWatch] Would send batch to \(configuration.namespace) in \(configuration.region):")
        for metric in metrics {
            let dimensionsStr = metric.dimensions.map { "\($0.name)=\($0.value)" }.joined(separator: ", ")
            print("  \(metric.name): \(metric.value) \(metric.unit) [\(dimensionsStr)]")
        }
        #endif

        // TODO: Implement actual CloudWatch API call
        // Example using AWS SDK:
        // let client = CloudWatchClient(region: configuration.region)
        // let request = PutMetricDataRequest(
        //     namespace: configuration.namespace,
        //     metricData: metrics.map { ... }
        // )
        // try await client.putMetricData(request)
    }

    deinit {
        flushTask?.cancel()
    }
}

/// CloudWatch metric data
struct CloudWatchMetric: Sendable {
    let name: String
    let value: Double
    let unit: CloudWatchUnit
    let dimensions: [CloudWatchDimension]
    let timestamp: Date

    init(name: String, value: Double, unit: CloudWatchUnit, dimensions: [CloudWatchDimension]) {
        self.name = name
        self.value = value
        self.unit = unit
        self.dimensions = dimensions
        self.timestamp = Date()
    }
}

/// CloudWatch metric dimension
struct CloudWatchDimension: Sendable {
    let name: String
    let value: String
}

/// CloudWatch metric units
enum CloudWatchUnit: String, Sendable {
    case none = "None"
    case count = "Count"
    case milliseconds = "Milliseconds"
    case seconds = "Seconds"
    case bytes = "Bytes"
    case kilobytes = "Kilobytes"
    case megabytes = "Megabytes"
    case percent = "Percent"
}
