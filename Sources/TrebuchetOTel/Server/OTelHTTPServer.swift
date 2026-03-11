import NIO
import NIOHTTP1
import NIOFoundationCompat
import Foundation
import Trebuchet

extension OTelHTTPServer: GracefullyShutdownable {}

/// An HTTP server that accepts OTLP/HTTP JSON telemetry data and serves a query API.
///
/// ``OTelHTTPServer`` binds to the specified host and port using SwiftNIO, configures an
/// HTTP pipeline, and routes incoming requests through ``OTelHTTPHandler`` for OTLP
/// ingestion and span/log/metric queries.
public final class OTelHTTPServer: Sendable {
    private let group: EventLoopGroup
    private let channel: Channel

    /// Creates and binds a new OTel HTTP server.
    ///
    /// The server starts listening immediately upon successful initialization.
    ///
    /// - Parameters:
    ///   - host: The hostname or IP address to bind to.
    ///   - port: The TCP port to listen on.
    ///   - ingester: The ``SpanIngester`` that buffers and flushes incoming telemetry.
    ///   - store: The ``SpanStore`` used for persisting and querying spans, logs, and metrics.
    ///   - authToken: An optional bearer token for authenticating incoming requests. When `nil`, authentication is disabled.
    ///   - corsOrigin: The value for the `Access-Control-Allow-Origin` header. Defaults to `"*"`.
    public init(host: String, port: Int, ingester: SpanIngester, store: SpanStore, authToken: String?, corsOrigin: String = "*") async throws {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 256)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(OTelHTTPHandler(
                        ingester: ingester,
                        store: store,
                        authToken: authToken,
                        corsOrigin: corsOrigin
                    ))
                }
            }
            .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.maxMessagesPerRead, value: 16)

        self.channel = try await bootstrap.bind(host: host, port: port).get()
    }

    /// Blocks until the server channel is closed.
    ///
    /// Call this method to keep the server running. It returns only after ``shutdown()`` is called
    /// or the channel closes for another reason.
    public func run() async throws {
        try await channel.closeFuture.get()
    }

    /// Gracefully shuts down the server.
    ///
    /// Closes the listening channel and shuts down the NIO event loop group.
    public func shutdown() async throws {
        try? await channel.close()
        try await group.shutdownGracefully()
    }
}
