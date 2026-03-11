import Foundation
import GRDB

public struct SpanRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "spans"

    public var traceId: String
    public var spanId: String
    public var parentSpanId: String?
    public var operationName: String
    public var serviceName: String
    public var spanKind: Int
    public var startTimeNano: Int64
    public var endTimeNano: Int64
    public var durationNano: Int64
    public var statusCode: Int  // 0=unset, 1=ok, 2=error
    public var statusMessage: String?
    public var attributes: String?  // JSON
    public var events: String?  // JSON
    public var resourceAttrs: String?  // JSON

    public init(
        traceId: String,
        spanId: String,
        parentSpanId: String? = nil,
        operationName: String,
        serviceName: String,
        spanKind: Int,
        startTimeNano: Int64,
        endTimeNano: Int64,
        durationNano: Int64,
        statusCode: Int,
        statusMessage: String? = nil,
        attributes: String? = nil,
        events: String? = nil,
        resourceAttrs: String? = nil
    ) {
        self.traceId = traceId
        self.spanId = spanId
        self.parentSpanId = parentSpanId
        self.operationName = operationName
        self.serviceName = serviceName
        self.spanKind = spanKind
        self.startTimeNano = startTimeNano
        self.endTimeNano = endTimeNano
        self.durationNano = durationNano
        self.statusCode = statusCode
        self.statusMessage = statusMessage
        self.attributes = attributes
        self.events = events
        self.resourceAttrs = resourceAttrs
    }
}
