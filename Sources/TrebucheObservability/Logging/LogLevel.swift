// LogLevel.swift
// Log severity levels for structured logging

import Foundation

/// Severity levels for log messages
public enum LogLevel: String, Sendable, Codable, Comparable, CaseIterable {
    /// Debug-level messages for detailed diagnostic information
    case debug

    /// Informational messages for general operational information
    case info

    /// Warning messages for potentially harmful situations
    case warning

    /// Error messages for error events that might still allow the application to continue running
    case error

    /// Critical messages for severe error events that might cause the application to abort
    case critical

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.priority < rhs.priority
    }

    private var priority: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        case .critical: return 4
        }
    }
}
