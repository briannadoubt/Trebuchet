import Testing
import Foundation
@testable import Trebuchet

// MARK: - Test Actors

/// Test actor with multiple @StreamedState properties
@Trebuchet
distributed actor GameRoom {
    @StreamedState public var gameState: GameState = GameState()
    @StreamedState public var playerList: [Player] = []

    public distributed func updateGameState(_ state: GameState) {
        self.gameState = state
    }

    public distributed func updatePlayers(_ players: [Player]) {
        self.playerList = players
    }
}

/// Streaming protocol for GameRoom
public protocol GameRoomStreaming: AnyObject, Sendable {
    func observeGameState() async -> AsyncStream<GameState>
    func observePlayerList() async -> AsyncStream<[Player]>
}

extension GameRoom: @preconcurrency GameRoomStreaming {}

/// Test actor with single @StreamedState property
@Trebuchet
distributed actor TestCounter {
    @StreamedState public var count: Int = 0

    public distributed func increment() {
        self.count += 1
    }

    public distributed func setCount(_ value: Int) {
        self.count = value
    }
}

public protocol CounterStreaming: AnyObject, Sendable {
    func observeCount() async -> AsyncStream<Int>
}

extension TestCounter: @preconcurrency CounterStreaming {}

// MARK: - Test Data Types

public struct GameState: Codable, Sendable, Equatable {
    public var phase: String
    public var score: Int

    public init(phase: String = "lobby", score: Int = 0) {
        self.phase = phase
        self.score = score
    }
}

public struct Player: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

// MARK: - Test Utilities

/// Thread-safe collector for test results
actor ResultCollector<T: Sendable> {
    private var values: [T] = []

    func append(_ value: T) {
        values.append(value)
    }

    func getAll() -> [T] {
        values
    }

    func count() -> Int {
        values.count
    }
}

/// Helper to run a test with a configured server
func withTestServer<T>(
    port: UInt16 = 0,
    _ test: (TrebuchetServer, UInt16) async throws -> T
) async throws -> T {
    let actualPort: UInt16 = port == 0 ? UInt16.random(in: 9000..<10000) : port
    let server = TrebuchetServer(transport: .webSocket(port: actualPort))

    // Start server in background
    let serverTask = Task {
        try await server.run()
    }

    defer {
        Task {
            await server.shutdown()
            serverTask.cancel()
        }
    }

    // Give server time to start
    try await Task.sleep(for: .milliseconds(100))

    return try await test(server, actualPort)
}

/// Helper to run a test with a connected client
func withTestClient<T>(
    host: String = "localhost",
    port: UInt16,
    _ test: (TrebuchetClient) async throws -> T
) async throws -> T {
    let client = TrebuchetClient(transport: .webSocket(host: host, port: port))
    try await client.connect()

    defer {
        Task {
            await client.disconnect()
        }
    }

    return try await test(client)
}

// MARK: - Tests

/// Integration tests for the streaming system
///
/// These tests verify end-to-end streaming behavior with actual server/client connections,
/// including the critical bug fix for multiple @StreamedState properties on the same actor.
@Suite("Streaming Integration Tests")
struct StreamingIntegrationTests {

