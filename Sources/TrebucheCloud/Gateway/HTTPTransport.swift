import Foundation
import NIO
import NIOHTTP1
import NIOFoundationCompat
import Trebuche

// MARK: - HTTP Transport

/// HTTP-based transport for cloud environments.
///
/// This transport uses HTTP POST requests to invoke distributed actors,
/// making it compatible with API Gateway, Cloud Functions, and other
/// HTTP-based serverless triggers.
public final class HTTPTransport: TrebuchetTransport, @unchecked Sendable {
    private let eventLoopGroup: EventLoopGroup
    private let ownsEventLoopGroup: Bool
    private var serverChannel: Channel?
    private let incomingContinuation: AsyncStream<TransportMessage>.Continuation
    public let incoming: AsyncStream<TransportMessage>

    private let connectionManager = ConnectionManager()

    /// Create an HTTP transport
    /// - Parameter eventLoopGroup: Optional event loop group (creates one if not provided)
    public init(eventLoopGroup: EventLoopGroup? = nil) {
        if let group = eventLoopGroup {
            self.eventLoopGroup = group
            self.ownsEventLoopGroup = false
        } else {
            self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
            self.ownsEventLoopGroup = true
        }

        var continuation: AsyncStream<TransportMessage>.Continuation!
        self.incoming = AsyncStream { continuation = $0 }
        self.incomingContinuation = continuation
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

    func getOrCreateConnection(
        to endpoint: Endpoint,
        eventLoopGroup: EventLoopGroup
    ) async throws -> Channel {
        let key = "\(endpoint.host):\(endpoint.port)"

        if let existing = connections[key], existing.isActive {
            return existing
        }

        let bootstrap = ClientBootstrap(group: eventLoopGroup)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHTTPClientHandlers()
            }

        let channel = try await bootstrap.connect(
            host: endpoint.host,
            port: Int(endpoint.port)
        ).get()

        connections[key] = channel
        return channel
    }

    func closeAll() async {
        for (_, channel) in connections {
            try? await channel.close()
        }
        connections.removeAll()
    }
}

// MARK: - HTTP Server Handler

private final class HTTPServerHandler: ChannelInboundHandler, RemovableChannelHandler {
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
                let capturedContext = context
                let body = requestBody

                let message = TransportMessage(
                    data: body,
                    source: nil,
                    respond: { [weak self] responseData in
                        self?.sendResponse(context: capturedContext, data: responseData, status: .ok)
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

private final class HTTPClientResponseHandler: ChannelInboundHandler, RemovableChannelHandler {
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
