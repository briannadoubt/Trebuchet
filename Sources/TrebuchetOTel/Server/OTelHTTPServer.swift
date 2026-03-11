import NIO
import NIOHTTP1
import NIOFoundationCompat
import Foundation
import Trebuchet

extension OTelHTTPServer: GracefullyShutdownable {}

public final class OTelHTTPServer: Sendable {
    private let group: EventLoopGroup
    private let channel: Channel

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

    public func run() async throws {
        try await channel.closeFuture.get()
    }

    public func shutdown() async throws {
        try? await channel.close()
        try await group.shutdownGracefully()
    }
}
