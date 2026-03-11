import Foundation
import GRDB

public struct MetricRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "metrics"

    public var timestamp: Int64  // nanoseconds
    public var name: String
    public var metricType: String  // gauge, sum, histogram, exponentialHistogram, summary
    public var serviceName: String
    public var attributes: String?  // JSON
    public var dataJSON: String  // Raw OTLP data point as JSON

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

public struct MetricPage: Codable, Sendable {
    public var metrics: [MetricRecord]
    public var nextCursor: Int64?

    public init(metrics: [MetricRecord], nextCursor: Int64? = nil) {
        self.metrics = metrics
        self.nextCursor = nextCursor
    }
}
