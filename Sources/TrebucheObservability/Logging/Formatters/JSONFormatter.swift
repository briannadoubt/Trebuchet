// JSONFormatter.swift
// JSON-formatted structured logging for machine parsing

import Foundation

/// JSON log formatter for structured logging systems
public struct JSONFormatter: LogFormatter {
    /// Whether to pretty-print JSON output
    public let prettyPrint: Bool

    /// ISO8601 date formatter for timestamps
    private nonisolated(unsafe) static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Creates a new JSON formatter
    /// - Parameter prettyPrint: Whether to format JSON with indentation (default: false)
    public init(prettyPrint: Bool = false) {
        self.prettyPrint = prettyPrint
    }

    public func format(level: LogLevel, message: String, context: LogContext) -> String {
        var json: [String: Any] = [
            "timestamp": Self.dateFormatter.string(from: context.timestamp),
            "level": level.rawValue,
            "label": context.label,
            "message": message
        ]

        if !context.metadata.isEmpty {
            json["metadata"] = context.metadata
        }

        if let correlationID = context.correlationID {
            json["correlation_id"] = correlationID.uuidString
        }

        do {
            let options: JSONSerialization.WritingOptions = prettyPrint ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
            let data = try JSONSerialization.data(withJSONObject: json, options: options)
            return String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            return """
            {"error":"Failed to encode log as JSON","original_message":"\(message)"}
            """
        }
    }
}