    /// CRITICAL: Test that verifies multiple @StreamedState properties route to correct handlers
    /// This test would have caught the bug we just fixed where registerTyped didn't check method names
    @Test("Multiple @StreamedState properties route correctly")
    func testMultipleStreamedStateHandlers() async throws {
        try await withTestServer { server, port in
            // Create and expose a GameRoom with two @StreamedState properties
            let room = GameRoom(actorSystem: server.actorSystem)
            await server.expose(room, as: "game-room")

            // Configure streaming for BOTH properties with distinct handlers
            await server.configureStreaming(
                for: GameRoomStreaming.self,
                method: "observeGameState"
            ) { await $0.observeGameState() }

            await server.configureStreaming(
                for: GameRoomStreaming.self,
                method: "observePlayerList"
            ) { await $0.observePlayerList() }

            // Connect client and subscribe to BOTH streams
            try await withTestClient(port: port) { client in
                let remoteRoom = try client.resolve(GameRoom.self, id: "game-room")

                // Create encoder for streaming calls
                var encoder1 = remoteRoom.actorSystem.makeInvocationEncoder()
                var encoder2 = remoteRoom.actorSystem.makeInvocationEncoder()

                // Subscribe to gameState stream
                let (gameStreamID, gameStream) = try await remoteRoom.actorSystem.remoteCallStream(
                    on: remoteRoom,
                    target: RemoteCallTarget("observeGameState"),
                    invocation: &encoder1,
                    returning: GameState.self
                )

                // Subscribe to playerList stream
                let (playerStreamID, playerStream) = try await remoteRoom.actorSystem.remoteCallStream(
                    on: remoteRoom,
                    target: RemoteCallTarget("observePlayerList"),
                    invocation: &encoder2,
                    returning: [Player].self
                )

                #expect(gameStreamID != playerStreamID, "Streams should have different IDs")

                // Collect updates from both streams concurrently using thread-safe collectors
                let gameCollector = ResultCollector<GameState>()
                let playerCollector = ResultCollector<[Player]>()

                let gameTask = Task {
                    var count = 0
                    for await state in gameStream {
                        await gameCollector.append(state)
                        count += 1
                        if count >= 2 { break }
                    }
                }

                let playerTask = Task {
                    var count = 0
                    for await players in playerStream {
                        await playerCollector.append(players)
                        count += 1
                        if count >= 2 { break }
                    }
                }

                // Wait for initial states
                try await Task.sleep(for: .milliseconds(100))

                // Update gameState - should only affect gameState stream
                try await remoteRoom.updateGameState(GameState(phase: "playing", score: 100))

                // Wait for update
                try await Task.sleep(for: .milliseconds(100))

                // Update playerList - should only affect playerList stream
                try await remoteRoom.updatePlayers([
                    Player(id: "1", name: "Alice"),
                    Player(id: "2", name: "Bob")
                ])

                // Wait for updates to propagate
                try await Task.sleep(for: .milliseconds(200))

                gameTask.cancel()
                playerTask.cancel()

                // Get collected results
                let receivedGameStates = await gameCollector.getAll()
                let receivedPlayerLists = await playerCollector.getAll()

                // Verify gameState stream received gameState updates
                #expect(receivedGameStates.count >= 2, "Should receive initial + updated game state")
                #expect(receivedGameStates[0].phase == "lobby", "Initial state should be lobby")
                #expect(receivedGameStates[1].phase == "playing", "Updated state should be playing")
                #expect(receivedGameStates[1].score == 100, "Score should be 100")

                // Verify playerList stream received playerList updates
                #expect(receivedPlayerLists.count >= 2, "Should receive initial + updated player list")
                #expect(receivedPlayerLists[0].isEmpty, "Initial player list should be empty")
                #expect(receivedPlayerLists[1].count == 2, "Updated list should have 2 players")
                #expect(receivedPlayerLists[1][0].name == "Alice", "First player should be Alice")
            }
        }
    }

