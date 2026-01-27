import Foundation
import Trebuche
import TrebucheCloud

// MARK: - WebSocket Event Models

/// Represents an API Gateway WebSocket event
public struct APIGatewayWebSocketEvent: Codable, Sendable {
    public let requestContext: RequestContext
    public let body: String?
    public let isBase64Encoded: Bool?

    public init(
        requestContext: RequestContext,
        body: String? = nil,
        isBase64Encoded: Bool? = nil
    ) {
        self.requestContext = requestContext
        self.body = body
        self.isBase64Encoded = isBase64Encoded
    }

    public struct RequestContext: Codable, Sendable {
        public let connectionId: String
        public let routeKey: String
        public let domainName: String?
        public let stage: String?
        public let requestTime: String?

        public init(
            connectionId: String,
            routeKey: String,
            domainName: String? = nil,
            stage: String? = nil,
            requestTime: String? = nil
        ) {
            self.connectionId = connectionId
            self.routeKey = routeKey
            self.domainName = domainName
            self.stage = stage
            self.requestTime = requestTime
        }
    }
}

/// API Gateway response
public struct APIGatewayWebSocketResponse: Codable, Sendable {
    public let statusCode: Int
    public let body: String?
    public let headers: [String: String]?

    public init(
        statusCode: Int,
        body: String? = nil,
        headers: [String: String]? = nil
    ) {
        self.statusCode = statusCode
        self.body = body
        self.headers = headers
    }
}

// MARK: - WebSocket Lambda Handler

