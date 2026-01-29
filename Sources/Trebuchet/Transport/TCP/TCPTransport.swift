import Foundation
@preconcurrency import NIO
import NIOConcurrencyHelpers
import NIOExtras
import NIOFoundationCompat

/// TCP-based transport for Trebuchet.
///
/// Provides efficient, low-overhead communication between distributed actor systems
/// using raw TCP sockets with length-prefixed message framing.
///
/// This transport is ideal for server-to-server communication where you don't need
/// browser compatibility and want minimal protocol overhead.
///
/// ## Message Framing
///
/// Messages are framed with a 4-byte big-endian length prefix:
/// ```
/// [4 bytes: message length][message payload]
/// ```
///
/// ## Security
///
/// **IMPORTANT:** This transport does NOT support TLS encryption. For secure communication:
/// - Use WebSocket transport with TLS for public networks
/// - Deploy within a trusted network (e.g., VPC, private network, localhost)
/// - Use a TLS termination proxy (e.g., nginx, Envoy) if TLS is required
///
/// This transport is designed for internal service-to-service communication within
/// secure network boundaries.
///
/// ## Usage
///
/// ```swift
/// // Server
/// let server = TrebuchetServer(transport: .tcp(host: "0.0.0.0", port: 9001))
/// try await server.run()
///
/// // Client
/// let client = TrebuchetClient(transport: .tcp(host: "server.local", port: 9001))
/// try await client.connect()
/// ```
public final class TCPTransport: TrebuchetTransport, @unchecked Sendable {
    private let eventLoopGroup: EventLoopGroup
    private let ownsEventLoopGroup: Bool

    private var serverChannel: Channel?
    private let connectionManager: TCPConnectionManager

    private let incomingContinuation: AsyncStream<TransportMessage>.Continuation
    public let incoming: AsyncStream<TransportMessage>

    /// Create a new TCP transport
    /// - Parameter eventLoopGroup: Optional event loop group. If nil, creates a new one.
    public init(eventLoopGroup: EventLoopGroup? = nil) {
        if let eventLoopGroup {
            self.eventLoopGroup = eventLoopGroup
            self.ownsEventLoopGroup = false
        } else {
            // Use 2-4 threads for typical server-to-server workloads
            // This is more efficient than using all cores for I/O bound operations
            self.eventLoopGroup = MultiThreadedEventLoopGroup(
                numberOfThreads: min(4, max(2, System.coreCount))
            )
            self.ownsEventLoopGroup = true
        }

        self.connectionManager = TCPConnectionManager()

        var continuation: AsyncStream<TransportMessage>.Continuation!
        self.incoming = AsyncStream { continuation = $0 }
        self.incomingContinuation = continuation
    }

    deinit {
        if ownsEventLoopGroup {
            try? eventLoopGroup.syncShutdownGracefully()
        }
    }

    public func connect(to endpoint: Endpoint) async throws {
        let continuation = incomingContinuation
        do {
            _ = try await connectionManager.getOrCreate(
                to: endpoint,
                using: eventLoopGroup,
                onMessage: { data in
                    let message = TransportMessage(data: data, source: endpoint, respond: { _ in })
                    continuation.yield(message)
                }
            )
        } catch {
            throw TrebuchetError.connectionFailed(host: endpoint.host, port: endpoint.port, underlying: error)
        }
    }

