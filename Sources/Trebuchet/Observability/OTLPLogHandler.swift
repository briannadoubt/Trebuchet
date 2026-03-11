#if !os(WASI)
import Foundation
import Logging

/// A swift-log LogHandler that exports log records via OTLP/HTTP.
///
/// Also writes to stderr for local visibility.
public struct OTLPLogHandler: LogHandler {
    public var metadata: Logger.Metadata = [:]
    public var logLevel: Logger.Level = .info
    public let label: String
    private let exporter: OTLPLogExporter
    private let localHandler: any LogHandler

    public init(label: String, exporter: OTLPLogExporter, format: LogFormat = .console) {
        self.label = label
        self.exporter = exporter
        switch format {
        case .console:
            self.localHandler = TrebuchetLogHandler(label: label)
        case .json:
            self.localHandler = TrebuchetJSONLogHandler(label: label)
        }
    }

    public subscript(metadataKey key: String) -> Logger.MetadataValue? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    public func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        // Also log locally
        var local = localHandler
        local.logLevel = logLevel
        local.log(level: level, message: message, metadata: metadata, source: source, file: file, function: function, line: line)

        // Export to OTLP
        let merged = self.metadata.merging(metadata ?? [:]) { _, new in new }
        let attrs = merged.map { ("\($0.key)", "\($0.value)") }
            + [("source", source), ("label", label)]

        let timestamp = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)

        let entry = OTLPLogExporter.LogEntry(
            timestamp: timestamp,
            severityNumber: OTLPLogExporter.severityNumber(for: level),
            severityText: OTLPLogExporter.severityText(for: level),
            body: "\(message)",
            attributes: attrs
        )

        Task { await exporter.append(entry) }
    }
}
#endif
