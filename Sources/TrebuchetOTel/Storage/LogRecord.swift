import Foundation
import GRDB

public struct LogRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "logs"

    public var timestamp: Int64  // nanoseconds
    public var traceId: String?
    public var spanId: String?
    public var severityNumber: Int  // OTLP: 1-4 TRACE, 5-8 DEBUG, 9-12 INFO, 13-16 WARN, 17-20 ERROR, 21-24 FATAL
    public var severityText: String
    public var body: String
    public var serviceName: String
    public var attributes: String?  // JSON

    public init(
        timestamp: Int64,
        traceId: String? = nil,
        spanId: String? = nil,
        severityNumber: Int,
        severityText: String,
        body: String,
        serviceName: String,
        attributes: String? = nil
    ) {
        self.timestamp = timestamp
        self.traceId = traceId
        self.spanId = spanId
        self.severityNumber = severityNumber
        self.severityText = severityText
        self.body = body
        self.serviceName = serviceName
        self.attributes = attributes
    }
}