/// Lambda handler for API Gateway WebSocket events.
///
/// This handler manages WebSocket lifecycle and message routing:
/// - **$connect**: Register new connections
/// - **$disconnect**: Clean up disconnected clients
/// - **$default**: Route messages to actors and handle streaming
///
/// ## Example Usage
///
/// ```swift
/// let storage = InMemoryConnectionStorage()
/// let sender = InMemoryConnectionSender()
/// let connectionManager = ConnectionManager(storage: storage, sender: sender)
/// let gateway = CloudGateway(/* configuration */)
///
/// let handler = WebSocketLambdaHandler(
///     gateway: gateway,
///     connectionManager: connectionManager
/// )
///
/// // In Lambda
/// let response = try await handler.handle(event, context: context)
/// ```
public actor WebSocketLambdaHandler {
    private let gateway: CloudGateway
    private let connectionManager: ConnectionManager
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    /// Buffer for outgoing stream data (for resumption support)
    private let streamBuffer = ServerStreamBuffer()

    public init(
        gateway: CloudGateway,
        connectionManager: ConnectionManager
    ) {
        self.gateway = gateway
        self.connectionManager = connectionManager

        self.decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        self.encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
    }

    // MARK: - Event Handling

    /// Handle a WebSocket event from API Gateway
    public func handle(
        _ event: APIGatewayWebSocketEvent
    ) async throws -> APIGatewayWebSocketResponse {
        switch event.requestContext.routeKey {
        case "$connect":
            return try await handleConnect(event: event)

        case "$disconnect":
            return try await handleDisconnect(event: event)

        case "$default":
            return try await handleMessage(event: event)

        default:
            return APIGatewayWebSocketResponse(
                statusCode: 404,
                body: "Route not found"
            )
        }
    }

    // MARK: - Connection Lifecycle

    private func handleConnect(
        event: APIGatewayWebSocketEvent
    ) async throws -> APIGatewayWebSocketResponse {
        let connectionID = event.requestContext.connectionId

        // Extract optional actorID from query parameters (if needed)
        // For now, just register the connection
        try await connectionManager.register(connectionID: connectionID)

        return APIGatewayWebSocketResponse(statusCode: 200)
    }

    private func handleDisconnect(
        event: APIGatewayWebSocketEvent
    ) async throws -> APIGatewayWebSocketResponse {
        let connectionID = event.requestContext.connectionId

        try await connectionManager.unregister(connectionID: connectionID)

        return APIGatewayWebSocketResponse(statusCode: 200)
    }

    // MARK: - Message Handling

    private func handleMessage(
        event: APIGatewayWebSocketEvent
    ) async throws -> APIGatewayWebSocketResponse {
        guard let body = event.body else {
            return APIGatewayWebSocketResponse(
                statusCode: 400,
                body: "Missing body"
            )
        }

        let connectionID = event.requestContext.connectionId
        let data = Data(body.utf8)

        // Decode envelope
        let envelope = try decoder.decode(TrebuchetEnvelope.self, from: data)

        // Handle different envelope types
        switch envelope {
        case .invocation(let invocation):
            return try await handleInvocation(invocation, connectionID: connectionID)

        case .streamResume(let resume):
            return try await handleStreamResume(resume, connectionID: connectionID)

        default:
            return APIGatewayWebSocketResponse(
                statusCode: 400,
                body: "Unexpected envelope type"
            )
        }
    }

    // MARK: - Invocation Handling

    private func handleInvocation(
        _ invocation: InvocationEnvelope,
        connectionID: String
    ) async throws -> APIGatewayWebSocketResponse {
        // Check if this is a streaming invocation (observe* methods)
        let isStreaming = invocation.targetIdentifier.hasPrefix("observe")

        if isStreaming {
            return try await handleStreamingInvocation(
                invocation,
                connectionID: connectionID
            )
        } else {
            return try await handleRPCInvocation(invocation, connectionID: connectionID)
        }
    }

    private func handleStreamingInvocation(
        _ invocation: InvocationEnvelope,
        connectionID: String
    ) async throws -> APIGatewayWebSocketResponse {
        let streamID = UUID()

        // Register subscription
        try await connectionManager.subscribe(
            connectionID: connectionID,
            streamID: streamID,
            actorID: invocation.actorID.id
        )

        // Send StreamStartEnvelope to client
        let startEnvelope = StreamStartEnvelope(
            streamID: streamID,
            callID: invocation.callID,
            actorID: invocation.actorID,
            targetIdentifier: invocation.targetIdentifier,
            filter: invocation.streamFilter
        )

        let startData = try encoder.encode(TrebuchetEnvelope.streamStart(startEnvelope))

        try await connectionManager.send(data: startData, to: connectionID)

        // The actual streaming will happen via DynamoDB Streams (Phase 12)
        // or via the actor's streaming mechanism

        return APIGatewayWebSocketResponse(statusCode: 200)
    }

    private func handleRPCInvocation(
        _ invocation: InvocationEnvelope,
        connectionID: String
    ) async throws -> APIGatewayWebSocketResponse {
        // TODO: Execute RPC through CloudGateway when handleInvocation is implemented
        // For now, return a simple acknowledgment

        let response = ResponseEnvelope(
            callID: invocation.callID,
            result: Data(),
            errorMessage: nil
        )

        // Encode response
        let responseData = try encoder.encode(TrebuchetEnvelope.response(response))
        let responseBody = String(data: responseData, encoding: .utf8)

        // For WebSocket, we send the response through the connection
        try await connectionManager.send(data: responseData, to: connectionID)

        return APIGatewayWebSocketResponse(
            statusCode: 200,
            body: responseBody
        )
    }

    // MARK: - Stream Resumption

    private func handleStreamResume(
        _ resume: StreamResumeEnvelope,
        connectionID: String
    ) async throws -> APIGatewayWebSocketResponse {
        // Check if we have buffered data for this stream
        if let bufferedData = await streamBuffer.getBufferedData(
            streamID: resume.streamID,
            afterSequence: resume.lastSequence
        ), !bufferedData.isEmpty {
            // Replay buffered data
            for (sequence, data) in bufferedData {
                let dataEnvelope = StreamDataEnvelope(
                    streamID: resume.streamID,
                    sequenceNumber: sequence,
                    data: data,
                    timestamp: Date()
                )
                let envelopeData = try encoder.encode(TrebuchetEnvelope.streamData(dataEnvelope))
                try await connectionManager.send(data: envelopeData, to: connectionID)
            }

            // Update connection's last sequence to the last replayed sequence
            if let lastSequence = bufferedData.last?.sequence {
                try await connectionManager.updateSequence(
                    connectionID: connectionID,
                    lastSequence: lastSequence
                )
            }
        } else {
            // Buffer expired or stream not found - restart stream
            let startEnvelope = StreamStartEnvelope(
                streamID: resume.streamID,
                callID: UUID(),
                actorID: resume.actorID,
                targetIdentifier: resume.targetIdentifier,
                filter: nil
            )

            let startData = try encoder.encode(TrebuchetEnvelope.streamStart(startEnvelope))
            try await connectionManager.send(data: startData, to: connectionID)

            // Update connection's last sequence
            try await connectionManager.updateSequence(
                connectionID: connectionID,
                lastSequence: resume.lastSequence
            )
        }

        return APIGatewayWebSocketResponse(statusCode: 200)
    }
}

