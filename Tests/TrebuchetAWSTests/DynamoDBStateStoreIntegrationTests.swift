import Testing
import Foundation
@testable import TrebuchetAWS
@testable import TrebuchetCloud

@Suite("DynamoDB State Store Integration Tests")
struct DynamoDBStateStoreIntegrationTests {

    @Test("Save and load actor state")
    func testSaveAndLoad() async throws {
        try #require(await LocalStackTestHelpers.isLocalStackAvailable())
        let client = LocalStackTestHelpers.createAWSClient()


        let stateStore = LocalStackTestHelpers.createStateStore(client: client)
        let actorId = LocalStackTestHelpers.uniqueActorID()

        // Save state
        let state = TestActorState(name: "TestActor", count: 42)
        try await stateStore.save(state, for: actorId)

        // Load state
        let loaded = try await stateStore.load(for: actorId, as: TestActorState.self)
        #expect(loaded != nil)
        #expect(loaded?.name == "TestActor")
        #expect(loaded?.count == 42)

        // Cleanup
        try await LocalStackTestHelpers.cleanupTable("trebuchet-test-state", client: client)
        try await client.shutdown()


    }

    @Test("Sequence numbers auto-increment")
    func testSequenceNumbersAutoIncrement() async throws {
        try #require(await LocalStackTestHelpers.isLocalStackAvailable())
        let client = LocalStackTestHelpers.createAWSClient()

        

        let stateStore = LocalStackTestHelpers.createStateStore(client: client)
        let actorId = LocalStackTestHelpers.uniqueActorID()

        let state = TestActorState(name: "test", count: 1)

        // First save - version should be 1
        try await stateStore.save(state, for: actorId)
        var sequence = try await stateStore.getSequenceNumber(for: actorId)
        #expect(sequence == 1)

        // Second save - version should be 2
        try await stateStore.save(state, for: actorId)
        sequence = try await stateStore.getSequenceNumber(for: actorId)
        #expect(sequence == 2)

        // Third save - version should be 3
        try await stateStore.save(state, for: actorId)
        sequence = try await stateStore.getSequenceNumber(for: actorId)
        #expect(sequence == 3)

        // Cleanup
        try await LocalStackTestHelpers.cleanupTable("trebuchet-test-state", client: client)
        try await client.shutdown()

    }

    @Test("Delete removes actor state")
    func testDelete() async throws {
        try #require(await LocalStackTestHelpers.isLocalStackAvailable())
        let client = LocalStackTestHelpers.createAWSClient()

        

        let stateStore = LocalStackTestHelpers.createStateStore(client: client)
        let actorId = LocalStackTestHelpers.uniqueActorID()

        // Save state
        let state = TestActorState(name: "test", count: 1)
        try await stateStore.save(state, for: actorId)

        // Verify exists
        var loaded = try await stateStore.load(for: actorId, as: TestActorState.self)
        #expect(loaded != nil)

        // Delete
        try await stateStore.delete(for: actorId)

        // Verify deleted
        loaded = try await stateStore.load(for: actorId, as: TestActorState.self)
        #expect(loaded == nil)

        // Cleanup
        try await LocalStackTestHelpers.cleanupTable("trebuchet-test-state", client: client)
        try await client.shutdown()

    }

    @Test("Exists returns correct boolean")
    func testExists() async throws {
        try #require(await LocalStackTestHelpers.isLocalStackAvailable())
        let client = LocalStackTestHelpers.createAWSClient()

        

        let stateStore = LocalStackTestHelpers.createStateStore(client: client)
        let actorId = LocalStackTestHelpers.uniqueActorID()

        // Should not exist initially
        var exists = try await stateStore.exists(for: actorId)
        #expect(!exists)

        // Save state
        let state = TestActorState(name: "test", count: 1)
        try await stateStore.save(state, for: actorId)

        // Should exist now
        exists = try await stateStore.exists(for: actorId)
        #expect(exists)

        // Delete
        try await stateStore.delete(for: actorId)

        // Should not exist after delete
        exists = try await stateStore.exists(for: actorId)
        #expect(!exists)

        // Cleanup
        try await LocalStackTestHelpers.cleanupTable("trebuchet-test-state", client: client)
        try await client.shutdown()

    }

