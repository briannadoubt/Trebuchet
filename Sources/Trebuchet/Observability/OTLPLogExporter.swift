#if !os(WASI)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Logging

/// Exports log records to an OTLP/HTTP collector at `/v1/logs`.
public actor OTLPLogExporter {
    private let endpoint: String
    private let serviceName: String
    private let authToken: String?
    private let batchSize: Int
    private let flushInterval: Duration
    private var buffer: [LogEntry] = []
    private var flushTask: Task<Void, Never>?

    public struct LogEntry: Sendable {
        let timestamp: UInt64  // nanoseconds
        let severityNumber: Int
        let severityText: String
        let body: String
        let attributes: [(String, String)]
    }

    public init(
        endpoint: String,
        serviceName: String = "trebuchet",
        authToken: String? = nil,
        batchSize: Int = 128,
        flushInterval: Duration = .seconds(3)
    ) {
        self.endpoint = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        self.serviceName = serviceName
        self.authToken = authToken
        self.batchSize = batchSize
        self.flushInterval = flushInterval
    }

    public func append(_ entry: LogEntry) {
        buffer.append(entry)
        ensurePeriodicFlush()
        if buffer.count >= batchSize {
            let batch = buffer
            buffer = []
            Task { await send(batch) }
        }
    }

    private func ensurePeriodicFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.flushInterval ?? .seconds(3))
                await self?.flush()
            }
        }
    }

    public func flush() async {
        guard !buffer.isEmpty else { return }
        let batch = buffer
        buffer = []
        await send(batch)
    }

    /// Gracefully shut down the exporter, flushing any buffered logs.
    public func shutdown() async {
        flushTask?.cancel()
        flushTask = nil
        guard !buffer.isEmpty else { return }
        let batch = buffer
        buffer = []
        await send(batch)
    }

    private func send(_ entries: [LogEntry]) async {
        guard !entries.isEmpty else { return }

        let payload = buildOTLPPayload(entries)
        guard let url = URL(string: "\(endpoint)/v1/logs") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authToken {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = payload

        _ = try? await URLSession.shared.data(for: request)
    }

    private func buildOTLPPayload(_ entries: [LogEntry]) -> Data {
        // Build OTLP JSON for /v1/logs
        var logRecords: [[String: Any]] = []

        for entry in entries {
            var record: [String: Any] = [
                "timeUnixNano": String(entry.timestamp),
                "severityNumber": entry.severityNumber,
                "severityText": entry.severityText,
                "body": ["stringValue": entry.body] as [String: Any],
            ]

            if !entry.attributes.isEmpty {
                record["attributes"] = entry.attributes.map { key, value in
                    ["key": key, "value": ["stringValue": value] as [String: Any]] as [String: Any]
                }
            }

            logRecords.append(record)
        }

        let payload: [String: Any] = [
            "resourceLogs": [[
                "resource": [
                    "attributes": [
                        ["key": "service.name", "value": ["stringValue": serviceName]]
                    ]
                ],
                "scopeLogs": [[
                    "logRecords": logRecords
                ]]
            ]]
        ]

        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }

    /// Map swift-log level to OTLP severity number
    public static func severityNumber(for level: Logger.Level) -> Int {
        switch level {
        case .trace: return 1
        case .debug: return 5
        case .info: return 9
        case .notice: return 10
        case .warning: return 13
        case .error: return 17
        case .critical: return 21
        }
    }

    /// Map swift-log level to severity text
    public static func severityText(for level: Logger.Level) -> String {
        switch level {
        case .trace: return "TRACE"
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .notice: return "INFO"
        case .warning: return "WARN"
        case .error: return "ERROR"
        case .critical: return "FATAL"
        }
    }
}
#endif