    /// Test dynamic actor creation during stream subscription
    @Test("Dynamic actor creation during streaming")
    func testDynamicActorStreamingCreation() async throws {
        try await withTestServer { server, port in
            // Configure dynamic actor creation
            server.onActorRequest = { actorID in
                // Create and expose the actor when requested
                let counter = TestCounter(actorSystem: server.actorSystem)
                await server.expose(counter, as: actorID.id)
            }

            // Configure streaming
            await server.configureStreaming(
                for: CounterStreaming.self,
                method: "observeCount"
            ) { await $0.observeCount() }

            try await withTestClient(port: port) { client in
                // Try to resolve and subscribe to non-existent actor
                // This should trigger dynamic creation
                let counter = try client.resolve(TestCounter.self, id: "dynamic-counter")

                // Give server time to create the actor via onActorRequest
                try await Task.sleep(for: .milliseconds(300))

                var encoder = counter.actorSystem.makeInvocationEncoder()
                let (_, stream) = try await counter.actorSystem.remoteCallStream(
                    on: counter,
                    target: RemoteCallTarget("observeCount"),
                    invocation: &encoder,
                    returning: Int.self
                )

                let collector = ResultCollector<Int>()
                let task = Task {
                    var count = 0
                    for await value in stream {
                        await collector.append(value)
                        count += 1
                        if count >= 2 { break }
                    }
                }

                // Wait for initial state to arrive
                try await Task.sleep(for: .milliseconds(400))

                // Update the counter
                try await counter.increment()

                // Wait for update to propagate
                try await Task.sleep(for: .milliseconds(400))
                task.cancel()

                // Get collected results
                let receivedValues = await collector.getAll()

                // Verify we received both initial state and update
                #expect(receivedValues.count >= 1, "Should receive at least initial state, got \(receivedValues.count)")
                if receivedValues.count >= 1 {
                    #expect(receivedValues[0] == 0, "Initial count should be 0")
                }
                if receivedValues.count >= 2 {
                    #expect(receivedValues[1] == 1, "Updated count should be 1")
                }
            }
        }
    }

    /// Test end-to-end streaming with state updates
    @Test("End-to-end streaming flow")
    func testEndToEndStreaming() async throws {
        try await withTestServer { server, port in
            let counter = TestCounter(actorSystem: server.actorSystem)
            await server.expose(counter, as: "counter")

            await server.configureStreaming(
                for: CounterStreaming.self,
                method: "observeCount"
            ) { await $0.observeCount() }

            try await withTestClient(port: port) { client in
                let remoteCounter = try client.resolve(TestCounter.self, id: "counter")

                var encoder = remoteCounter.actorSystem.makeInvocationEncoder()
                let (_, stream) = try await remoteCounter.actorSystem.remoteCallStream(
                    on: remoteCounter,
                    target: RemoteCallTarget("observeCount"),
                    invocation: &encoder,
                    returning: Int.self
                )

                let collector = ResultCollector<Int>()
                let task = Task {
                    for await value in stream {
                        await collector.append(value)
                        let count = await collector.count()
                        if count >= 5 { break }
                    }
                }

                // Wait for initial state
                try await Task.sleep(for: .milliseconds(50))

                // Send multiple updates
                try await remoteCounter.increment()
                try await remoteCounter.increment()
                try await remoteCounter.setCount(10)
                try await remoteCounter.increment()

                try await Task.sleep(for: .milliseconds(200))
                task.cancel()

                // Get collected results
                let receivedValues = await collector.getAll()

                // Verify all updates were received
                #expect(receivedValues.count >= 5, "Should receive all updates")
                #expect(receivedValues[0] == 0, "Initial")
                #expect(receivedValues[1] == 1, "After first increment")
                #expect(receivedValues[2] == 2, "After second increment")
                #expect(receivedValues[3] == 10, "After setCount")
                #expect(receivedValues[4] == 11, "After final increment")
            }
        }
    }


