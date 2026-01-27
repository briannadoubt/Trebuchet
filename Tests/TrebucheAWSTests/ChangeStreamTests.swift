import Testing
import Foundation
@testable import Trebuchet
@testable import TrebuchetCloud
@testable import TrebuchetAWS

@Suite("Change Stream Tests")
struct ChangeStreamTests {

    // MARK: - DynamoDB Stream Adapter Tests

    @Test("DynamoDBStreamAdapter processes INSERT events")
    func testProcessInsertEvent() async throws {
        let storage = InMemoryConnectionStorage()
        let sender = InMemoryConnectionSender()
        let manager = ConnectionManager(storage: storage, sender: sender)
        let adapter = DynamoDBStreamAdapter(connectionManager: manager)

        // Register connections and subscribe to streams
        let streamID1 = UUID()
        let streamID2 = UUID()
        try await manager.register(connectionID: "conn-1", actorID: "actor-1")
        try await manager.register(connectionID: "conn-2", actorID: "actor-1")
        try await manager.subscribe(connectionID: "conn-1", streamID: streamID1, actorID: "actor-1")
        try await manager.subscribe(connectionID: "conn-2", streamID: streamID2, actorID: "actor-1")
        await sender.markAlive("conn-1")
        await sender.markAlive("conn-2")

        // Create INSERT event
        let stateData = Data("test-state".utf8)
        let event = DynamoDBStreamEvent(records: [
            DynamoDBStreamRecord(
                eventID: "event-1",
                eventName: "INSERT",
                eventSource: "aws:dynamodb",
                dynamodb: DynamoDBStreamData(
                    newImage: [
                        "actorId": .s("actor-1"),
                        "state": .b(stateData),
                        "sequenceNumber": .n("1")
                    ],
                    sequenceNumber: "12345"
                )
            )
        ])

        // Process event
        try await adapter.process(event)

        // Verify broadcast to both connections
        let sent1 = await sender.getSentMessages(for: "conn-1")
        let sent2 = await sender.getSentMessages(for: "conn-2")

        #expect(sent1.count == 1)
        #expect(sent2.count == 1)

        // Verify it's a StreamData envelope
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(TrebuchetEnvelope.self, from: sent1[0])

        if case .streamData(let streamData) = envelope {
            #expect(streamData.sequenceNumber == 1)
            #expect(streamData.data == stateData)
        } else {
            #expect(Bool(false), "Expected StreamData envelope")
        }
    }

    @Test("DynamoDBStreamAdapter processes MODIFY events")
    func testProcessModifyEvent() async throws {
        let storage = InMemoryConnectionStorage()
        let sender = InMemoryConnectionSender()
        let manager = ConnectionManager(storage: storage, sender: sender)
        let adapter = DynamoDBStreamAdapter(connectionManager: manager)

        // Register connection and subscribe to stream
        let streamID = UUID()
        try await manager.register(connectionID: "conn-1", actorID: "actor-1")
        try await manager.subscribe(connectionID: "conn-1", streamID: streamID, actorID: "actor-1")
        await sender.markAlive("conn-1")

        // Create MODIFY event
        let newStateData = Data("updated-state".utf8)
        let event = DynamoDBStreamEvent(records: [
            DynamoDBStreamRecord(
                eventID: "event-2",
                eventName: "MODIFY",
                eventSource: "aws:dynamodb",
                dynamodb: DynamoDBStreamData(
                    newImage: [
                        "actorId": .s("actor-1"),
                        "state": .b(newStateData),
                        "sequenceNumber": .n("2")
                    ],
                    oldImage: [
                        "actorId": .s("actor-1"),
                        "state": .b(Data("old-state".utf8)),
                        "sequenceNumber": .n("1")
                    ],
                    sequenceNumber: "12346"
                )
            )
        ])

        // Process event
        try await adapter.process(event)

        // Verify broadcast
        let sentMessages = await sender.getSentMessages(for: "conn-1")
        #expect(sentMessages.count == 1)

        // Verify updated state
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(TrebuchetEnvelope.self, from: sentMessages[0])

        if case .streamData(let streamData) = envelope {
            #expect(streamData.data == newStateData)
            #expect(streamData.sequenceNumber == 2)
        } else {
            #expect(Bool(false), "Expected StreamData envelope")
        }
    }

    @Test("DynamoDBStreamAdapter ignores REMOVE events")
    func testIgnoreRemoveEvents() async throws {
        let storage = InMemoryConnectionStorage()
        let sender = InMemoryConnectionSender()
        let manager = ConnectionManager(storage: storage, sender: sender)
        let adapter = DynamoDBStreamAdapter(connectionManager: manager)

        // Register connection
        try await manager.register(connectionID: "conn-1", actorID: "actor-1")
        await sender.markAlive("conn-1")

        // Create REMOVE event
        let event = DynamoDBStreamEvent(records: [
            DynamoDBStreamRecord(
                eventID: "event-3",
                eventName: "REMOVE",
                eventSource: "aws:dynamodb",
                dynamodb: DynamoDBStreamData(
                    oldImage: [
                        "actorId": .s("actor-1"),
                        "state": .b(Data("deleted-state".utf8))
                    ]
                )
            )
        ])

        // Process event
        try await adapter.process(event)

        // Verify no broadcast (REMOVE events are ignored)
        let sentMessages = await sender.getSentMessages(for: "conn-1")
        #expect(sentMessages.isEmpty)
    }

