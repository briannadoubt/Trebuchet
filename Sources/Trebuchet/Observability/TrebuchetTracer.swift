#if !os(WASI)
import Tracing
import Foundation

/// A Tracer implementation that routes completed spans to a configured ``SpanExportBackend``.
///
/// This tracer integrates with Swift's `InstrumentationSystem` and is automatically
/// bootstrapped when a ``System`` declares tracing in its observability configuration.
public final class TrebuchetTracer: Tracer, Sendable {
    public typealias Span = TrebuchetRecordingSpan

    private let exportBackend: any SpanExportBackend
    private let serviceName: String

    public init(serviceName: String, exportBackend: any SpanExportBackend) {
        self.serviceName = serviceName
        self.exportBackend = exportBackend
    }

    public func startSpan<Instant: TracerInstant>(
        _ operationName: String,
        context: @autoclosure () -> ServiceContext,
        ofKind kind: SpanKind,
        at instant: @autoclosure () -> Instant,
        function: String,
        file: String,
        line: UInt
    ) -> TrebuchetRecordingSpan {
        let ctx = context()
        return TrebuchetRecordingSpan(
            operationName: operationName,
            context: ctx,
            kind: kind,
            startTime: instant().asInstant,
            exportBackend: exportBackend
        )
    }

    public func forceFlush() {
        Task {
            await exportBackend.flush()
        }
    }

    public func inject<Carrier, Inject>(
        _ context: ServiceContext,
        into carrier: inout Carrier,
        using injector: Inject
    ) where Inject: Injector, Inject.Carrier == Carrier {
        // Inject W3C traceparent if available
        if let traceID = context.trebuchetTraceID, let spanID = context.trebuchetSpanID {
            let traceparent = "00-\(traceID)-\(spanID)-01"
            injector.inject(traceparent, forKey: "traceparent", into: &carrier)
        }
    }

    public func extract<Carrier, Extract>(
        _ carrier: Carrier,
        into context: inout ServiceContext,
        using extractor: Extract
    ) where Extract: Extractor, Extract.Carrier == Carrier {
        // Extract W3C traceparent
        if let traceparent = extractor.extract(key: "traceparent", from: carrier) {
            let parts = traceparent.split(separator: "-")
            if parts.count >= 3 {
                context.trebuchetTraceID = String(parts[1])
                context.trebuchetSpanID = String(parts[2])
            }
        }
    }
}

// MARK: - Recording Span

/// A concrete Span implementation that records attributes, events, and exports on end.
public final class TrebuchetRecordingSpan: Tracing.Span, @unchecked Sendable {
    private let lock = NSLock()
    private let exportBackend: any SpanExportBackend
    private let startTime: ContinuousClock.Instant

    public let context: ServiceContext
    public let kind: SpanKind

    public var operationName: String {
        get { lock.withLock { _operationName } }
        set { lock.withLock { _operationName = newValue } }
    }

    public var attributes: SpanAttributes {
        get { lock.withLock { _attributes } }
        set { lock.withLock { _attributes = newValue } }
    }

    public var isRecording: Bool {
        lock.withLock { !_ended }
    }

    private var _operationName: String
    private var _attributes = SpanAttributes()
    private var _status: SpanStatus = .init(code: .ok)
    private var _events: [SpanEvent] = []
    private var _links: [SpanLink] = []
    private var _ended = false

    init(
        operationName: String,
        context: ServiceContext,
        kind: SpanKind,
        startTime: ContinuousClock.Instant,
        exportBackend: any SpanExportBackend
    ) {
        self._operationName = operationName
        self.kind = kind
        self.startTime = startTime
        self.exportBackend = exportBackend

        // Generate trace/span IDs and set them on the context
        var ctx = context
        if ctx.trebuchetTraceID == nil {
            // Root span: generate a new trace ID (UUID format for roundtripping)
            ctx.trebuchetTraceID = UUID().uuidString
        }
        // Promote current spanID to parentSpanID, generate new spanID
        if let currentSpanID = ctx.trebuchetSpanID {
            ctx.trebuchetParentSpanID = currentSpanID
        } else if let parentSpanID = ctx.trebuchetParentSpanID {
            // Keep parent span ID from incoming context (e.g., server receiving from client)
            ctx.trebuchetParentSpanID = parentSpanID
        }
        ctx.trebuchetSpanID = UUID().uuidString
        self.context = ctx
    }

    public func setStatus(_ status: SpanStatus) {
        lock.withLock { _status = status }
    }

    public func addEvent(_ event: SpanEvent) {
        lock.withLock { _events.append(event) }
    }

    public func addLink(_ link: SpanLink) {
        lock.withLock { _links.append(link) }
    }

