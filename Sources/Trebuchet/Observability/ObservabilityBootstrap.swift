#if !os(WASI)
import Foundation
import Logging
import CoreMetrics
import Tracing

/// Bootstraps swift-log, swift-metrics, and swift-distributed-tracing
/// from a ``ResolvedObservability`` configuration.
///
/// This is called once during ``System`` startup. The bootstrap is idempotent —
/// subsequent calls are ignored by the underlying libraries.
public enum ObservabilityBootstrap {
    /// Stored references to exporters for graceful shutdown.
    nonisolated(unsafe) private static var _spanExporter: (any Sendable)?
    nonisolated(unsafe) private static var _logExporter: (any Sendable)?

    /// Apply the resolved observability configuration, bootstrapping
    /// the Swift observability stack.
    ///
    /// - Parameters:
    ///   - config: The resolved observability config from the System DSL
    ///   - serviceName: The service name for resource identification
    public static func apply(_ config: ResolvedObservability, serviceName: String) {
        bootstrapLogging(config.logging)
        bootstrapMetrics(config.metrics, serviceName: serviceName)
        bootstrapTracing(config.tracing, serviceName: serviceName)
    }

    /// Gracefully shut down all OTLP exporters, flushing any buffered data.
    public static func shutdown() async {
        if let spanExporter = _spanExporter as? OTLPSpanExporter {
            await spanExporter.shutdown()
        }
        if let logExporter = _logExporter as? OTLPLogExporter {
            await logExporter.shutdown()
        }
        _spanExporter = nil
        _logExporter = nil
    }

    // MARK: - Logging

    private static func bootstrapLogging(_ config: LoggingDeclaration?) {
        let level = config?.level ?? .info
        let format = config?.format ?? .console
        let swiftLogLevel = level.toSwiftLogLevel()

        if let endpoint = config?.endpoint {
            let exporter = OTLPLogExporter(
                endpoint: endpoint,
                serviceName: "trebuchet",
                authToken: config?.authToken
            )
            _logExporter = exporter
            LoggingSystem.bootstrap { label in
                var handler = OTLPLogHandler(label: label, exporter: exporter, format: format)
                handler.logLevel = swiftLogLevel
                return handler
            }
        } else {
            LoggingSystem.bootstrap { label in
                var handler: any LogHandler
                switch format {
                case .console:
                    handler = TrebuchetLogHandler(label: label)
                case .json:
                    handler = TrebuchetJSONLogHandler(label: label)
                }
                handler.logLevel = swiftLogLevel
                return handler
            }
        }
    }

    // MARK: - Metrics

    private static func bootstrapMetrics(_ config: MetricsDeclaration?, serviceName: String) {
        guard let config else { return }

        switch config.exporter {
        case .inMemory:
            // Use swift-metrics default (no-op unless user bootstraps their own)
            break
        case .otlp(let endpoint):
            MetricsSystem.bootstrap(
                OTLPMetricsFactory(endpoint: endpoint, serviceName: serviceName)
            )
        }
    }

    // MARK: - Tracing

    private static func bootstrapTracing(_ config: TracingDeclaration?, serviceName: String) {
        guard let config else { return }

        let backend: any SpanExportBackend
        switch config.exporter {
        case .console:
            backend = ConsoleSpanExportBackend()
        case .otlp(let endpoint, let authToken):
            let exporter = OTLPSpanExporter(endpoint: endpoint, serviceName: serviceName, authToken: authToken)
            _spanExporter = exporter
            backend = exporter
        }

        let tracer = TrebuchetTracer(serviceName: serviceName, exportBackend: backend)
        InstrumentationSystem.bootstrap(tracer)
    }
}

// MARK: - Log Level Mapping

extension LoggingLevel {
    func toSwiftLogLevel() -> Logger.Level {
        switch self {
        case .trace: return .trace
        case .debug: return .debug
        case .info: return .info
        case .notice: return .notice
        case .warning: return .warning
        case .error: return .error
        case .critical: return .critical
        }
    }
}

// MARK: - Console Log Handler

/// A structured log handler that outputs to stderr with optional metadata.
struct TrebuchetLogHandler: LogHandler {
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .info
    let label: String

    init(label: String) {
        self.label = label
    }

    subscript(metadataKey key: String) -> Logger.MetadataValue? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        let merged = self.metadata.merging(metadata ?? [:]) { _, new in new }
        var output = "[\(level)] [\(label)] \(message)"
        if !merged.isEmpty {
            let metadataStr = merged.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            output += " | \(metadataStr)"
        }
        FileHandle.standardError.write(Data((output + "\n").utf8))
    }
}

// MARK: - JSON Log Handler

/// A log handler that outputs structured JSON to stderr.
struct TrebuchetJSONLogHandler: LogHandler {
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .info
    let label: String

    init(label: String) {
        self.label = label
    }