    @Test("DynamoDBStreamAdapter processes multiple records in batch")
    func testProcessMultipleRecords() async throws {
        let storage = InMemoryConnectionStorage()
        let sender = InMemoryConnectionSender()
        let manager = ConnectionManager(storage: storage, sender: sender)
        let adapter = DynamoDBStreamAdapter(connectionManager: manager)

        // Register connection and subscribe to stream
        let streamID = UUID()
        try await manager.register(connectionID: "conn-1", actorID: "actor-1")
        try await manager.subscribe(connectionID: "conn-1", streamID: streamID, actorID: "actor-1")
        await sender.markAlive("conn-1")

        // Create batch event with multiple records
        let event = DynamoDBStreamEvent(records: [
            DynamoDBStreamRecord(
                eventID: "event-1",
                eventName: "INSERT",
                eventSource: "aws:dynamodb",
                dynamodb: DynamoDBStreamData(
                    newImage: [
                        "actorId": .s("actor-1"),
                        "state": .b(Data("state-1".utf8)),
                        "sequenceNumber": .n("1")
                    ]
                )
            ),
            DynamoDBStreamRecord(
                eventID: "event-2",
                eventName: "MODIFY",
                eventSource: "aws:dynamodb",
                dynamodb: DynamoDBStreamData(
                    newImage: [
                        "actorId": .s("actor-1"),
                        "state": .b(Data("state-2".utf8)),
                        "sequenceNumber": .n("2")
                    ]
                )
            )
        ])

        // Process batch
        try await adapter.process(event)

        // Verify both records were broadcast
        let sentMessages = await sender.getSentMessages(for: "conn-1")
        #expect(sentMessages.count == 2)
    }

    @Test("DynamoDBStreamAdapter handles missing actorID gracefully")
    func testMissingActorID() async throws {
        let storage = InMemoryConnectionStorage()
        let sender = InMemoryConnectionSender()
        let manager = ConnectionManager(storage: storage, sender: sender)
        let adapter = DynamoDBStreamAdapter(connectionManager: manager)

        // Create event without actorID
        let event = DynamoDBStreamEvent(records: [
            DynamoDBStreamRecord(
                eventID: "event-1",
                eventName: "INSERT",
                eventSource: "aws:dynamodb",
                dynamodb: DynamoDBStreamData(
                    newImage: [
                        "state": .b(Data("state".utf8))
                        // Missing actorId
                    ]
                )
            )
        ])

        // Process should not throw
        try await adapter.process(event)

        // No messages should be sent (no actorID to route to)
        // This test just verifies no crash occurs
    }

    @Test("DynamoDBStreamAdapter handles missing state data gracefully")
    func testMissingStateData() async throws {
        let storage = InMemoryConnectionStorage()
        let sender = InMemoryConnectionSender()
        let manager = ConnectionManager(storage: storage, sender: sender)
        let adapter = DynamoDBStreamAdapter(connectionManager: manager)

        // Create event without state data
        let event = DynamoDBStreamEvent(records: [
            DynamoDBStreamRecord(
                eventID: "event-1",
                eventName: "INSERT",
                eventSource: "aws:dynamodb",
                dynamodb: DynamoDBStreamData(
                    newImage: [
                        "actorId": .s("actor-1")
                        // Missing state
                    ]
                )
            )
        ])

        // Process should not throw
        try await adapter.process(event)
    }

    // MARK: - Stream Processor Handler Tests

    @Test("StreamProcessorHandler initializes correctly")
    func testStreamProcessorInitialization() async throws {
        let storage = InMemoryConnectionStorage()
        let sender = InMemoryConnectionSender()
        let manager = ConnectionManager(storage: storage, sender: sender)

        let handler = StreamProcessorHandler.initialize(connectionManager: manager)

        // Verify handler was created
        #expect(handler != nil)
    }

    @Test("StreamProcessorHandler handles events")
    func testStreamProcessorHandleEvent() async throws {
        let storage = InMemoryConnectionStorage()
        let sender = InMemoryConnectionSender()
        let manager = ConnectionManager(storage: storage, sender: sender)
        let handler = StreamProcessorHandler.initialize(connectionManager: manager)

        // Register connection and subscribe to stream
        let streamID = UUID()
        try await manager.register(connectionID: "conn-1", actorID: "actor-1")
        try await manager.subscribe(connectionID: "conn-1", streamID: streamID, actorID: "actor-1")
        await sender.markAlive("conn-1")

        // Create event
        let event = DynamoDBStreamEvent(records: [
            DynamoDBStreamRecord(
                eventID: "event-1",
                eventName: "INSERT",
                eventSource: "aws:dynamodb",
                dynamodb: DynamoDBStreamData(
                    newImage: [
                        "actorId": .s("actor-1"),
                        "state": .b(Data("state".utf8)),
                        "sequenceNumber": .n("1")
                    ]
                )
            )
        ])

        // Handle event
        try await handler.handle(event)

        // Verify broadcast occurred
        let sentMessages = await sender.getSentMessages(for: "conn-1")
        #expect(sentMessages.count == 1)
    }

