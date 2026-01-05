import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOFoundationCompat
import NIOHTTP1
import NIOSSL
import NIOWebSocket
import WebSocketKit

/// WebSocket-based transport for Trebuchet.
///
/// Provides bidirectional, real-time communication between distributed actor systems.
/// Supports both plain WebSocket (ws://) and secure WebSocket (wss://) connections.
public final class WebSocketTransport: TrebuchetTransport, @unchecked Sendable {
    private let eventLoopGroup: EventLoopGroup
    private let ownsEventLoopGroup: Bool
    private let tlsConfiguration: TLSConfiguration?

    private var serverChannel: Channel?
    private let connectionManager: ConnectionManager

    private let incomingContinuation: AsyncStream<TransportMessage>.Continuation
    public let incoming: AsyncStream<TransportMessage>

    /// Create a new WebSocket transport
    /// - Parameters:
    ///   - eventLoopGroup: Optional event loop group. If nil, creates a new one.
    ///   - tlsConfiguration: Optional TLS configuration for secure connections.
    public init(eventLoopGroup: EventLoopGroup? = nil, tlsConfiguration: TLSConfiguration? = nil) {
        if let eventLoopGroup {
            self.eventLoopGroup = eventLoopGroup
            self.ownsEventLoopGroup = false
        } else {
            self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
            self.ownsEventLoopGroup = true
        }

        self.tlsConfiguration = tlsConfiguration
        self.connectionManager = ConnectionManager(useTLS: tlsConfiguration != nil)

        var continuation: AsyncStream<TransportMessage>.Continuation!
        self.incoming = AsyncStream { continuation = $0 }
        self.incomingContinuation = continuation
    }

    deinit {
        if ownsEventLoopGroup {
            try? eventLoopGroup.syncShutdownGracefully()
        }
    }

    public func send(_ data: Data, to endpoint: Endpoint) async throws {
        let continuation = incomingContinuation
        let ws = try await connectionManager.getOrCreate(
            to: endpoint,
            using: eventLoopGroup,
            onMessage: { data in
                // Route incoming responses to the stream (no respond callback needed for client)
                let message = TransportMessage(data: data, source: endpoint, respond: { _ in })
                continuation.yield(message)
            }
        )

        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)

        try await ws.send(raw: buffer.readableBytesView, opcode: .binary)
    }

    public func listen(on endpoint: Endpoint) async throws {
        // Build NIO SSL context if TLS is configured
        let sslContext: NIOSSLContext? = try tlsConfiguration.map { tls in
            var config = NIOSSL.TLSConfiguration.makeServerConfiguration(
                certificateChain: tls.certificateChain.map { .certificate($0) },
                privateKey: .privateKey(tls.privateKey)
            )
            config.minimumTLSVersion = .tlsv12
            return try NIOSSLContext(configuration: config)
        }

        // Create a WebSocket server using NIO
        let serverBootstrap = ServerBootstrap(group: eventLoopGroup)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [weak self] channel in
                // Add TLS handler first if configured
                let tlsFuture: EventLoopFuture<Void>
                if let sslContext {
                    let sslHandler = NIOSSLServerHandler(context: sslContext)
                    tlsFuture = channel.pipeline.addHandler(sslHandler)
                } else {
                    tlsFuture = channel.eventLoop.makeSucceededFuture(())
                }

                return tlsFuture.flatMap {
                    let upgrader = NIOWebSocketServerUpgrader(
                        shouldUpgrade: { channel, head in
                            channel.eventLoop.makeSucceededFuture(HTTPHeaders())
                        },
                        upgradePipelineHandler: { [weak self] channel, req in
                            guard let self else {
                                return channel.eventLoop.makeSucceededFuture(())
                            }

                            let handler = WebSocketMessageHandler { [weak self] data, respond in
                                guard let self else { return }
                                let message = TransportMessage(data: data, source: nil, respond: respond)
                                self.incomingContinuation.yield(message)
                            }

                            return channel.pipeline.addHandler(handler)
                        }
                    )

                    let config: NIOHTTPServerUpgradeConfiguration = (
                        upgraders: [upgrader],
                        completionHandler: { _ in }
                    )

                    return channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: config)
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        do {
            let channel = try await serverBootstrap.bind(host: endpoint.host, port: Int(endpoint.port)).get()
            self.serverChannel = channel
        } catch {
            throw TrebuchetError.connectionFailed(host: endpoint.host, port: endpoint.port, underlying: error)
        }
    }

    public func shutdown() async {
        try? await serverChannel?.close()
        serverChannel = nil

        await connectionManager.closeAll()

        incomingContinuation.finish()
    }
}

