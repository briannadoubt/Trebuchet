import Foundation
import GRDB

public struct TraceSummary: Codable, Sendable {
    public var traceId: String
    public var rootOperation: String
    public var serviceName: String
    public var startTimeNano: Int64
    public var durationNano: Int64
    public var spanCount: Int
    public var errorCount: Int

    public init(
        traceId: String,
        rootOperation: String,
        serviceName: String,
        startTimeNano: Int64,
        durationNano: Int64,
        spanCount: Int,
        errorCount: Int
    ) {
        self.traceId = traceId
        self.rootOperation = rootOperation
        self.serviceName = serviceName
        self.startTimeNano = startTimeNano
        self.durationNano = durationNano
        self.spanCount = spanCount
        self.errorCount = errorCount
    }
}

public struct SpanStats: Codable, Sendable {
    public var totalCount: Int
    public var errorCount: Int
    public var p50DurationNano: Int64
    public var p95DurationNano: Int64

    public init(totalCount: Int, errorCount: Int, p50DurationNano: Int64, p95DurationNano: Int64) {
        self.totalCount = totalCount
        self.errorCount = errorCount
        self.p50DurationNano = p50DurationNano
        self.p95DurationNano = p95DurationNano
    }
}

public struct TracePage: Codable, Sendable {
    public var traces: [TraceSummary]
    public var nextCursor: Int64?

    public init(traces: [TraceSummary], nextCursor: Int64? = nil) {
        self.traces = traces
        self.nextCursor = nextCursor
    }
}

public struct LogPage: Codable, Sendable {
    public var logs: [LogRecord]
    public var nextCursor: Int64?

    public init(logs: [LogRecord], nextCursor: Int64? = nil) {
        self.logs = logs
        self.nextCursor = nextCursor
    }
}