    public func recordError<Clock: TracerInstant>(
        _ error: any Error,
        attributes: SpanAttributes,
        at instant: @autoclosure () -> Clock
    ) {
        lock.withLock {
            _status = .init(code: .error, message: String(describing: error))
            _events.append(SpanEvent(name: "exception", attributes: attributes))
        }
    }

    public func end<Clock: TracerInstant>(at instant: @autoclosure () -> Clock) {
        let endTime = instant().asInstant
        lock.lock()
        guard !_ended else {
            lock.unlock()
            return
        }
        _ended = true
        let snapshot = ExportableSpan(
            operationName: _operationName,
            kind: kind,
            context: context,
            status: _status,
            attributes: _attributes,
            events: _events,
            links: _links,
            startTime: startTime,
            endTime: endTime
        )
        lock.unlock()

        Task {
            await exportBackend.export(snapshot)
        }
    }
}

// MARK: - Exportable Span

/// A snapshot of a completed span, ready for export.
public struct ExportableSpan: Sendable {
    public let operationName: String
    public let kind: SpanKind
    public let context: ServiceContext
    public let status: SpanStatus
    public let attributes: SpanAttributes
    public let events: [SpanEvent]
    public let links: [SpanLink]
    public let startTime: ContinuousClock.Instant
    public let endTime: ContinuousClock.Instant

    public var traceID: String? { context.trebuchetTraceID }
    public var spanID: String? { context.trebuchetSpanID }
    public var parentSpanID: String? { context.trebuchetParentSpanID }

    public var durationNanoseconds: UInt64 {
        let start = startTime
        let end = endTime
        let duration = start.duration(to: end)
        let seconds = duration.components.seconds
        let attoseconds = duration.components.attoseconds
        return UInt64(seconds) * 1_000_000_000 + UInt64(attoseconds / 1_000_000_000)
    }
}

// MARK: - Export Backend Protocol

/// Protocol for span export backends (OTLP, console, in-memory).
public protocol SpanExportBackend: Sendable {
    func export(_ span: ExportableSpan) async
    func flush() async
}

// MARK: - Console Export Backend

/// Prints completed spans to stderr for development.
public actor ConsoleSpanExportBackend: SpanExportBackend {
    public init() {}

    public func export(_ span: ExportableSpan) {
        let traceID = span.traceID ?? "unknown"
        let spanID = span.spanID ?? "unknown"
        let durationMs = Double(span.durationNanoseconds) / 1_000_000
        let status = span.status.code == .error ? "ERROR" : "OK"

        var output = "[TRACE] \(span.operationName) [\(status)] \(String(format: "%.2f", durationMs))ms"
        output += " trace=\(traceID.prefix(8)) span=\(spanID.prefix(8))"

        if !span.attributes.isEmpty {
            output += " \(span.attributes)"
        }

        FileHandle.standardError.write(Data((output + "\n").utf8))
    }

    public func flush() {}
}

// MARK: - In-Memory Export Backend (for testing)

/// Collects spans in memory for testing and inspection.
public actor InMemorySpanExportBackend: SpanExportBackend {
    public private(set) var spans: [ExportableSpan] = []

    public init() {}

    public func export(_ span: ExportableSpan) {
        spans.append(span)
    }

    public func flush() {}

    public func reset() {
        spans.removeAll()
    }
}

// MARK: - Service Context Keys

private enum TrebuchetTraceIDKey: ServiceContextKey {
    typealias Value = String
    static let nameOverride: String? = "trebuchet-trace-id"
}

private enum TrebuchetSpanIDKey: ServiceContextKey {
    typealias Value = String
    static let nameOverride: String? = "trebuchet-span-id"
}

private enum TrebuchetParentSpanIDKey: ServiceContextKey {
    typealias Value = String
    static let nameOverride: String? = "trebuchet-parent-span-id"
}

public extension ServiceContext {
    var trebuchetTraceID: String? {
        get { self[TrebuchetTraceIDKey.self] }
        set { self[TrebuchetTraceIDKey.self] = newValue }
    }

    var trebuchetSpanID: String? {
        get { self[TrebuchetSpanIDKey.self] }
        set { self[TrebuchetSpanIDKey.self] = newValue }
    }

    var trebuchetParentSpanID: String? {
        get { self[TrebuchetParentSpanIDKey.self] }
        set { self[TrebuchetParentSpanIDKey.self] = newValue }
    }
}

// MARK: - TracerInstant Helpers

private extension TracerInstant {
    var asInstant: ContinuousClock.Instant {
        if let instant = self as? ContinuousClock.Instant {
            return instant
        }
        // Fallback: use current time
        return .now
    }
}
#endif