// MARK: - Connection Manager

private actor ConnectionManager {
    private var connections: [Endpoint: WebSocket] = [:]
    private let useTLS: Bool

    init(useTLS: Bool = false) {
        self.useTLS = useTLS
    }

    func getOrCreate(
        to endpoint: Endpoint,
        using group: EventLoopGroup,
        onMessage: @escaping @Sendable (Data) -> Void
    ) async throws -> WebSocket {
        // Check for existing connection
        if let existing = connections[endpoint], !existing.isClosed {
            return existing
        }

        // Create new connection using a promise to capture the WebSocket
        let promise = group.next().makePromise(of: WebSocket.self)

        // Use wss:// for TLS, ws:// for plain
        let scheme = useTLS ? "wss" : "ws"
        let url = "\(scheme)://\(endpoint.host):\(endpoint.port)"

        // Configure TLS if needed
        var tlsConfig: WebSocketClient.Configuration = .init()
        if useTLS {
            // For client connections, trust the server certificate
            // In production, you'd want to configure proper certificate verification
            tlsConfig.tlsConfiguration = .makeClientConfiguration()
            tlsConfig.tlsConfiguration?.certificateVerification = .none // For self-signed certs in dev
        }

        WebSocket.connect(
            to: url,
            configuration: tlsConfig,
            on: group
        ) { ws in
            // Set up handler for incoming messages (responses from server)
            ws.onBinary { _, buffer in
                let data = Data(buffer: buffer)
                onMessage(data)
            }
            ws.onText { _, text in
                let data = Data(text.utf8)
                onMessage(data)
            }
            promise.succeed(ws)
        }.whenFailure { error in
            promise.fail(error)
        }

        let ws = try await promise.futureResult.get()
        connections[endpoint] = ws
        return ws
    }

    func closeAll() async {
        for ws in connections.values {
            try? await ws.close()
        }
        connections.removeAll()
    }
}

// MARK: - WebSocket Message Handler

private final class WebSocketMessageHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let onMessage: @Sendable (Data, @escaping @Sendable (Data) async throws -> Void) -> Void
    private weak var context: ChannelHandlerContext?

    init(onMessage: @escaping @Sendable (Data, @escaping @Sendable (Data) async throws -> Void) -> Void) {
        self.onMessage = onMessage
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)

        switch frame.opcode {
        case .binary, .text:
            var frameData = frame.unmaskedData
            let data = frameData.readData(length: frameData.readableBytes) ?? Data()

            // Capture what we need from context before the closure
            let channel = context.channel

            let respond: @Sendable (Data) async throws -> Void = { responseData in
                var buffer = channel.allocator.buffer(capacity: responseData.count)
                buffer.writeBytes(responseData)
                let responseFrame = WebSocketFrame(fin: true, opcode: .binary, data: buffer)
                channel.writeAndFlush(NIOAny(responseFrame), promise: nil)
            }

            onMessage(data, respond)

        case .ping:
            let pongData = frame.data
            let pong = WebSocketFrame(fin: true, opcode: .pong, data: pongData)
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)

        case .connectionClose:
            context.close(promise: nil)

        default:
            break
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
