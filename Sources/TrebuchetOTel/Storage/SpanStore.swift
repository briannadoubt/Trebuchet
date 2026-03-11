import Foundation
import GRDB

/// A lightweight summary of a distributed trace, used for trace listing pages.
public struct TraceSummary: Codable, Sendable {
    /// The unique trace identifier.
    public var traceId: String
    /// The operation name of the root span in this trace.
    public var rootOperation: String
    /// The service name of the root span.
    public var serviceName: String
    /// The earliest span start time in the trace, in nanoseconds since epoch.
    public var startTimeNano: Int64
    /// The total trace duration in nanoseconds (max end time minus min start time).
    public var durationNano: Int64
    /// The number of spans in this trace.
    public var spanCount: Int
    /// The number of spans with an error status code.
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

/// Aggregate statistics for spans within a time range.
public struct SpanStats: Codable, Sendable {
    /// Total number of spans in the queried time range.
    public var totalCount: Int
    /// Number of spans with an error status code (status code 2).
    public var errorCount: Int
    /// The median (p50) span duration in nanoseconds.
    public var p50DurationNano: Int64
    /// The 95th percentile span duration in nanoseconds.
    public var p95DurationNano: Int64

    public init(totalCount: Int, errorCount: Int, p50DurationNano: Int64, p95DurationNano: Int64) {
        self.totalCount = totalCount
        self.errorCount = errorCount
        self.p50DurationNano = p50DurationNano
        self.p95DurationNano = p95DurationNano
    }
}

/// A cursor-paginated page of trace summaries.
public struct TracePage: Codable, Sendable {
    /// The trace summaries in this page.
    public var traces: [TraceSummary]
    /// The cursor value for fetching the next page, or `nil` if this is the last page.
    public var nextCursor: Int64?

    public init(traces: [TraceSummary], nextCursor: Int64? = nil) {
        self.traces = traces
        self.nextCursor = nextCursor
    }
}

/// A cursor-paginated page of log records.
public struct LogPage: Codable, Sendable {
    /// The log records in this page.
    public var logs: [LogRecord]
    /// The cursor value for fetching the next page, or `nil` if this is the last page.
    public var nextCursor: Int64?