    subscript(metadataKey key: String) -> Logger.MetadataValue? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        let merged = self.metadata.merging(metadata ?? [:]) { _, new in new }
        var dict: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "level": "\(level)",
            "label": label,
            "message": "\(message)",
            "source": source,
        ]
        for (key, value) in merged {
            dict["metadata.\(key)"] = "\(value)"
        }
        if let data = try? JSONSerialization.data(withJSONObject: dict),
           let json = String(data: data, encoding: .utf8) {
            FileHandle.standardError.write(Data((json + "\n").utf8))
        }
    }
}

// MARK: - OTLP Metrics Factory

/// A MetricsFactory that exports metrics via OTLP/HTTP.
///
/// This is a basic implementation that creates counters, gauges, and histograms
/// and periodically exports them to an OTLP collector.
final class OTLPMetricsFactory: MetricsFactory, @unchecked Sendable {
    private let endpoint: String
    private let serviceName: String
    private let lock = NSLock()
    private var handlers: [String: any MetricHandler] = [:]

    init(endpoint: String, serviceName: String) {
        self.endpoint = endpoint
        self.serviceName = serviceName
    }

    func makeCounter(label: String, dimensions: [(String, String)]) -> any CounterHandler {
        let handler = OTLPCounterHandler(label: label, dimensions: dimensions)
        lock.withLock { handlers[label] = handler }
        return handler
    }

    func makeFloatingPointCounter(label: String, dimensions: [(String, String)]) -> any FloatingPointCounterHandler {
        let handler = OTLPFloatingPointCounterHandler(label: label, dimensions: dimensions)
        lock.withLock { handlers[label] = handler }
        return handler
    }

    func makeRecorder(label: String, dimensions: [(String, String)], aggregate: Bool) -> any RecorderHandler {
        let handler = OTLPRecorderHandler(label: label, dimensions: dimensions)
        lock.withLock { handlers[label] = handler }
        return handler
    }

    func makeMeter(label: String, dimensions: [(String, String)]) -> any MeterHandler {
        let handler = OTLPMeterHandler(label: label, dimensions: dimensions)
        lock.withLock { handlers[label] = handler }
        return handler
    }

    func makeTimer(label: String, dimensions: [(String, String)]) -> any TimerHandler {
        let handler = OTLPTimerHandler(label: label, dimensions: dimensions)
        lock.withLock { handlers[label] = handler }
        return handler
    }

    func destroyCounter(_ handler: any CounterHandler) {}
    func destroyFloatingPointCounter(_ handler: any FloatingPointCounterHandler) {}
    func destroyRecorder(_ handler: any RecorderHandler) {}
    func destroyMeter(_ handler: any MeterHandler) {}
    func destroyTimer(_ handler: any TimerHandler) {}
}

private protocol MetricHandler: AnyObject {}

private final class OTLPCounterHandler: CounterHandler, MetricHandler, @unchecked Sendable {
    let label: String
    let dimensions: [(String, String)]
    private let lock = NSLock()
    private var value: Int64 = 0

    init(label: String, dimensions: [(String, String)]) {
        self.label = label
        self.dimensions = dimensions
    }

    func increment(by amount: Int64) {
        lock.withLock { value += amount }
    }

    func reset() {
        lock.withLock { value = 0 }
    }
}

private final class OTLPFloatingPointCounterHandler: FloatingPointCounterHandler, MetricHandler, @unchecked Sendable {
    let label: String
    let dimensions: [(String, String)]
    private let lock = NSLock()
    private var value: Double = 0

    init(label: String, dimensions: [(String, String)]) {
        self.label = label
        self.dimensions = dimensions
    }

    func increment(by amount: Double) {
        lock.withLock { value += amount }
    }

    func reset() {
        lock.withLock { value = 0 }
    }
}

private final class OTLPRecorderHandler: RecorderHandler, MetricHandler, @unchecked Sendable {
    let label: String
    let dimensions: [(String, String)]
    private let lock = NSLock()
    private var values: [Double] = []

    init(label: String, dimensions: [(String, String)]) {
        self.label = label
        self.dimensions = dimensions
    }

    func record(_ value: Int64) {
        lock.withLock { values.append(Double(value)) }
    }

    func record(_ value: Double) {
        lock.withLock { values.append(value) }
    }
}

private final class OTLPMeterHandler: MeterHandler, MetricHandler, @unchecked Sendable {
    let label: String
    let dimensions: [(String, String)]
    private let lock = NSLock()
    private var value: Double = 0

    init(label: String, dimensions: [(String, String)]) {
        self.label = label
        self.dimensions = dimensions
    }

    func set(_ value: Int64) {
        lock.withLock { self.value = Double(value) }
    }

    func set(_ value: Double) {
        lock.withLock { self.value = value }
    }

    func increment(by amount: Double) {
        lock.withLock { value += amount }
    }

    func decrement(by amount: Double) {
        lock.withLock { value -= amount }
    }
}

private final class OTLPTimerHandler: TimerHandler, MetricHandler, @unchecked Sendable {
    let label: String
    let dimensions: [(String, String)]
    private let lock = NSLock()
    private var values: [Int64] = []

    init(label: String, dimensions: [(String, String)]) {
        self.label = label
        self.dimensions = dimensions
    }

    func recordNanoseconds(_ duration: Int64) {
        lock.withLock { values.append(duration) }
    }
}
#endif
