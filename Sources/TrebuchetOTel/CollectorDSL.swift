import Trebuchet
import Foundation

/// An OTel collector infrastructure node for the Trebuchet topology DSL.
///
/// Add a `Collector` to your system topology to automatically start a
/// self-hosted OpenTelemetry backend alongside your actors:
///
/// ```swift
/// @TopologyBuilder
/// var topology: some Topology {
///     Collector(port: 4318)
///
///     GameRoom.self
///         .expose(as: "game-room")
/// }
/// ```
///
/// The collector runs an HTTP server that accepts OTLP/HTTP JSON on
/// `/v1/traces` and `/v1/logs`, stores data in a local SQLite database,
/// and serves an embedded web dashboard.
public func Collector(
    port: Int = 4318,
    authToken: String? = nil,
    storagePath: String? = nil,
    retentionHours: Int = 72
) -> AnyTopology {
    let descriptor = CollectorDescriptor(
        port: port,
        authToken: authToken,
        storagePath: storagePath,
        retentionHours: retentionHours
    )

    return AnyTopology { collector, _ in
        collector.addCollector(descriptor: descriptor) {
            let path = storagePath ?? NSTemporaryDirectory() + "trebuchet-otel.sqlite"
            let store = try SpanStore(path: path)
            let ingester = SpanIngester(store: store)
            let server = try await OTelHTTPServer(
                host: "0.0.0.0",
                port: port,
                ingester: ingester,
                store: store,
                authToken: authToken
            )
            Task { try await server.run() }

            if retentionHours > 0 {
                let sweeper = RetentionSweeper(store: store, maxAge: .seconds(retentionHours * 3600))
                Task { await sweeper.start() }
            }

            return server
        }
    }
}