public actor SpanStore {
    private let dbPool: DatabasePool

    public init(path: String) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
        }
        let pool = try DatabasePool(path: path, configuration: config)
        try pool.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS spans (
                    traceId TEXT NOT NULL,
                    spanId TEXT NOT NULL,
                    parentSpanId TEXT,
                    operationName TEXT NOT NULL,
                    serviceName TEXT NOT NULL,
                    spanKind INTEGER NOT NULL DEFAULT 1,
                    startTimeNano INTEGER NOT NULL,
                    endTimeNano INTEGER NOT NULL,
                    durationNano INTEGER NOT NULL,
                    statusCode INTEGER NOT NULL DEFAULT 0,
                    statusMessage TEXT,
                    attributes TEXT,
                    events TEXT,
                    resourceAttrs TEXT,
                    PRIMARY KEY (traceId, spanId)
                )
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_spans_start_time ON spans(startTimeNano DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_spans_service ON spans(serviceName, startTimeNano DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_spans_status_error ON spans(statusCode, startTimeNano DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_spans_operation ON spans(operationName, startTimeNano DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_spans_duration ON spans(durationNano DESC)")

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS logs (
                    timestamp INTEGER NOT NULL,
                    traceId TEXT,
                    spanId TEXT,
                    severityNumber INTEGER NOT NULL,
                    severityText TEXT NOT NULL,
                    body TEXT NOT NULL,
                    serviceName TEXT NOT NULL,
                    attributes TEXT
                )
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_logs_timestamp ON logs(timestamp DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_logs_severity_time ON logs(severityNumber, timestamp DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_logs_service_time ON logs(serviceName, timestamp DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_logs_trace ON logs(traceId)")
        }
        dbPool = pool
    }

    // MARK: - Write

    public func insertSpans(_ spans: [SpanRecord]) throws {
        try dbPool.write { db in
            for span in spans {
                try span.insert(db)
            }
        }
    }

    // MARK: - Read

    public func listTraces(
        service: String? = nil,
        status: Int? = nil,
        since: Int64? = nil,
        until: Int64? = nil,
        limit: Int = 50,
        cursor: Int64? = nil
    ) throws -> TracePage {
        try dbPool.read { db in
            var conditions: [String] = []
            var arguments: [any DatabaseValueConvertible] = []

            if let service {
                conditions.append("serviceName = ?")
                arguments.append(service)
            }
            if let status {
                conditions.append("statusCode = ?")
                arguments.append(status)
            }
            if let since {
                conditions.append("startTimeNano >= ?")
                arguments.append(since)
            }
            if let until {
                conditions.append("startTimeNano <= ?")
                arguments.append(until)
            }
            if let cursor {
                conditions.append("startTimeNano < ?")
                arguments.append(cursor)
            }

            let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")

            // Fetch traceIds ordered by their earliest startTimeNano, paginated
            let traceSQL = """
                SELECT traceId, MIN(startTimeNano) AS minStart
                FROM spans
                \(whereClause)
                GROUP BY traceId
                ORDER BY minStart DESC
                LIMIT ?
                """
            arguments.append(limit + 1)

            let traceRows = try Row.fetchAll(db, sql: traceSQL, arguments: StatementArguments(arguments))

            let hasMore = traceRows.count > limit
            let pageRows = hasMore ? Array(traceRows.prefix(limit)) : traceRows
            let traceIds = pageRows.map { $0["traceId"] as String }

            if traceIds.isEmpty {
                return TracePage(traces: [], nextCursor: nil)
            }

            // Fetch summary data for those traces
            let placeholders = traceIds.map { _ in "?" }.joined(separator: ", ")
            let summarySQL = """
                SELECT
                    traceId,
                    MIN(startTimeNano) AS startTimeNano,
                    MAX(endTimeNano) - MIN(startTimeNano) AS durationNano,
                    COUNT(*) AS spanCount,
                    COALESCE(SUM(CASE WHEN statusCode = 2 THEN 1 ELSE 0 END), 0) AS errorCount
                FROM spans
                WHERE traceId IN (\(placeholders))
                GROUP BY traceId
                """
            let summaryRows = try Row.fetchAll(
                db,
                sql: summarySQL,
                arguments: StatementArguments(traceIds.map { $0 as any DatabaseValueConvertible })
            )

            var summaryMap: [String: Row] = [:]
            for row in summaryRows {
                summaryMap[row["traceId"] as String] = row
            }

            // Fetch root span info (span with no parentSpanId) for each trace
            let rootSQL = """
                SELECT traceId, operationName, serviceName
                FROM spans
                WHERE traceId IN (\(placeholders)) AND parentSpanId IS NULL
                """
            let rootRows = try Row.fetchAll(
                db,
                sql: rootSQL,
                arguments: StatementArguments(traceIds.map { $0 as any DatabaseValueConvertible })
            )

            var rootMap: [String: (operation: String, service: String)] = [:]
            for row in rootRows {
                let tid: String = row["traceId"]
                rootMap[tid] = (row["operationName"], row["serviceName"])
            }

            // Assemble summaries in the same order as traceIds
            var traces: [TraceSummary] = []
            for tid in traceIds {
                guard let summary = summaryMap[tid] else { continue }
                let root = rootMap[tid]
                traces.append(TraceSummary(
                    traceId: tid,
                    rootOperation: root?.operation ?? "unknown",
                    serviceName: root?.service ?? "unknown",
                    startTimeNano: summary["startTimeNano"],
                    durationNano: summary["durationNano"],
                    spanCount: summary["spanCount"],
                    errorCount: summary["errorCount"]
                ))
            }

            let nextCursor: Int64? = hasMore ? pageRows.last?["minStart"] : nil
            return TracePage(traces: traces, nextCursor: nextCursor)
        }
    }

    public func getTrace(traceId: String) throws -> [SpanRecord] {
        try dbPool.read { db in
            try SpanRecord
                .filter(Column("traceId") == traceId)
                .order(Column("startTimeNano").asc)
                .fetchAll(db)
        }
    }

    public func searchSpans(query: String, limit: Int = 100) throws -> [SpanRecord] {
        try dbPool.read { db in
            let pattern = "%\(query)%"
            return try SpanRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM spans
                    WHERE operationName LIKE ? OR statusMessage LIKE ?
                    ORDER BY startTimeNano DESC
                    LIMIT ?
                    """,
                arguments: [pattern, pattern, limit]
            )
        }
    }

    public func getStats(since: Int64) throws -> SpanStats {
        try dbPool.read { db in
            let countRow = try Row.fetchOne(
                db,
                sql: """
                    SELECT
                        COUNT(*) AS totalCount,
                        COALESCE(SUM(CASE WHEN statusCode = 2 THEN 1 ELSE 0 END), 0) AS errorCount
                    FROM spans
                    WHERE startTimeNano >= ?
                    """,
                arguments: [since]
            )!

            let totalCount: Int = countRow["totalCount"]
            let errorCount: Int = countRow["errorCount"]

            // Fetch durations for percentile computation, capped to avoid reading too many rows
            let durations = try Int64.fetchAll(
                db,
                sql: """
                    SELECT durationNano FROM spans
                    WHERE startTimeNano >= ?
                    ORDER BY durationNano ASC
                    LIMIT 100000
                    """,
                arguments: [since]
            )

            let p50 = percentile(durations, p: 0.50)
            let p95 = percentile(durations, p: 0.95)

            return SpanStats(
                totalCount: totalCount,
                errorCount: errorCount,
                p50DurationNano: p50,
                p95DurationNano: p95
            )
        }
    }

    public func listServices() throws -> [String] {
        try dbPool.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT serviceName FROM spans ORDER BY serviceName")
        }
    }

    // MARK: - Log Write

    public func insertLogs(_ logs: [LogRecord]) throws {
        try dbPool.write { db in
            for log in logs {
                try log.insert(db)
            }
        }
    }

    // MARK: - Log Read

    public func listLogs(
        service: String? = nil,
        minSeverity: Int? = nil,
        search: String? = nil,
        limit: Int = 50,
        cursor: Int64? = nil
    ) throws -> LogPage {
        try dbPool.read { db in
            var conditions: [String] = []
            var arguments: [any DatabaseValueConvertible] = []

            if let service {
                conditions.append("serviceName = ?")
                arguments.append(service)
            }
            if let minSeverity {
                conditions.append("severityNumber >= ?")
                arguments.append(minSeverity)
            }
            if let search, !search.isEmpty {
                conditions.append("body LIKE ?")
                arguments.append("%\(search)%")
            }
            if let cursor {
                conditions.append("timestamp < ?")
                arguments.append(cursor)
            }

            let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")

            let sql = """
                SELECT * FROM logs
                \(whereClause)
                ORDER BY timestamp DESC
                LIMIT ?
                """
            arguments.append(limit + 1)

            let logs = try LogRecord.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))

            let hasMore = logs.count > limit
            let pageLogs = hasMore ? Array(logs.prefix(limit)) : logs
            let nextCursor: Int64? = hasMore ? pageLogs.last?.timestamp : nil

            return LogPage(logs: pageLogs, nextCursor: nextCursor)
        }
    }

    public func getLogsForTrace(traceId: String) throws -> [LogRecord] {
        try dbPool.read { db in
            try LogRecord
                .filter(Column("traceId") == traceId)
                .order(Column("timestamp").asc)
                .fetchAll(db)
        }
    }

    // MARK: - Cleanup

    public func deleteOlderThan(_ cutoff: Int64) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM spans WHERE startTimeNano < ?",
                arguments: [cutoff]
            )
            try db.execute(
                sql: "DELETE FROM logs WHERE timestamp < ?",
                arguments: [cutoff]
            )
        }
    }

    // MARK: - Helpers

    private func percentile(_ sorted: [Int64], p: Double) -> Int64 {
        guard !sorted.isEmpty else { return 0 }
        let index = Int(Double(sorted.count - 1) * p)
        return sorted[index]
    }
}
