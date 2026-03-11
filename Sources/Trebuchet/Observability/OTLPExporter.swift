#if !os(WASI)
import Foundation

/// OTLP/HTTP JSON span exporter.
///
/// Batches completed spans and periodically flushes them to an OpenTelemetry
/// collector via HTTP POST to `/v1/traces` using the OTLP JSON encoding.
///
/// This is a lightweight implementation that avoids gRPC and protobuf dependencies
/// by using the OTLP JSON wire format.
public actor OTLPSpanExporter: SpanExportBackend {
    private let endpoint: String
    private let batchSize: Int
    private let flushInterval: Duration
    private var buffer: [ExportableSpan] = []
    private var flushTask: Task<Void, Never>?
    private let serviceName: String
    private let urlSession: URLSession
    private let authToken: String?

    /// Create an OTLP/HTTP span exporter.
    ///
    /// - Parameters:
    ///   - endpoint: The collector endpoint (e.g. "http://localhost:4318")
    ///   - serviceName: The service name to include in resource attributes
    ///   - authToken: Bearer token for authenticating with the collector (e.g. OTEL_AUTH_TOKEN)
    ///   - batchSize: Maximum spans per batch before auto-flush (default: 256)
    ///   - flushInterval: Time between periodic flushes (default: 5 seconds)
    public init(
        endpoint: String,
        serviceName: String = "trebuchet",
        authToken: String? = nil,
        batchSize: Int = 256,
        flushInterval: Duration = .seconds(5)
    ) {
        self.endpoint = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        self.serviceName = serviceName
        self.authToken = authToken
        self.batchSize = batchSize
        self.flushInterval = flushInterval

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        self.urlSession = URLSession(configuration: config)
    }

    /// Start the periodic flush task. Called lazily on first export.
    private func ensurePeriodicFlush() {
        guard flushTask == nil else { return }
        startPeriodicFlush()
    }

    deinit {
        flushTask?.cancel()
    }

    public func export(_ span: ExportableSpan) {
        ensurePeriodicFlush()
        buffer.append(span)
        if buffer.count >= batchSize {
            Task { await flush() }
        }
    }

    public func flush() {
        guard !buffer.isEmpty else { return }
        let spans = buffer
        buffer.removeAll(keepingCapacity: true)

        Task {
            await sendBatch(spans)
        }
    }

    // MARK: - Private

    private func startPeriodicFlush() {
        flushTask = Task { [weak self, flushInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: flushInterval)
                await self?.flush()
            }
        }
    }

    private nonisolated func sendBatch(_ spans: [ExportableSpan]) async {
        let payload = encodeOTLP(spans: spans)

        guard let url = URL(string: "\(endpoint)/v1/traces") else {
            FileHandle.standardError.write(Data("[OTLP] Invalid endpoint URL: \(endpoint)/v1/traces\n".utf8))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authToken {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = payload

        do {
            let (_, response) = try await urlSession.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
                FileHandle.standardError.write(Data("[OTLP] Export failed with status \(httpResponse.statusCode)\n".utf8))
            }
        } catch {
            FileHandle.standardError.write(Data("[OTLP] Export error: \(error)\n".utf8))
        }
    }

    // MARK: - OTLP JSON Encoding

    /// Encode spans into OTLP JSON format per the OpenTelemetry specification.
    /// https://opentelemetry.io/docs/specs/otlp/#json-protobuf-encoding
    private nonisolated func encodeOTLP(spans: [ExportableSpan]) -> Data {
        // Group spans by trace ID for efficient batching
        var scopeSpans: [[String: Any]] = []

        for span in spans {
            let traceID = (span.traceID ?? UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
            let spanID = String((span.spanID ?? UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased().prefix(16))

            var spanDict: [String: Any] = [
                "traceId": traceID,
                "spanId": spanID,
                "name": span.operationName,
                "kind": otlpSpanKind(span.kind),
                "startTimeUnixNano": String(startTimeNanos(span)),
                "endTimeUnixNano": String(endTimeNanos(span)),
                "status": otlpStatus(span.status),
            ]

            if let parentID = span.parentSpanID {
                spanDict["parentSpanId"] = String(parentID.replacingOccurrences(of: "-", with: "").lowercased().prefix(16))
            }

            // Attributes
            let attrs = otlpAttributes(span.attributes)
            if !attrs.isEmpty {
                spanDict["attributes"] = attrs
            }

            // Events
            if !span.events.isEmpty {
                spanDict["events"] = span.events.map { event in
                    var eventDict: [String: Any] = ["name": event.name]
                    let eventAttrs = otlpAttributes(event.attributes)
                    if !eventAttrs.isEmpty {
                        eventDict["attributes"] = eventAttrs
                    }
                    return eventDict
                }
            }

            scopeSpans.append(spanDict)
        }

        let payload: [String: Any] = [
            "resourceSpans": [
                [
                    "resource": [
                        "attributes": [
                            ["key": "service.name", "value": ["stringValue": serviceName]]
                        ]
                    ],
                    "scopeSpans": [
                        [
                            "scope": ["name": "trebuchet", "version": "1.0"],
                            "spans": scopeSpans,
                        ]
                    ],
                ]
            ]
        ]

        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }

    private nonisolated func otlpSpanKind(_ kind: SpanKind) -> Int {
        switch kind {
        case .internal: return 1
        case .server: return 2
        case .client: return 3
        case .producer: return 4
        case .consumer: return 5
        }
    }

    private nonisolated func otlpStatus(_ status: SpanStatus) -> [String: Any] {
        switch status.code {
        case .ok:
            return ["code": 1]
        case .error:
            var dict: [String: Any] = ["code": 2]
            if let message = status.message {
                dict["message"] = message
            }
            return dict
        }
    }

    private nonisolated func otlpAttributes(_ attributes: SpanAttributes) -> [[String: Any]] {
        var result: [[String: Any]] = []
        attributes.forEach { key, value in
            var otlpValue: [String: Any]
            switch value {
            case .int32(let v): otlpValue = ["intValue": String(v)]
            case .int64(let v): otlpValue = ["intValue": String(v)]
            case .int32Array(let v): otlpValue = ["arrayValue": ["values": v.map { ["intValue": String($0)] }]]
            case .int64Array(let v): otlpValue = ["arrayValue": ["values": v.map { ["intValue": String($0)] }]]
            case .double(let v): otlpValue = ["doubleValue": v]
            case .doubleArray(let v): otlpValue = ["arrayValue": ["values": v.map { ["doubleValue": $0] }]]
            case .bool(let v): otlpValue = ["boolValue": v]
            case .boolArray(let v): otlpValue = ["arrayValue": ["values": v.map { ["boolValue": $0] }]]
            case .string(let v): otlpValue = ["stringValue": v]
            case .stringArray(let v): otlpValue = ["arrayValue": ["values": v.map { ["stringValue": $0] }]]
            case .stringConvertible(let v): otlpValue = ["stringValue": v.description]
            case .stringConvertibleArray(let v): otlpValue = ["arrayValue": ["values": v.map { ["stringValue": $0.description] }]]
            @unknown default: otlpValue = ["stringValue": "\(value)"]
            }
            result.append(["key": key, "value": otlpValue])
        }
        return result
    }

    private nonisolated func startTimeNanos(_ span: ExportableSpan) -> UInt64 {
        let now = ContinuousClock.now
        let elapsed = span.startTime.duration(to: now)
        let wallNow = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        let elapsedNanos = UInt64(elapsed.components.seconds) * 1_000_000_000 + UInt64(elapsed.components.attoseconds / 1_000_000_000)
        return wallNow - elapsedNanos
    }

    private nonisolated func endTimeNanos(_ span: ExportableSpan) -> UInt64 {
        startTimeNanos(span) + span.durationNanoseconds
    }
}

// Import SpanKind and SpanStatus from Tracing
import Tracing
#endif
