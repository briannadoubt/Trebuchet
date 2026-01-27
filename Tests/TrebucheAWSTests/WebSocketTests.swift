import Testing
import Foundation
@testable import Trebuchet
@testable import TrebuchetCloud
@testable import TrebuchetAWS

@Suite("WebSocket Tests")
struct WebSocketTests {

    // MARK: - Connection Manager Tests

    @Test("ConnectionManager registers connections")
    func testConnectionRegistration() async throws {
        let storage = InMemoryConnectionStorage()
        let sender = InMemoryConnectionSender()
        let manager = ConnectionManager(storage: storage, sender: sender)

        // Register a connection
        try await manager.register(connectionID: "conn-123", actorID: "actor-1")

        // Verify connection exists
        let connections = try await manager.getConnections(for: "actor-1")
        #expect(connections.count == 1)
        #expect(connections[0].connectionID == "conn-123")
    }

    @Test("ConnectionManager handles subscriptions")
    func testConnectionSubscription() async throws {
        let storage = InMemoryConnectionStorage()
        let sender = InMemoryConnectionSender()
        let manager = ConnectionManager(storage: storage, sender: sender)

        let streamID = UUID()

        // Register and subscribe
        try await manager.register(connectionID: "conn-123")
        try await manager.subscribe(
            connectionID: "conn-123",
            streamID: streamID,
            actorID: "actor-1"
        )

        // Verify subscription
        let connections = try await manager.getConnections(for: "actor-1")
        #expect(connections.count == 1)
        #expect(connections[0].streamID == streamID)
    }

    @Test("ConnectionManager unregisters connections")
    func testConnectionUnregistration() async throws {
        let storage = InMemoryConnectionStorage()
        let sender = InMemoryConnectionSender()
        let manager = ConnectionManager(storage: storage, sender: sender)

        // Register and unregister
        try await manager.register(connectionID: "conn-123", actorID: "actor-1")
        try await manager.unregister(connectionID: "conn-123")

        // Verify connection removed
        let connections = try await manager.getConnections(for: "actor-1")
        #expect(connections.isEmpty)
    }

    @Test("ConnectionManager sends data to specific connection")
    func testSendToConnection() async throws {
        let storage = InMemoryConnectionStorage()
        let sender = InMemoryConnectionSender()
        let manager = ConnectionManager(storage: storage, sender: sender)

        // Register connection and mark as alive
        try await manager.register(connectionID: "conn-123")
        await sender.markAlive("conn-123")

        // Send data
        let testData = Data("Hello".utf8)
        try await manager.send(data: testData, to: "conn-123")

        // Verify data was sent
        let sentMessages = await sender.getSentMessages(for: "conn-123")
        #expect(sentMessages.count == 1)
        #expect(sentMessages[0] == testData)
    }

    @Test("ConnectionManager broadcasts to multiple connections")
    func testBroadcast() async throws {
        let storage = InMemoryConnectionStorage()
        let sender = InMemoryConnectionSender()
        let manager = ConnectionManager(storage: storage, sender: sender)

        // Register multiple connections for same actor
        try await manager.register(connectionID: "conn-1", actorID: "actor-1")
        try await manager.register(connectionID: "conn-2", actorID: "actor-1")
        try await manager.register(connectionID: "conn-3", actorID: "actor-1")

        await sender.markAlive("conn-1")
        await sender.markAlive("conn-2")
        await sender.markAlive("conn-3")

        // Broadcast data
        let testData = Data("Broadcast".utf8)
        try await manager.broadcast(data: testData, to: "actor-1")

        // Verify all connections received data
        let sent1 = await sender.getSentMessages(for: "conn-1")
        let sent2 = await sender.getSentMessages(for: "conn-2")
        let sent3 = await sender.getSentMessages(for: "conn-3")

        #expect(sent1.count == 1)
        #expect(sent2.count == 1)
        #expect(sent3.count == 1)
    }