// MARK: - Convenience Extensions

extension WebSocketLambdaHandler {
    /// Broadcast a stream data update to all subscribers of an actor
    public func broadcastStreamData(
        streamID: UUID,
        sequenceNumber: UInt64,
        data: Data,
        to actorID: String
    ) async throws {
        let envelope = StreamDataEnvelope(
            streamID: streamID,
            sequenceNumber: sequenceNumber,
            data: data,
            timestamp: Date()
        )

        // Buffer the data for potential resumption
        await streamBuffer.buffer(streamID: streamID, sequence: sequenceNumber, data: data)

        try await connectionManager.broadcastEnvelope(
            .streamData(envelope),
            to: actorID
        )
    }

    /// Broadcast a stream error to all subscribers
    public func broadcastStreamError(
        streamID: UUID,
        error: String,
        to actorID: String
    ) async throws {
        let envelope = StreamErrorEnvelope(
            streamID: streamID,
            errorMessage: error
        )

        try await connectionManager.broadcastEnvelope(
            .streamError(envelope),
            to: actorID
        )
    }

    /// Broadcast stream end to all subscribers
    public func broadcastStreamEnd(
        streamID: UUID,
        to actorID: String
    ) async throws {
        let envelope = StreamEndEnvelope(
            streamID: streamID,
            reason: .completed
        )

        try await connectionManager.broadcastEnvelope(
            .streamEnd(envelope),
            to: actorID
        )

        // Clean up buffer for completed stream
        await streamBuffer.removeBuffer(streamID: streamID)
    }
}

// MARK: - Server Stream Buffer

/// Buffer for outgoing stream data to support resumption
private actor ServerStreamBuffer {
    private struct BufferedStream {
        var recentData: [(sequence: UInt64, data: Data)] = []
        var lastActivity: Date = Date()
    }

    private var buffers: [UUID: BufferedStream] = [:]
    private let maxBufferSize: Int
    private let ttl: TimeInterval

    init(maxBufferSize: Int = 100, ttl: TimeInterval = 300) {
        self.maxBufferSize = maxBufferSize
        self.ttl = ttl
    }

    /// Buffer outgoing stream data
    func buffer(streamID: UUID, sequence: UInt64, data: Data) {
        var stream = buffers[streamID] ?? BufferedStream()
        stream.recentData.append((sequence, data))
        stream.lastActivity = Date()

        // Keep only recent items
        if stream.recentData.count > maxBufferSize {
            stream.recentData.removeFirst()
        }

        buffers[streamID] = stream
    }

    /// Get buffered data for resumption
    func getBufferedData(streamID: UUID, afterSequence: UInt64) -> [(sequence: UInt64, data: Data)]? {
        guard let stream = buffers[streamID] else {
            return nil
        }

        // Check if buffer is still valid (not expired)
        if Date().timeIntervalSince(stream.lastActivity) > ttl {
            buffers.removeValue(forKey: streamID)
            return nil
        }

        // Return data after the given sequence
        return stream.recentData.filter { $0.sequence > afterSequence }
    }

    /// Remove buffer for a completed stream
    func removeBuffer(streamID: UUID) {
        buffers.removeValue(forKey: streamID)
    }

    /// Clean up all buffers
    func removeAllBuffers() {
        buffers.removeAll()
    }
}
