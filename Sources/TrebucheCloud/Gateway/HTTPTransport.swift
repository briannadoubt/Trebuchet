import Foundation
import NIO
import NIOHTTP1
import NIOFoundationCompat
import NIOSSL
import Trebuchet

// MARK: - HTTP Transport

/// HTTP-based transport for cloud environments.
///
/// This transport uses HTTP POST requests to invoke distributed actors,
/// making it compatible with API Gateway, Cloud Functions, and other
/// HTTP-based serverless triggers.
///
/// TLS is automatically negotiated for connections to port 443 or when
/// explicitly enabled.
public final class HTTPTransport: TrebuchetTransport, @unchecked Sendable {
    private let eventLoopGroup: EventLoopGroup
    private let ownsEventLoopGroup: Bool
    private var serverChannel: Channel?
    private let incomingContinuation: AsyncStream<TransportMessage>.Continuation
    public let incoming: AsyncStream<TransportMessage>

    private let connectionManager: ConnectionManager
    private let tlsEnabled: Bool?  // nil = auto-detect based on port

    /// Create an HTTP transport
    /// - Parameters:
    ///   - eventLoopGroup: Optional event loop group (creates one if not provided)
    ///   - tlsEnabled: Whether to use TLS. If nil, auto-detects based on port (443 = TLS)
    public init(eventLoopGroup: EventLoopGroup? = nil, tlsEnabled: Bool? = nil) {
        if let group = eventLoopGroup {
            self.eventLoopGroup = group
            self.ownsEventLoopGroup = false
        } else {
            self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
            self.ownsEventLoopGroup = true
        }

        self.tlsEnabled = tlsEnabled
        self.connectionManager = ConnectionManager(defaultTLSEnabled: tlsEnabled)

        var continuation: AsyncStream<TransportMessage>.Continuation!
        self.incoming = AsyncStream { continuation = $0 }
        self.incomingContinuation = continuation
    }

    /// Create an HTTPS transport (TLS always enabled)
    public static func https(eventLoopGroup: EventLoopGroup? = nil) -> HTTPTransport {
        HTTPTransport(eventLoopGroup: eventLoopGroup, tlsEnabled: true)
    }

    // MARK: - Client Operations

    public func connect(to endpoint: Endpoint) async throws {
        // HTTP is stateless - no persistent connection needed
        // But we can validate the endpoint is reachable
        _ = try await connectionManager.getOrCreateConnection(
            to: endpoint,
            eventLoopGroup: eventLoopGroup
        )
    }

    public func send(_ data: Data, to endpoint: Endpoint) async throws {
        let channel = try await connectionManager.getOrCreateConnection(
            to: endpoint,
            eventLoopGroup: eventLoopGroup
        )

        let responsePromise = channel.eventLoop.makePromise(of: Data.self)

        // Create HTTP request
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Content-Length", value: "\(data.count)")
        headers.add(name: "Host", value: endpoint.host)

        let requestHead = HTTPRequestHead(
            version: .http1_1,
            method: .POST,
            uri: "/invoke",
            headers: headers
        )

        // Set up response handler
        let handler = HTTPClientResponseHandler(promise: responsePromise)
        try await channel.pipeline.addHandler(handler).get()

        // Send request
        channel.write(NIOAny(HTTPClientRequestPart.head(requestHead)), promise: nil)

        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        channel.write(NIOAny(HTTPClientRequestPart.body(.byteBuffer(buffer))), promise: nil)

        try await channel.writeAndFlush(NIOAny(HTTPClientRequestPart.end(nil))).get()

        // Wait for response
        let responseData = try await responsePromise.futureResult.get()

        // Yield response to incoming stream
        incomingContinuation.yield(TransportMessage(
            data: responseData,
            source: endpoint,
            respond: { _ in }  // Client doesn't respond to responses
        ))
    }

    // MARK: - Server Operations

    public func listen(on endpoint: Endpoint) async throws {
        let bootstrap = ServerBootstrap(group: eventLoopGroup)
            .serverChannelOption(.backlog, value: 256)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(
                        HTTPServerHandler(continuation: self.incomingContinuation)
                    )
                }
            }
            .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.maxMessagesPerRead, value: 16)

        serverChannel = try await bootstrap.bind(host: endpoint.host, port: Int(endpoint.port)).get()
    }

    public func shutdown() async {
        try? await serverChannel?.close()
        serverChannel = nil

        await connectionManager.closeAll()

        if ownsEventLoopGroup {
            try? await eventLoopGroup.shutdownGracefully()
        }

        incomingContinuation.finish()
    }
}

// MARK: - Connection Manager