    public init(logs: [LogRecord], nextCursor: Int64? = nil) {
        self.logs = logs
        self.nextCursor = nextCursor
    }
}

/// SQLite-backed storage for OpenTelemetry spans, logs, and metrics.
///
/// ``SpanStore`` manages a GRDB `DatabasePool` in WAL mode with indexed tables for spans,
/// logs, and metrics. It provides paginated query methods and aggregate statistics suitable
/// for powering a trace-viewer dashboard.
public actor SpanStore {
    private let dbPool: DatabasePool

    /// Creates a new span store, opening or creating the SQLite database at the given path.
    ///
    /// On first creation, the database schema (spans, logs, metrics tables and indexes) is
    /// initialized automatically.
    ///
    /// - Parameter path: The filesystem path for the SQLite database file.
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

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS metrics (
                    timestamp INTEGER NOT NULL,
                    name TEXT NOT NULL,
                    metricType TEXT NOT NULL,
                    serviceName TEXT NOT NULL,
                    attributes TEXT,
                    dataJSON TEXT NOT NULL
                )
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_metrics_timestamp ON metrics(timestamp DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_metrics_name_time ON metrics(name, timestamp DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_metrics_service_time ON metrics(serviceName, timestamp DESC)")
        }
        dbPool = pool
    }

    // MARK: - Write

    /// Inserts a batch of span records into the database.
    ///
    /// - Parameter spans: The span records to persist.
    public func insertSpans(_ spans: [SpanRecord]) throws {
        try dbPool.write { db in
            for span in spans {
                try span.insert(db)
            }
        }
    }

    // MARK: - Read

    /// Lists trace summaries with optional filtering and cursor-based pagination.
    ///
    /// - Parameters:
    ///   - service: Filter traces to those containing spans from this service.
    ///   - status: Filter traces to those containing spans with this status code.
    ///   - since: Only include traces starting at or after this nanosecond timestamp.
    ///   - until: Only include traces starting at or before this nanosecond timestamp.
    ///   - limit: Maximum number of traces to return per page. Defaults to 50.
    ///   - cursor: A `startTimeNano` value from a previous ``TracePage/nextCursor`` for pagination.
    /// - Returns: A ``TracePage`` containing the matching trace summaries and an optional cursor.
    public func listTraces(
        service: String? = nil,
        status: Int? = nil,
        search: String? = nil,
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
            if let search, !search.isEmpty {
                let escaped = search
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
                conditions.append("operationName LIKE ? ESCAPE '\\'")
                arguments.append("%\(escaped)%")
            }
            if let since {
                conditions.append("startTimeNano >= ?")
                arguments.append(since)
            }
            if let until {
                conditions.append("startTimeNano <= ?")
                arguments.append(until)
            }
            let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")

            // Cursor is applied post-grouping via HAVING so it filters on the
            // trace's actual MIN(startTimeNano), not individual span rows.
            let havingClause = cursor != nil ? "HAVING minStart < ?" : ""

            // Fetch traceIds ordered by their earliest startTimeNano, paginated
            let traceSQL = """
                SELECT traceId, MIN(startTimeNano) AS minStart
                FROM spans
                \(whereClause)
                GROUP BY traceId
                \(havingClause)
                ORDER BY minStart DESC
                LIMIT ?
                """
            if let cursor { arguments.append(cursor) }
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

    /// Retrieves all spans belonging to a specific trace, ordered by start time.
    ///
    /// - Parameter traceId: The trace identifier to look up.
    /// - Returns: An array of ``SpanRecord`` values for the trace, sorted ascending by start time.
    public func getTrace(traceId: String) throws -> [SpanRecord] {
        try dbPool.read { db in
            try SpanRecord
                .filter(Column("traceId") == traceId)
                .order(Column("startTimeNano").asc)
                .fetchAll(db)
        }
    }

    /// Searches spans by operation name or status message using a case-insensitive substring match.
    ///
    /// - Parameters:
    ///   - query: The search string to match against operation names and status messages.
    ///   - limit: Maximum number of results to return. Defaults to 100.
    /// - Returns: Matching ``SpanRecord`` values, ordered by start time descending.
    public func searchSpans(query: String, limit: Int = 100) throws -> [SpanRecord] {
        try dbPool.read { db in
            let escaped = query
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            let pattern = "%\(escaped)%"
            return try SpanRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM spans
                    WHERE operationName LIKE ? ESCAPE '\\' OR statusMessage LIKE ? ESCAPE '\\'
                    ORDER BY startTimeNano DESC
                    LIMIT ?
                    """,
                arguments: [pattern, pattern, limit]
            )
        }
    }

    /// Computes aggregate statistics for spans starting at or after the given timestamp.
    ///
    /// Calculates total count, error count, and p50/p95 duration percentiles using
    /// SQL-based offset queries to avoid loading all durations into memory.
    ///
    /// - Parameter since: The nanosecond timestamp lower bound for included spans.
    /// - Returns: A ``SpanStats`` summary for the time range.
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

            // Compute percentiles via SQL OFFSET/LIMIT to avoid loading all durations into memory
            let p50 = try Int64.fetchOne(
                db,
                sql: """
                    SELECT durationNano FROM spans
                    WHERE startTimeNano >= ?
                    ORDER BY durationNano ASC
                    LIMIT 1 OFFSET (SELECT COUNT(*) FROM spans WHERE startTimeNano >= ?) / 2
                    """,
                arguments: [since, since]
            ) ?? 0

            let p95 = try Int64.fetchOne(
                db,
                sql: """
                    SELECT durationNano FROM spans
                    WHERE startTimeNano >= ?
                    ORDER BY durationNano ASC
                    LIMIT 1 OFFSET (SELECT COUNT(*) FROM spans WHERE startTimeNano >= ?) * 95 / 100
                    """,
                arguments: [since, since]
            ) ?? 0

            return SpanStats(
                totalCount: totalCount,
                errorCount: errorCount,
                p50DurationNano: p50,
                p95DurationNano: p95
            )
        }
    }

    /// Returns all distinct service names that have emitted spans, sorted alphabetically.
    public func listServices() throws -> [String] {
        try dbPool.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT serviceName FROM spans ORDER BY serviceName")
        }
    }

    // MARK: - Metric Write

    /// Inserts a batch of metric records into the database.
    ///
    /// - Parameter metrics: The metric records to persist.
    public func insertMetrics(_ metrics: [MetricRecord]) throws {
        try dbPool.write { db in
            for metric in metrics {
                try metric.insert(db)
            }
        }
    }

    // MARK: - Log Write

    /// Inserts a batch of log records into the database.
    ///
    /// - Parameter logs: The log records to persist.
    public func insertLogs(_ logs: [LogRecord]) throws {
        try dbPool.write { db in
            for log in logs {
                try log.insert(db)
            }
        }
    }

    // MARK: - Log Read

    /// Lists log records with optional filtering and cursor-based pagination.
    ///
    /// - Parameters:
    ///   - service: Filter logs to those from this service.
    ///   - minSeverity: Filter logs to those with severity number at or above this value.
    ///   - search: A substring to match against log body text.
    ///   - limit: Maximum number of logs to return per page. Defaults to 50.
    ///   - cursor: A `timestamp` value from a previous ``LogPage/nextCursor`` for pagination.
    /// - Returns: A ``LogPage`` containing the matching log records and an optional cursor.
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
                let escaped = search
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
                conditions.append("body LIKE ? ESCAPE '\\'")
                arguments.append("%\(escaped)%")
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

    /// Retrieves all log records correlated with a specific trace, ordered by timestamp.
    ///
    /// - Parameter traceId: The trace identifier to look up.
    /// - Returns: An array of ``LogRecord`` values associated with the trace.
    public func getLogsForTrace(traceId: String) throws -> [LogRecord] {
        try dbPool.read { db in
            try LogRecord
                .filter(Column("traceId") == traceId)
                .order(Column("timestamp").asc)
                .fetchAll(db)
        }
    }

    // MARK: - Metric Read

    /// Lists metric records with optional filtering and cursor-based pagination.
    ///
    /// - Parameters:
    ///   - name: Filter metrics to those with this metric name.
    ///   - service: Filter metrics to those from this service.
    ///   - limit: Maximum number of metrics to return per page. Defaults to 50.
    ///   - cursor: A `timestamp` value from a previous ``MetricPage/nextCursor`` for pagination.
    /// - Returns: A ``MetricPage`` containing the matching metric records and an optional cursor.
    public func listMetrics(
        name: String? = nil,
        service: String? = nil,
        limit: Int = 50,
        cursor: Int64? = nil
    ) throws -> MetricPage {
        try dbPool.read { db in
            var conditions: [String] = []
            var arguments: [any DatabaseValueConvertible] = []

            if let name {
                conditions.append("name = ?")
                arguments.append(name)
            }
            if let service {
                conditions.append("serviceName = ?")
                arguments.append(service)
            }
            if let cursor {
                conditions.append("timestamp < ?")
                arguments.append(cursor)
            }

            let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")

            let sql = """
                SELECT * FROM metrics
                \(whereClause)
                ORDER BY timestamp DESC
                LIMIT ?
                """
            arguments.append(limit + 1)

            let metrics = try MetricRecord.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))

            let hasMore = metrics.count > limit
            let pageMetrics = hasMore ? Array(metrics.prefix(limit)) : metrics
            let nextCursor: Int64? = hasMore ? pageMetrics.last?.timestamp : nil

            return MetricPage(metrics: pageMetrics, nextCursor: nextCursor)
        }
    }

    /// Returns all distinct metric names that have been recorded, sorted alphabetically.
    public func listMetricNames() throws -> [String] {
        try dbPool.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT name FROM metrics ORDER BY name")
        }
    }

    // MARK: - Cleanup

    /// Deletes all spans, logs, and metrics older than the given nanosecond timestamp.
    ///
    /// Used by ``RetentionSweeper`` to enforce data retention policies.
    ///
    /// - Parameter cutoff: The nanosecond timestamp cutoff; records older than this are deleted.
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
            try db.execute(
                sql: "DELETE FROM metrics WHERE timestamp < ?",
                arguments: [cutoff]
            )
        }
    }

}