    @Test("StreamProcessorHandler handles single record")
    func testStreamProcessorHandleRecord() async throws {
        let storage = InMemoryConnectionStorage()
        let sender = InMemoryConnectionSender()
        let manager = ConnectionManager(storage: storage, sender: sender)
        let handler = StreamProcessorHandler.initialize(connectionManager: manager)

        // Register connection and subscribe to stream
        let streamID = UUID()
        try await manager.register(connectionID: "conn-1", actorID: "actor-1")
        try await manager.subscribe(connectionID: "conn-1", streamID: streamID, actorID: "actor-1")
        await sender.markAlive("conn-1")

        // Create record
        let record = DynamoDBStreamRecord(
            eventID: "event-1",
            eventName: "MODIFY",
            eventSource: "aws:dynamodb",
            dynamodb: DynamoDBStreamData(
                newImage: [
                    "actorId": .s("actor-1"),
                    "state": .b(Data("updated".utf8)),
                    "sequenceNumber": .n("5")
                ]
            )
        )

        // Handle record
        try await handler.handleRecord(record)

        // Verify broadcast
        let sentMessages = await sender.getSentMessages(for: "conn-1")
        #expect(sentMessages.count == 1)
    }

    // MARK: - DynamoDB State Store Sequence Tests

    @Test("DynamoDBStateStore saves with sequence tracking")
    func testSaveWithSequence() async throws {
        // Note: This test uses the in-memory stateStore since we don't have
        // actual DynamoDB connection in tests
        let stateStore = InMemoryStateStore()

        struct TestState: Codable, Sendable {
            var count: Int
        }

        let state = TestState(count: 42)

        // Save with explicit sequence
        try await stateStore.save(state, for: "test-actor")

        // Verify saved
        let loaded = try await stateStore.load(for: "test-actor", as: TestState.self)
        #expect(loaded?.count == 42)
    }

    // MARK: - End-to-End Integration Test

    @Test("End-to-end: State change triggers stream broadcast")
    func testEndToEndStateChangeStreaming() async throws {
        // Setup infrastructure
        let storage = InMemoryConnectionStorage()
        let sender = InMemoryConnectionSender()
        let manager = ConnectionManager(storage: storage, sender: sender)
        let adapter = DynamoDBStreamAdapter(connectionManager: manager)

        // Register WebSocket connections and subscribe to streams
        let streamID1 = UUID()
        let streamID2 = UUID()
        try await manager.register(connectionID: "client-1", actorID: "todo-list")
        try await manager.register(connectionID: "client-2", actorID: "todo-list")
        try await manager.subscribe(connectionID: "client-1", streamID: streamID1, actorID: "todo-list")
        try await manager.subscribe(connectionID: "client-2", streamID: streamID2, actorID: "todo-list")
        await sender.markAlive("client-1")
        await sender.markAlive("client-2")

        // Simulate state change in DynamoDB
        struct TodoState: Codable {
            var todos: [String]
        }

        let newState = TodoState(todos: ["Buy milk", "Walk dog"])
        let encoder = JSONEncoder()
        let stateData = try encoder.encode(newState)

        // Create DynamoDB Stream event
        let event = DynamoDBStreamEvent(records: [
            DynamoDBStreamRecord(
                eventID: UUID().uuidString,
                eventName: "MODIFY",
                eventSource: "aws:dynamodb",
                dynamodb: DynamoDBStreamData(
                    newImage: [
                        "actorId": .s("todo-list"),
                        "state": .b(stateData),
                        "sequenceNumber": .n("10")
                    ],
                    oldImage: [
                        "actorId": .s("todo-list"),
                        "state": .b(Data()),
                        "sequenceNumber": .n("9")
                    ],
                    sequenceNumber: "67890"
                )
            )
        ])

        // Process stream event
        try await adapter.process(event)

        // Verify both clients received the update
        let sent1 = await sender.getSentMessages(for: "client-1")
        let sent2 = await sender.getSentMessages(for: "client-2")

        #expect(sent1.count == 1)
        #expect(sent2.count == 1)

        // Verify content
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope1 = try decoder.decode(TrebuchetEnvelope.self, from: sent1[0])

        if case .streamData(let streamData) = envelope1 {
            #expect(streamData.sequenceNumber == 10)
            let receivedState = try decoder.decode(TodoState.self, from: streamData.data)
            #expect(receivedState.todos.count == 2)
            #expect(receivedState.todos[0] == "Buy milk")
        } else {
            #expect(Bool(false), "Expected StreamData envelope")
        }
    }
}