    @Test("Save with version check succeeds on match")
    func testSaveWithVersionCheckSucceeds() async throws {
        try #require(await LocalStackTestHelpers.isLocalStackAvailable())
        let client = LocalStackTestHelpers.createAWSClient()

        

        let stateStore = LocalStackTestHelpers.createStateStore(client: client)
        let actorId = LocalStackTestHelpers.uniqueActorID()

        // Save initial state (version will be 1)
        let state1 = TestActorState(name: "test", count: 1)
        try await stateStore.save(state1, for: actorId)

        // Save with correct version should succeed
        let state2 = TestActorState(name: "test", count: 2)
        let newVersion = try await stateStore.saveIfVersion(state2, for: actorId, expectedVersion: 1)
        #expect(newVersion == 2)

        // Verify updated state
        let loaded = try await stateStore.load(for: actorId, as: TestActorState.self)
        #expect(loaded != nil)
        #expect(loaded?.count == 2)

        // Cleanup
        try await LocalStackTestHelpers.cleanupTable("trebuchet-test-state", client: client)
        try await client.shutdown()

    }

    @Test("Save with version check fails on mismatch")
    func testSaveWithVersionCheckFails() async throws {
        try #require(await LocalStackTestHelpers.isLocalStackAvailable())
        let client = LocalStackTestHelpers.createAWSClient()

        

        let stateStore = LocalStackTestHelpers.createStateStore(client: client)
        let actorId = LocalStackTestHelpers.uniqueActorID()

        // Save initial state (version will be 1)
        let state1 = TestActorState(name: "test", count: 1)
        try await stateStore.save(state1, for: actorId)

        // Try to save with wrong version (expecting 99 but actual is 1)
        let state2 = TestActorState(name: "test", count: 2)

        do {
            _ = try await stateStore.saveIfVersion(state2, for: actorId, expectedVersion: 99)
            Issue.record("Expected version mismatch error")
        } catch let error as ActorStateError {
            if case .versionConflict(let expected, let actual) = error {
                #expect(expected == 99)
                #expect(actual == 1)
            } else {
                Issue.record("Wrong error type: \(error)")
            }
        }

        // Verify state unchanged
        let loaded = try await stateStore.load(for: actorId, as: TestActorState.self)
        #expect(loaded?.count == 1)

        // Cleanup
        try await LocalStackTestHelpers.cleanupTable("trebuchet-test-state", client: client)
        try await client.shutdown()

    }

    @Test("Concurrent saves to different actors")
    func testConcurrentSaves() async throws {
        try #require(await LocalStackTestHelpers.isLocalStackAvailable())
        let client = LocalStackTestHelpers.createAWSClient()

        

        let stateStore = LocalStackTestHelpers.createStateStore(client: client)

        // Create 10 concurrent save operations for different actors
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    let actorId = LocalStackTestHelpers.uniqueActorID(prefix: "concurrent-\(i)")
                    let state = TestActorState(name: "test-\(i)", count: i)
                    try! await stateStore.save(state, for: actorId)
                }
            }
        }

        // Cleanup
        try await LocalStackTestHelpers.cleanupTable("trebuchet-test-state", client: client)
        try await client.shutdown()

    }

    @Test("Update with transform function")
    func testUpdateWithTransform() async throws {
        try #require(await LocalStackTestHelpers.isLocalStackAvailable())
        let client = LocalStackTestHelpers.createAWSClient()

        

        let stateStore = LocalStackTestHelpers.createStateStore(client: client)
        let actorId = LocalStackTestHelpers.uniqueActorID()

        // Save initial state
        let state1 = TestActorState(name: "test", count: 10)
        try await stateStore.save(state1, for: actorId)

        // Update by incrementing counter
        let updated = try await stateStore.update(for: actorId, as: TestActorState.self) { current in
            guard let current = current else {
                return TestActorState(name: "test", count: 0)
            }
            return TestActorState(name: current.name, count: current.count + 5)
        }

        // Verify updated state
        #expect(updated.count == 15)

        let loaded = try await stateStore.load(for: actorId, as: TestActorState.self)
        #expect(loaded?.count == 15)

        // Cleanup
        try await LocalStackTestHelpers.cleanupTable("trebuchet-test-state", client: client)
        try await client.shutdown()

    }

    @Test("Load returns nil for non-existent actor")
    func testLoadNonExistent() async throws {
        try #require(await LocalStackTestHelpers.isLocalStackAvailable())
        let client = LocalStackTestHelpers.createAWSClient()



        let stateStore = LocalStackTestHelpers.createStateStore(client: client)
        let actorId = LocalStackTestHelpers.uniqueActorID()

        let loaded = try await stateStore.load(for: actorId, as: TestActorState.self)
        #expect(loaded == nil)

        try await client.shutdown()
    }
}

// MARK: - Test Types

struct TestActorState: Codable, Sendable {
    let name: String
    let count: Int
}
