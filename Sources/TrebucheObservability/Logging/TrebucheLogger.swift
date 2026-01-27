// TrebuchetLogger.swift
// Main logging interface for Trebuchet observability

import Foundation

/// Configuration for logger behavior
public struct LoggingConfiguration: Sendable {
    /// Minimum log level to output (messages below this level are filtered)
    public var level: LogLevel

    /// Whether to include metadata in log output
    public var includeMetadata: Bool

    /// Whether to redact sensitive data from metadata
    public var redactSensitiveData: Bool

    /// Keys to redact if redactSensitiveData is true
    public var sensitiveKeys: Set<String>

    /// Creates a new logging configuration
    /// - Parameters:
    ///   - level: Minimum log level (default: .info)
    ///   - includeMetadata: Whether to include metadata (default: true)
    ///   - redactSensitiveData: Whether to redact sensitive data (default: true)
    ///   - sensitiveKeys: Keys to redact (default: common sensitive fields)
    public init(
        level: LogLevel = .info,
        includeMetadata: Bool = true,
        redactSensitiveData: Bool = true,
        sensitiveKeys: Set<String> = ["password", "token", "secret", "apiKey", "authorization", "cookie"]
    ) {
        self.level = level
        self.includeMetadata = includeMetadata
        self.redactSensitiveData = redactSensitiveData
        self.sensitiveKeys = sensitiveKeys
    }

    /// Default configuration for production use
    public static let `default` = LoggingConfiguration()

    /// Development configuration with debug logging
    public static let development = LoggingConfiguration(
        level: .debug,
        redactSensitiveData: false
    )
}

/// Structured logger for Trebuchet distributed actors
public actor TrebuchetLogger {
    /// Logger label identifying the source
    public let label: String

    /// Configuration controlling logger behavior
    public var configuration: LoggingConfiguration

    /// Formatter for log output
    public let formatter: LogFormatter

    /// Output handler for formatted log messages
    private let output: @Sendable (String) -> Void

    /// Creates a new logger
    /// - Parameters:
    ///   - label: Identifier for this logger (e.g., actor type, component name)
    ///   - configuration: Logger configuration
    ///   - formatter: Log formatter (default: console formatter)
    ///   - output: Output handler (default: print to stderr)
    public init(
        label: String,
        configuration: LoggingConfiguration = .default,
        formatter: LogFormatter = ConsoleFormatter(),
        output: @escaping @Sendable (String) -> Void = defaultOutput
    ) {
        self.label = label
        self.configuration = configuration
        self.formatter = formatter
        self.output = output
    }

    /// Logs a message at the specified level
    /// - Parameters:
    ///   - level: Log severity level
    ///   - message: Log message
    ///   - metadata: Optional metadata to attach
    ///   - correlationID: Optional correlation ID for distributed tracing
    public func log(
        level: LogLevel,
        message: String,
        metadata: [String: String] = [:],
        correlationID: UUID? = nil
    ) {
        // Filter by level
        guard level >= configuration.level else { return }

        // Process metadata
        var processedMetadata = configuration.includeMetadata ? metadata : [:]
        if configuration.redactSensitiveData {
            processedMetadata = redact(metadata: processedMetadata)
        }

        // Create context and format
        let context = LogContext(
            label: label,
            metadata: processedMetadata,
            correlationID: correlationID
        )
        let formatted = formatter.format(level: level, message: message, context: context)
        output(formatted)
    }

    /// Convenience method for debug-level logs
    public func debug(_ message: String, metadata: [String: String] = [:], correlationID: UUID? = nil) {
        log(level: .debug, message: message, metadata: metadata, correlationID: correlationID)
    }

    /// Convenience method for info-level logs
    public func info(_ message: String, metadata: [String: String] = [:], correlationID: UUID? = nil) {
        log(level: .info, message: message, metadata: metadata, correlationID: correlationID)
    }

    /// Convenience method for warning-level logs
    public func warning(_ message: String, metadata: [String: String] = [:], correlationID: UUID? = nil) {
        log(level: .warning, message: message, metadata: metadata, correlationID: correlationID)
    }

    /// Convenience method for error-level logs
    public func error(_ message: String, metadata: [String: String] = [:], correlationID: UUID? = nil) {
        log(level: .error, message: message, metadata: metadata, correlationID: correlationID)
    }

    /// Convenience method for critical-level logs
    public func critical(_ message: String, metadata: [String: String] = [:], correlationID: UUID? = nil) {
        log(level: .critical, message: message, metadata: metadata, correlationID: correlationID)
    }

    /// Redacts sensitive values from metadata
    private func redact(metadata: [String: String]) -> [String: String] {
        var redacted = metadata
        for key in configuration.sensitiveKeys {
            if redacted[key] != nil {
                redacted[key] = "[REDACTED]"
            }
            // Also check case-insensitive
            let lowerKey = key.lowercased()
            for (metaKey, _) in metadata where metaKey.lowercased().contains(lowerKey) {
                redacted[metaKey] = "[REDACTED]"
            }
        }
        return redacted
    }
}

/// Default output handler that prints to stderr
///
/// Uses Foundation's FileHandle.standardError which is concurrency-safe.
public let defaultOutput: @Sendable (String) -> Void = { message in
    if let data = (message + "\n").data(using: .utf8) {
        try? FileHandle.standardError.write(contentsOf: data)
    }
}
