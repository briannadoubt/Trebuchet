#if !os(WASI)
import Foundation
import Logging
import Tracing

/// Configuration for client-side distributed tracing.
public struct ClientTracing: Sendable {
    public let endpoint: String
    public let serviceName: String
    public let authToken: String?

    /// Configure OTLP trace export for client-side spans.
    ///
    /// ```swift
    /// .trebuchet(
    ///     transport: .webSocket(host: "api.example.com", port: 8080),
    ///     tracing: .otlp(endpoint: "http://otel.example.com:4318")
    /// )
    /// ```
    public static func otlp(
        endpoint: String,
        serviceName: String = "TrebuchetClient",
        authToken: String? = nil
    ) -> ClientTracing {
        ClientTracing(endpoint: endpoint, serviceName: serviceName, authToken: authToken)
    }
}

/// Bootstrap client-side distributed tracing.
///
/// Call this once at app startup to enable OTLP span export from the client.
/// This is called automatically when using the `.trebuchet(tracing:)` SwiftUI modifier.
public enum TrebuchetTracing {
    nonisolated(unsafe) private static var isBootstrapped = false

    /// Bootstrap the tracing system with an OTLP exporter.
    ///
    /// - Parameters:
    ///   - endpoint: The OTLP collector endpoint (e.g., "http://localhost:4318")
    ///   - serviceName: Service name for span identification
    ///   - authToken: Optional Bearer token for authenticated collectors
    public static func bootstrap(
        endpoint: String,
        serviceName: String = "TrebuchetClient",
        authToken: String? = nil
    ) {
        guard !isBootstrapped else { return }
        isBootstrapped = true

        // Bootstrap tracing
        let backend = OTLPSpanExporter(
            endpoint: endpoint,
            serviceName: serviceName,
            authToken: authToken
        )
        let tracer = TrebuchetTracer(serviceName: serviceName, exportBackend: backend)
        InstrumentationSystem.bootstrap(tracer)

        // Bootstrap logging with OTLP export
        let logExporter = OTLPLogExporter(
            endpoint: endpoint,
            serviceName: serviceName,
            authToken: authToken
        )
        LoggingSystem.bootstrap { label in
            var handler = OTLPLogHandler(label: label, exporter: logExporter)
            handler.logLevel = .info
            return handler
        }
    }

    /// Bootstrap from a ClientTracing configuration.
    public static func bootstrap(_ config: ClientTracing) {
        bootstrap(
            endpoint: config.endpoint,
            serviceName: config.serviceName,
            authToken: config.authToken
        )
    }
}
#endif
