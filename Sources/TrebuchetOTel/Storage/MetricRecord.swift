import Foundation
import GRDB

/// A single OTLP metric data point persisted in the ``SpanStore`` database.
///
/// Each ``MetricRecord`` corresponds to one data point from an OTLP metrics payload.
/// The raw data point JSON is preserved in ``dataJSON`` for full-fidelity retrieval.
public struct MetricRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "metrics"

    /// The data point timestamp in nanoseconds since epoch.
    public var timestamp: Int64
    /// The metric name (e.g., `"http.server.duration"`).
    public var name: String
    /// The OTLP metric type: `"gauge"`, `"sum"`, `"histogram"`, `"exponentialHistogram"`, or `"summary"`.
    public var metricType: String
    /// The service that emitted this metric.
    public var serviceName: String
    /// Flattened data point attributes as a JSON string, or `nil` if no attributes are present.
    public var attributes: String?
    /// The raw OTLP data point serialized as JSON.
    public var dataJSON: String

    /// Creates a new metric record.
    ///
    /// - Parameters:
    ///   - timestamp: The data point timestamp in nanoseconds since epoch.
    ///   - name: The metric name.
    ///   - metricType: The OTLP metric type string.
    ///   - serviceName: The originating service name.
    ///   - attributes: Optional JSON string of flattened data point attributes.
    ///   - dataJSON: The raw OTLP data point as a JSON string.
    public init(
        timestamp: Int64,
        name: String,
        metricType: String,
        serviceName: String,
        attributes: String? = nil,
        dataJSON: String
    ) {
        self.timestamp = timestamp
        self.name = name
        self.metricType = metricType
        self.serviceName = serviceName
        self.attributes = attributes
        self.dataJSON = dataJSON
    }
}

/// A cursor-paginated page of metric records.
public struct MetricPage: Codable, Sendable {
    /// The metric records in this page.
    public var metrics: [MetricRecord]
    /// The cursor value for fetching the next page, or `nil` if this is the last page.
    public var nextCursor: Int64?

    public init(metrics: [MetricRecord], nextCursor: Int64? = nil) {
        self.metrics = metrics
        self.nextCursor = nextCursor
    }
}