    public func send(_ data: Data, to endpoint: Endpoint) async throws {
        let continuation = incomingContinuation
        let channel = try await connectionManager.getOrCreate(
            to: endpoint,
            using: eventLoopGroup,
            onMessage: { data in
                // Route incoming responses to the stream
                let message = TransportMessage(data: data, source: endpoint, respond: { _ in })
                continuation.yield(message)
            }
        )

        // Write length-prefixed message with timeout to prevent hanging
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await channel.writeAndFlush(data).get()
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(30))
                    throw TrebuchetError.remoteInvocationFailed("Write timeout after 30 seconds")
                }
                try await group.next()
                group.cancelAll()
            }
        } catch {
            throw TrebuchetError.connectionFailed(host: endpoint.host, port: endpoint.port, underlying: error)
        }
    }

    public func listen(on endpoint: Endpoint) async throws {
        let continuation = self.incomingContinuation

        var bootstrap = ServerBootstrap(group: eventLoopGroup)
        bootstrap = bootstrap.serverChannelOption(ChannelOptions.backlog, value: 256)
        bootstrap = bootstrap.childChannelInitializer { (channel: Channel) -> EventLoopFuture<Void> in
            // Add framing handlers: length prefix codec
            channel.pipeline.addHandlers([
                ByteToMessageHandler(LengthFieldBasedFrameDecoder(
                    lengthFieldLength: LengthFieldBasedFrameDecoder.ByteLength.four
                )),
                LengthFieldPrepender(
                    lengthFieldLength: LengthFieldPrepender.ByteLength.four
                ),
                TCPMessageHandler { data, respond in
                    let message = TransportMessage(data: data, source: nil, respond: respond)
                    continuation.yield(message)
                }
            ])
        }

        do {
            let channel = try await bootstrap.bind(host: endpoint.host, port: Int(endpoint.port)).get()
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

// MARK: - TCP Connection Manager

private actor TCPConnectionManager {
    private struct ConnectionInfo {
        let channel: Channel
        var lastUsed: Date
    }

    private var connections: [Endpoint: ConnectionInfo] = [:]
    private let maxIdleTime: TimeInterval = 300 // 5 minutes

    func getOrCreate(
        to endpoint: Endpoint,
        using group: EventLoopGroup,
        onMessage: @escaping @Sendable (Data) -> Void
    ) async throws -> Channel {
        // Check for existing connection and validate it's active
        if let existing = connections[endpoint] {
            if existing.channel.isActive {
                // Update last used time
                connections[endpoint]?.lastUsed = Date()
                return existing.channel
            } else {
                // Clean up stale connection
                try? await existing.channel.close()
                connections.removeValue(forKey: endpoint)
            }
        }

        // Clean up idle connections periodically
        await cleanupIdleConnections()

        // Create new connection
        var bootstrap = ClientBootstrap(group: group)
        bootstrap = bootstrap.channelInitializer { (channel: Channel) -> EventLoopFuture<Void> in
            // Add framing handlers
            channel.pipeline.addHandlers([
                ByteToMessageHandler(LengthFieldBasedFrameDecoder(
                    lengthFieldLength: LengthFieldBasedFrameDecoder.ByteLength.four
                )),
                LengthFieldPrepender(
                    lengthFieldLength: LengthFieldPrepender.ByteLength.four
                ),
                TCPMessageHandler { data, _ in
                    // Client side: just deliver messages, no respond callback needed
                    onMessage(data)
                }
            ])
        }

        let channel = try await bootstrap.connect(host: endpoint.host, port: Int(endpoint.port)).get()
        connections[endpoint] = ConnectionInfo(channel: channel, lastUsed: Date())
        return channel
    }

    private func cleanupIdleConnections() async {
        let now = Date()
        var toRemove: [Endpoint] = []

        for (endpoint, info) in connections {
            if now.timeIntervalSince(info.lastUsed) > maxIdleTime {
                try? await info.channel.close()
                toRemove.append(endpoint)
            }
        }

        for endpoint in toRemove {
            connections.removeValue(forKey: endpoint)
        }
    }

    func closeAll() async {
        for info in connections.values {
            try? await info.channel.close()
        }
        connections.removeAll()
    }
}

// MARK: - TCP Message Handler

private final class TCPMessageHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let onMessage: @Sendable (Data, @escaping @Sendable (Data) async throws -> Void) -> Void
    private weak var context: ChannelHandlerContext?

    init(onMessage: @escaping @Sendable (Data, @escaping @Sendable (Data) async throws -> Void) -> Void) {
        self.onMessage = onMessage
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let data = buffer.readData(length: buffer.readableBytes) else {
            return
        }

        // Capture what we need from context before the closure
        let channel = context.channel

        let respond: @Sendable (Data) async throws -> Void = { responseData in
            try await channel.writeAndFlush(responseData).get()
        }

        onMessage(data, respond)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

// MARK: - Channel Extensions

extension Channel {
    /// Write and flush data as a length-prefixed message
    fileprivate func writeAndFlush(_ data: Data) -> EventLoopFuture<Void> {
        var buffer = allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        return writeAndFlush(buffer)
    }
}