private actor ConnectionManager {
    private var connections: [String: Channel] = [:]
    private let defaultTLSEnabled: Bool?

    init(defaultTLSEnabled: Bool? = nil) {
        self.defaultTLSEnabled = defaultTLSEnabled
    }

    func getOrCreateConnection(
        to endpoint: Endpoint,
        eventLoopGroup: EventLoopGroup
    ) async throws -> Channel {
        // Determine if TLS should be used
        let useTLS = defaultTLSEnabled ?? (endpoint.port == 443)

        // Include TLS state in the cache key to avoid mixing TLS and non-TLS connections
        let key = "\(endpoint.host):\(endpoint.port):\(useTLS ? "tls" : "plain")"

        if let existing = connections[key], existing.isActive {
            return existing
        }

        let channel: Channel
        if useTLS {
            channel = try await createTLSConnection(to: endpoint, eventLoopGroup: eventLoopGroup)
        } else {
            channel = try await createPlainConnection(to: endpoint, eventLoopGroup: eventLoopGroup)
        }

        connections[key] = channel
        return channel
    }

    private func createPlainConnection(
        to endpoint: Endpoint,
        eventLoopGroup: EventLoopGroup
    ) async throws -> Channel {
        let bootstrap = ClientBootstrap(group: eventLoopGroup)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHTTPClientHandlers()
            }

        return try await bootstrap.connect(
            host: endpoint.host,
            port: Int(endpoint.port)
        ).get()
    }

    private func createTLSConnection(
        to endpoint: Endpoint,
        eventLoopGroup: EventLoopGroup
    ) async throws -> Channel {
        // Create TLS configuration for client connections
        var tlsConfig = NIOSSL.TLSConfiguration.makeClientConfiguration()
        tlsConfig.certificateVerification = .fullVerification

        let sslContext = try NIOSSLContext(configuration: tlsConfig)
        let hostname = endpoint.host

        let bootstrap = ClientBootstrap(group: eventLoopGroup)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                do {
                    // Create the TLS handler with SNI (Server Name Indication)
                    let sslHandler = try NIOSSLClientHandler(
                        context: sslContext,
                        serverHostname: hostname
                    )
                    // Add TLS handler first, then HTTP handlers on top
                    return channel.pipeline.addHandler(sslHandler).flatMap {
                        channel.pipeline.addHTTPClientHandlers()
                    }
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

        return try await bootstrap.connect(
            host: endpoint.host,
            port: Int(endpoint.port)
        ).get()
    }

    func closeAll() async {
        for (_, channel) in connections {
            try? await channel.close()
        }
        connections.removeAll()
    }
}

// MARK: - HTTP Server Handler

private final class HTTPServerHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let continuation: AsyncStream<TransportMessage>.Continuation
    private var requestBody = Data()
    private var currentRequest: HTTPRequestHead?

    init(continuation: AsyncStream<TransportMessage>.Continuation) {
        self.continuation = continuation
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)

        switch part {
        case .head(let request):
            currentRequest = request
            requestBody = Data()

        case .body(let buffer):
            if let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) {
                requestBody.append(contentsOf: bytes)
            }

        case .end:
            guard let request = currentRequest else { return }

            // Only handle POST /invoke
            if request.method == .POST && request.uri.hasPrefix("/invoke") {
                let channel = context.channel
                let body = requestBody

                let message = TransportMessage(
                    data: body,
                    source: nil,
                    respond: { responseData in
                        // Execute response on the channel's event loop
                        channel.eventLoop.execute {
                            var headers = HTTPHeaders()
                            headers.add(name: "Content-Type", value: "application/json")
                            headers.add(name: "Content-Length", value: "\(responseData.count)")

                            let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
                            channel.write(HTTPServerResponsePart.head(responseHead), promise: nil)

                            var buffer = channel.allocator.buffer(capacity: responseData.count)
                            buffer.writeBytes(responseData)
                            channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)

                            channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)
                        }
                    }
                )

                continuation.yield(message)
            } else if request.uri == "/health" {
                // Health check endpoint
                sendResponse(context: context, data: Data("OK".utf8), status: .ok)
            } else {
                sendResponse(context: context, data: Data("Not Found".utf8), status: .notFound)
            }

            currentRequest = nil
            requestBody = Data()
        }
    }

    private func sendResponse(context: ChannelHandlerContext, data: Data, status: HTTPResponseStatus) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Content-Length", value: "\(data.count)")

        let responseHead = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)

        var buffer = context.channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)

        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        sendResponse(
            context: context,
            data: Data("{\"error\":\"\(error)\"}".utf8),
            status: .internalServerError
        )
        context.close(promise: nil)
    }
}

// MARK: - HTTP Client Response Handler

private final class HTTPClientResponseHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart

    private let promise: EventLoopPromise<Data>
    private var responseBody = Data()

    init(promise: EventLoopPromise<Data>) {
        self.promise = promise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)

        switch part {
        case .head:
            responseBody = Data()

        case .body(let buffer):
            if let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) {
                responseBody.append(contentsOf: bytes)
            }

        case .end:
            promise.succeed(responseBody)
            context.pipeline.removeHandler(self, promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        promise.fail(error)
        context.pipeline.removeHandler(self, promise: nil)
    }
}

// MARK: - Transport Configuration Extension

extension TransportConfiguration {
    /// HTTP transport configuration
    public static func http(host: String = "0.0.0.0", port: UInt16) -> TransportConfiguration {
        // For now, reuse the tcp case structure
        // In a full implementation, we'd add a dedicated case
        .tcp(host: host, port: port)
    }
}