    @Test("ConnectionManager excludes connections from broadcast")
    func testBroadcastWithExclusion() async throws {
        let storage = InMemoryConnectionStorage()
        let sender = InMemoryConnectionSender()
        let manager = ConnectionManager(storage: storage, sender: sender)

        // Register connections
        try await manager.register(connectionID: "conn-1", actorID: "actor-1")
        try await manager.register(connectionID: "conn-2", actorID: "actor-1")

        await sender.markAlive("conn-1")
        await sender.markAlive("conn-2")

        // Broadcast excluding conn-1
        let testData = Data("Broadcast".utf8)
        try await manager.broadcast(data: testData, to: "actor-1", excluding: "conn-1")

        // Verify only conn-2 received data
        let sent1 = await sender.getSentMessages(for: "conn-1")
        let sent2 = await sender.getSentMessages(for: "conn-2")

        #expect(sent1.isEmpty)
        #expect(sent2.count == 1)
    }

    @Test("ConnectionManager updates sequence numbers")
    func testSequenceUpdate() async throws {
        let storage = InMemoryConnectionStorage()
        let sender = InMemoryConnectionSender()
        let manager = ConnectionManager(storage: storage, sender: sender)

        let streamID = UUID()

        // Register and subscribe
        try await manager.register(connectionID: "conn-123")
        try await manager.subscribe(
            connectionID: "conn-123",
            streamID: streamID,
            actorID: "actor-1"
        )

        // Update sequence
        try await manager.updateSequence(connectionID: "conn-123", lastSequence: 42)

        // Verify sequence updated
        let connections = try await manager.getConnections(for: "actor-1")
        #expect(connections[0].lastSequence == 42)
    }

    // MARK: - WebSocket Lambda Handler Tests

    @Test("WebSocketLambdaHandler handles $connect events")
    func testHandleConnect() async throws {
        let storage = InMemoryConnectionStorage()
        let sender = InMemoryConnectionSender()
        let manager = ConnectionManager(storage: storage, sender: sender)

        let stateStore = InMemoryStateStore()
        let gateway = CloudGateway(
            configuration: .init(stateStore: stateStore)
        )

        let handler = WebSocketLambdaHandler(
            gateway: gateway,
            connectionManager: manager
        )

        // Create connect event
        let event = APIGatewayWebSocketEvent(
            requestContext: .init(
                connectionId: "conn-123",
                routeKey: "$connect"
            )
        )

        // Handle event
        let response = try await handler.handle(event)

        // Verify response
        #expect(response.statusCode == 200)

        // Verify connection registered
        // Note: Without actorID in connect event, connection won't be in actor index yet
    }

    @Test("WebSocketLambdaHandler handles $disconnect events")
    func testHandleDisconnect() async throws {
        let storage = InMemoryConnectionStorage()
        let sender = InMemoryConnectionSender()
        let manager = ConnectionManager(storage: storage, sender: sender)

        let stateStore = InMemoryStateStore()
        let gateway = CloudGateway(
            configuration: .init(stateStore: stateStore)
        )

        let handler = WebSocketLambdaHandler(
            gateway: gateway,
            connectionManager: manager
        )

        // Register a connection first
        try await manager.register(connectionID: "conn-123", actorID: "actor-1")

        // Create disconnect event
        let event = APIGatewayWebSocketEvent(
            requestContext: .init(
                connectionId: "conn-123",
                routeKey: "$disconnect"
            )
        )

        // Handle event
        let response = try await handler.handle(event)

        // Verify response
        #expect(response.statusCode == 200)

        // Verify connection removed
        let connections = try await manager.getConnections(for: "actor-1")
        #expect(connections.isEmpty)
    }