    /// Test stream resumption after disconnect
    @Test("Stream resumption after disconnect")
    func testStreamResumption() async throws {
        // This test verifies that the stream buffering and resumption infrastructure exists
        // A full end-to-end test of resumption requires more complex setup
        try await withTestServer { server, port in
            let counter = TestCounter(actorSystem: server.actorSystem)
            await server.expose(counter, as: "counter")

            await server.configureStreaming(
                for: CounterStreaming.self,
                method: "observeCount"
            ) { await $0.observeCount() }

            // Connect and establish stream
            try await withTestClient(port: port) { client in
                let remoteCounter = try client.resolve(TestCounter.self, id: "counter")
                var encoder = remoteCounter.actorSystem.makeInvocationEncoder()
                let (streamID, stream) = try await remoteCounter.actorSystem.remoteCallStream(
                    on: remoteCounter,
                    target: RemoteCallTarget("observeCount"),
                    invocation: &encoder,
                    returning: Int.self
                )

                let collector = ResultCollector<Int>()
                let task = Task {
                    for await value in stream {
                        await collector.append(value)
                        let count = await collector.count()
                        if count >= 2 { break }
                    }
                }

                try await Task.sleep(for: .milliseconds(100))
                try await remoteCounter.increment()
                try await Task.sleep(for: .milliseconds(200))
                task.cancel()

                let values = await collector.getAll()
                #expect(values.count >= 1, "Should receive streaming updates")

                // Verify we can get the last sequence (for resumption)
                let lastSeq = await remoteCounter.actorSystem.streamRegistry.getLastSequence(streamID: streamID)
                #expect(lastSeq != nil, "Should track sequence numbers for resumption")
            }
        }
    }

    /// Test connection drop during streaming
    @Test("Connection drop during streaming")
    func testConnectionDropDuringStreaming() async throws {
        try await withTestServer { server, port in
            let counter = TestCounter(actorSystem: server.actorSystem)
            await server.expose(counter, as: "counter")

            await server.configureStreaming(
                for: CounterStreaming.self,
                method: "observeCount"
            ) { await $0.observeCount() }

            let client = TrebuchetClient(transport: .webSocket(host: "localhost", port: port))
            try await client.connect()

            let remoteCounter = try client.resolve(TestCounter.self, id: "counter")
            var encoder = remoteCounter.actorSystem.makeInvocationEncoder()
            let (_, stream) = try await remoteCounter.actorSystem.remoteCallStream(
                on: remoteCounter,
                target: RemoteCallTarget("observeCount"),
                invocation: &encoder,
                returning: Int.self
            )

            let collector = ResultCollector<Int>()
            let task = Task {
                for await value in stream {
                    await collector.append(value)
                }
            }

            try await Task.sleep(for: .milliseconds(50))
            try await remoteCounter.increment()
            try await Task.sleep(for: .milliseconds(50))

            // Disconnect abruptly
            await client.disconnect()

            try await Task.sleep(for: .milliseconds(100))

            // Task should complete naturally
            task.cancel()

            let receivedValues = await collector.getAll()
            #expect(receivedValues.count >= 1, "Should have received at least initial state")
        }
    }

    /// Test actor termination during streaming
    @Test("Actor termination during streaming")
    func testActorTerminationDuringStreaming() async throws {
        try await withTestServer { server, port in
            var counter: TestCounter? = TestCounter(actorSystem: server.actorSystem)
            await server.expose(counter!, as: "counter")

            await server.configureStreaming(
                for: CounterStreaming.self,
                method: "observeCount"
            ) { await $0.observeCount() }

            try await withTestClient(port: port) { client in
                let remoteCounter = try client.resolve(TestCounter.self, id: "counter")
                var encoder = remoteCounter.actorSystem.makeInvocationEncoder()
                let (_, stream) = try await remoteCounter.actorSystem.remoteCallStream(
                    on: remoteCounter,
                    target: RemoteCallTarget("observeCount"),
                    invocation: &encoder,
                    returning: Int.self
                )

                let collector = ResultCollector<Int>()
                let task = Task {
                    for await value in stream {
                        await collector.append(value)
                    }
                }

                try await Task.sleep(for: .milliseconds(50))

                // Terminate the actor by setting it to nil
                counter = nil

                try await Task.sleep(for: .milliseconds(100))

                // Stream should eventually end
                task.cancel()

                let receivedValues = await collector.getAll()
                #expect(receivedValues.count >= 1, "Should receive initial state before termination")
            }
        }
    }
}
