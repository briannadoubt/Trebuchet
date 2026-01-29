// CloudWatchReporter.swift
// AWS CloudWatch metrics reporter

import Foundation
import SotoCloudWatch
import SotoCore

/// Configuration for CloudWatch metrics reporting
public struct CloudWatchConfiguration: Sendable {
    /// CloudWatch namespace for metrics
    public let namespace: String

    /// AWS region
    public let region: Region

    /// Flush interval for batching metrics
    public let flushInterval: Duration

    /// Maximum batch size (CloudWatch supports up to 1000, but smaller batches are more reliable)
    public let maxBatchSize: Int

    /// Creates a new CloudWatch configuration
    /// - Parameters:
    ///   - namespace: CloudWatch namespace (e.g., "Trebuchet/Production")
    ///   - region: AWS region (default: .useast1)
    ///   - flushInterval: How often to flush metrics (default: 60 seconds)
    ///   - maxBatchSize: Maximum metrics per batch (default: 20)
    public init(
        namespace: String,
        region: Region = .useast1,
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
/// ## Features
///
/// - Automatic batching to reduce API calls
/// - Periodic flushing on configured interval
/// - Retry logic for throttled requests
/// - Support for dimensions (tags)
/// - Multiple metric units (count, milliseconds, bytes, etc.)
///
/// ## Example Usage
///
/// ```swift
/// let reporter = CloudWatchReporter(
///     configuration: CloudWatchConfiguration(
///         namespace: "MyApp/Production",
///         region: .useast1
///     )
/// )
///
/// await reporter.incrementCounter("requests", by: 1, tags: ["endpoint": "/api/users"])
/// await reporter.recordHistogram("latency", value: .milliseconds(150), tags: ["operation": "query"])
/// ```
public actor CloudWatchReporter: MetricsCollector {
    private let client: CloudWatch
    private let awsClient: AWSClient
    private let configuration: CloudWatchConfiguration
    private var pendingMetrics: [CloudWatchMetric] = []
    private var flushTask: Task<Void, Never>?

    /// Creates a new CloudWatch reporter
    /// - Parameters:
    ///   - configuration: CloudWatch configuration
    ///   - awsClient: Optional custom AWSClient for advanced configuration
    public init(
        configuration: CloudWatchConfiguration,
        awsClient: AWSClient? = nil
    ) {
        self.configuration = configuration

        self.awsClient = awsClient ?? AWSClient(credentialProvider: .default)
        self.client = CloudWatch(client: self.awsClient, region: configuration.region)

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

        // Batch metrics (CloudWatch supports up to 1000, but we use smaller batches)
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
        // Convert internal metrics to CloudWatch MetricDatum
        let metricData = metrics.map { metric -> CloudWatch.MetricDatum in
            CloudWatch.MetricDatum(
                dimensions: metric.dimensions.map { dimension in
                    CloudWatch.Dimension(
                        name: dimension.name,
                        value: dimension.value
                    )
                },
                metricName: metric.name,
                timestamp: metric.timestamp,
                unit: convertUnit(metric.unit),
                value: metric.value
            )
        }

        let input = CloudWatch.PutMetricDataInput(
            metricData: metricData,
            namespace: configuration.namespace
        )

        // Send to CloudWatch with retry logic for throttling
        var retries = 0
        let maxRetries = 3

        while retries < maxRetries {
            do {
                _ = try await client.putMetricData(input)
                return
            } catch {
                // Check if it's a throttling error (AWS returns this in error messages)
                let errorString = String(describing: error)
                if errorString.contains("Throttling") || errorString.contains("throttling") {
                    retries += 1
                    if retries < maxRetries {
                        let backoff = Duration.milliseconds(100 * (1 << retries))
                        try await Task.sleep(for: backoff)
                    } else {
                        throw error
                    }
                } else {
                    // Non-throttling error, rethrow immediately
                    throw error
                }
            }
        }
    }

    /// Convert internal unit enum to CloudWatch StandardUnit
    private func convertUnit(_ unit: CloudWatchUnit) -> CloudWatch.StandardUnit {
        switch unit {
        case .none: return .none
        case .count: return .count
        case .milliseconds: return .milliseconds
        case .seconds: return .seconds
        case .bytes: return .bytes
        case .kilobytes: return .kilobytes
        case .megabytes: return .megabytes
        case .percent: return .percent
        }
    }

    /// Shutdown the reporter and underlying AWS client
    ///
    /// This cancels the flush task, flushes any pending metrics, and shuts down
    /// the AWS client. Should be called when the reporter is no longer needed.
    public func shutdown() async throws {
        flushTask?.cancel()
        try await flush()
        try await awsClient.shutdown()
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