    @Test("WebSocketLambdaHandler handles streaming invocations")
    func testHandleStreamingInvocation() async throws {
        let storage = InMemoryConnectionStorage()
        let sender = InMemoryConnectionSender()
        let manager = ConnectionManager(storage: storage, sender: sender)

        // Register connection first
        try await manager.register(connectionID: "conn-123")
        await sender.markAlive("conn-123")

        let stateStore = InMemoryStateStore()
        let gateway = CloudGateway(
            configuration: .init(stateStore: stateStore)
        )

        let handler = WebSocketLambdaHandler(
            gateway: gateway,
            connectionManager: manager
        )

        // Create streaming invocation
        let actorID = TrebuchetActorID(id: "test-actor")
        let invocation = InvocationEnvelope(
            callID: UUID(),
            actorID: actorID,
            targetIdentifier: "observeState",
            genericSubstitutions: [],
            arguments: []
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let envelopeData = try encoder.encode(TrebuchetEnvelope.invocation(invocation))
        let body = String(data: envelopeData, encoding: .utf8)!

        // Create message event
        let event = APIGatewayWebSocketEvent(
            requestContext: .init(
                connectionId: "conn-123",
                routeKey: "$default"
            ),
            body: body
        )

        // Handle event
        let response = try await handler.handle(event)

        // Verify response
        #expect(response.statusCode == 200)

        // Verify connection subscribed
        let connections = try await manager.getConnections(for: actorID.id)
        #expect(connections.count == 1)
        #expect(connections[0].connectionID == "conn-123")

        // Verify StreamStart sent
        let sentMessages = await sender.getSentMessages(for: "conn-123")
        #expect(sentMessages.count == 1)

        // Decode and verify it's a StreamStart
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(TrebuchetEnvelope.self, from: sentMessages[0])

        if case .streamStart(let start) = envelope {
            #expect(start.actorID == actorID)
            #expect(start.targetIdentifier == "observeState")
        } else {
            #expect(Bool(false), "Expected StreamStart envelope")
        }
    }

    @Test("WebSocketLambdaHandler handles stream resumption")
    func testHandleStreamResume() async throws {
        let storage = InMemoryConnectionStorage()
        let sender = InMemoryConnectionSender()
        let manager = ConnectionManager(storage: storage, sender: sender)

        // Register connection first
        try await manager.register(connectionID: "conn-123")
        await sender.markAlive("conn-123")

        let stateStore = InMemoryStateStore()
        let gateway = CloudGateway(
            configuration: .init(stateStore: stateStore)
        )

        let handler = WebSocketLambdaHandler(
            gateway: gateway,
            connectionManager: manager
        )

        // Create stream resume envelope
        let streamID = UUID()
        let actorID = TrebuchetActorID(id: "test-actor")
        let resume = StreamResumeEnvelope(
            streamID: streamID,
            lastSequence: 42,
            actorID: actorID,
            targetIdentifier: "observeState"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let envelopeData = try encoder.encode(TrebuchetEnvelope.streamResume(resume))
        let body = String(data: envelopeData, encoding: .utf8)!

        // Create message event
        let event = APIGatewayWebSocketEvent(
            requestContext: .init(
                connectionId: "conn-123",
                routeKey: "$default"
            ),
            body: body
        )

        // Handle event
        let response = try await handler.handle(event)

        // Verify response
        #expect(response.statusCode == 200)

        // Verify StreamStart sent (since we don't have buffered data yet)
        let sentMessages = await sender.getSentMessages(for: "conn-123")
        #expect(sentMessages.count == 1)
    }

    @Test("WebSocketLambdaHandler broadcasts stream data")
    func testBroadcastStreamData() async throws {
        let storage = InMemoryConnectionStorage()
        let sender = InMemoryConnectionSender()
        let manager = ConnectionManager(storage: storage, sender: sender)

        let stateStore = InMemoryStateStore()
        let gateway = CloudGateway(
            configuration: .init(stateStore: stateStore)
        )

        let handler = WebSocketLambdaHandler(
            gateway: gateway,
            connectionManager: manager
        )

        // Register connections
        try await manager.register(connectionID: "conn-1", actorID: "actor-1")
        try await manager.register(connectionID: "conn-2", actorID: "actor-1")

        await sender.markAlive("conn-1")
        await sender.markAlive("conn-2")

        // Broadcast stream data
        let streamID = UUID()
        let testData = Data("state".utf8)

        try await handler.broadcastStreamData(
            streamID: streamID,
            sequenceNumber: 1,
            data: testData,
            to: "actor-1"
        )

        // Verify both connections received the data
        let sent1 = await sender.getSentMessages(for: "conn-1")
        let sent2 = await sender.getSentMessages(for: "conn-2")

        #expect(sent1.count == 1)
        #expect(sent2.count == 1)

        // Verify it's a StreamData envelope
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope1 = try decoder.decode(TrebuchetEnvelope.self, from: sent1[0])

        if case .streamData(let data) = envelope1 {
            #expect(data.streamID == streamID)
            #expect(data.sequenceNumber == 1)
        } else {
            #expect(Bool(false), "Expected StreamData envelope")
        }
    }
}
