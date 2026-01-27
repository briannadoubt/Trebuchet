// LogFormatter.swift
// Protocol and implementations for formatting log output

import Foundation

/// Protocol for formatting log messages
public protocol LogFormatter: Sendable {
    /// Formats a log message for output
    /// - Parameters:
    ///   - level: Log severity level
    ///   - message: Log message content
    ///   - context: Structured metadata context
    /// - Returns: Formatted log string
    func format(level: LogLevel, message: String, context: LogContext) -> String
}
