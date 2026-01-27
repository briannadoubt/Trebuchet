// ConsoleFormatter.swift
// Human-readable console log formatting

import Foundation

/// Console-friendly log formatter with optional color support
public struct ConsoleFormatter: LogFormatter {
    /// Whether to include ANSI color codes in output
    public let colorEnabled: Bool

    /// ISO8601 date formatter for timestamps
    private nonisolated(unsafe) static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Creates a new console formatter
    /// - Parameter colorEnabled: Whether to include ANSI color codes (default: false)
    public init(colorEnabled: Bool = false) {
        self.colorEnabled = colorEnabled
    }

    public func format(level: LogLevel, message: String, context: LogContext) -> String {
        let timestamp = Self.dateFormatter.string(from: context.timestamp)
        let levelStr = colorEnabled ? colorize(level: level) : "[\(level.rawValue.uppercased())]"
        let label = "[\(context.label)]"

        var output = "\(timestamp) \(levelStr) \(label) \(message)"

        if !context.metadata.isEmpty {
            let metadataStr = context.metadata
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            output += " | \(metadataStr)"
        }

        if let correlationID = context.correlationID {
            output += " | correlation_id=\(correlationID.uuidString)"
        }

        return output
    }

    private func colorize(level: LogLevel) -> String {
        let color: String
        switch level {
        case .debug: color = "\u{001B}[0;36m" // Cyan
        case .info: color = "\u{001B}[0;32m" // Green
        case .warning: color = "\u{001B}[0;33m" // Yellow
        case .error: color = "\u{001B}[0;31m" // Red
        case .critical: color = "\u{001B}[0;35m" // Magenta
        }
        let reset = "\u{001B}[0m"
        return "\(color)[\(level.rawValue.uppercased())]\(reset)"
    }
}
