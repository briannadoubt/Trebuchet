import Testing
import Foundation
@testable import TrebuchetAWS
@testable import TrebuchetCloud

@Suite("AWS Integration Workflow Tests")
struct AWSIntegrationWorkflowTests {

    init() async throws {
        // Skip all tests if LocalStack is not available
        guard await LocalStackTestHelpers.isLocalStackAvailable() else {
            throw TestSkipError()
        }
    }

    @Test("Actor discovery workflow")
    func testActorDiscoveryWorkflow() async throws {
        let client = LocalStackTestHelpers.createAWSClient()
        

        let registry = try await LocalStackTestHelpers.createRegistry(client: client)
        let stateStore = LocalStackTestHelpers.createStateStore(client: client)
        let actorId = LocalStackTestHelpers.uniqueActorID()

        // Step 1: Register actor in Cloud Map
        let endpoint = CloudEndpoint(
            provider: .aws,
            region: "us-east-1",
            identifier: "arn:aws:lambda:us-east-1:123:function:game-room",
            scheme: .lambda,
            metadata: ["type": "GameRoom"]
        )
        try await registry.register(
            actorID: actorId,
            endpoint: endpoint,
            metadata: ["version": "1.0"],
            ttl: nil
        )

        // Step 2: Save actor state to DynamoDB
        let state = GameRoomState(name: "Main Room", players: 5, maxPlayers: 10)
        try await stateStore.save(state, for: actorId)

        // Step 3: Resolve actor from Cloud Map
        let resolved = try await registry.resolve(actorID: actorId)
        #expect(resolved != nil)
        #expect(resolved?.provider == .aws)
        #expect(resolved?.region == "us-east-1")
        #expect(resolved?.metadata["type"] == "GameRoom")

        // Step 4: Load actor state from DynamoDB
        let loadedState = try await stateStore.load(for: actorId, as: GameRoomState.self)
        #expect(loadedState != nil)
        #expect(loadedState?.name == "Main Room")
        #expect(loadedState?.players == 5)
        #expect(loadedState?.maxPlayers == 10)

        // Cleanup
        try? await registry.deregister(actorID: actorId)
        try await LocalStackTestHelpers.cleanupTable("trebuchet-test-state", client: client)
        try await client.shutdown()
    }

    @Test("Optimistic locking prevents conflicts")
    func testOptimisticLockingPreventsConflicts() async throws {
        let client = LocalStackTestHelpers.createAWSClient()
        

        let stateStore = LocalStackTestHelpers.createStateStore(client: client)
        let actorId = LocalStackTestHelpers.uniqueActorID()

        // Initial state (version will be 1)
        let initialState = CounterState(counter: 0)
        try await stateStore.save(initialState, for: actorId)

        // Client 1 loads state (version 1)
        let client1State = try await stateStore.load(for: actorId, as: CounterState.self)
        #expect(client1State != nil)

        // Client 2 loads state (version 1)
        let client2State = try await stateStore.load(for: actorId, as: CounterState.self)
        #expect(client2State != nil)

        // Client 1 updates successfully with version 1
        let client1Update = CounterState(counter: 1)
        let newVersion = try await stateStore.saveIfVersion(client1Update, for: actorId, expectedVersion: 1)
        #expect(newVersion == 2)

        // Client 2 tries to update with stale version 1 - should fail
        let client2Update = CounterState(counter: 2)

        do {
            _ = try await stateStore.saveIfVersion(client2Update, for: actorId, expectedVersion: 1)
            Issue.record("Expected version conflict error")
        } catch let error as ActorStateError {
            if case .versionConflict(let expected, let actual) = error {
                #expect(expected == 1)
                #expect(actual == 2)
            } else {
                Issue.record("Wrong error type: \(error)")
            }
        }

        // Verify final state is from client 1
        let finalState = try await stateStore.load(for: actorId, as: CounterState.self)
        #expect(finalState?.counter == 1)

        // Cleanup
        try await LocalStackTestHelpers.cleanupTable("trebuchet-test-state", client: client)
        try await client.shutdown()
    }

    @Test("Multi-region actor coordination")
    func testMultiRegionActorCoordination() async throws {
        let client = LocalStackTestHelpers.createAWSClient()
        

        let registry = try await LocalStackTestHelpers.createRegistry(client: client)
        let stateStore = LocalStackTestHelpers.createStateStore(client: client)

        // Register actors in different "regions"
        let regions = ["us-east-1", "us-west-2", "eu-west-1"]
        var actorIds: [String] = []

        for (index, region) in regions.enumerated() {
            let actorId = LocalStackTestHelpers.uniqueActorID(prefix: "region-actor")
            actorIds.append(actorId)

            // Register in Cloud Map with region metadata
            let endpoint = CloudEndpoint(
                provider: .aws,
                region: region,
                identifier: "arn:aws:lambda:\(region):123:function:actor-\(index)",
                scheme: .lambda,
                metadata: ["availability": "high"]
            )
            try await registry.register(
                actorID: actorId,
                endpoint: endpoint,
                metadata: [:],
                ttl: nil
            )

            // Save regional state
            let state = RegionalActorState(region: region, status: "active", load: index * 10)
            try await stateStore.save(state, for: actorId)
        }

        // Verify all actors are discoverable
        for (index, actorId) in actorIds.enumerated() {
            let resolved = try await registry.resolve(actorID: actorId)
            #expect(resolved != nil)
            #expect(resolved?.region == regions[index])

            let loadedState = try await stateStore.load(for: actorId, as: RegionalActorState.self)
            #expect(loadedState != nil)
            #expect(loadedState?.region == regions[index])
            #expect(loadedState?.status == "active")
        }

        // Cleanup
        for actorId in actorIds {
            try? await registry.deregister(actorID: actorId)
        }
        try await LocalStackTestHelpers.cleanupTable("trebuchet-test-state", client: client)
        try await client.shutdown()
    }
}

// MARK: - Test Types

struct GameRoomState: Codable, Sendable {
    let name: String
    let players: Int
    let maxPlayers: Int
}

struct CounterState: Codable, Sendable {
    let counter: Int
}

struct RegionalActorState: Codable, Sendable {
    let region: String
    let status: String
    let load: Int
}
