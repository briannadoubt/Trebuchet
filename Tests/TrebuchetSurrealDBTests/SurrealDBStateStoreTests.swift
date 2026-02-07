import Testing
import Foundation
import SurrealDB
@testable import TrebuchetSurrealDB
@testable import TrebuchetCloud

@Suite("SurrealDB State Store Tests")
struct SurrealDBStateStoreTests {

    @Test("Save and load actor state")
    func testSaveAndLoad() async throws {
        guard await SurrealDBTestHelpers.isSurrealDBAvailable() else {
            print("⏭️  Skipping: SurrealDB not available. Start with: docker-compose -f docker-compose.surrealdb.yml up -d")
            return
        }

        let stateStore = try await SurrealDBTestHelpers.createStateStore()

        let actorId = SurrealDBTestHelpers.uniqueActorID()

        // Save state
        let state = TestActorState(name: "TestActor", count: 42)
        try await stateStore.save(state, for: actorId)

        // Load state
        let loaded = try await stateStore.load(for: actorId, as: TestActorState.self)
        #expect(loaded != nil)
        #expect(loaded?.name == "TestActor")
        #expect(loaded?.count == 42)

        await stateStore.shutdown()
    }

    @Test("Sequence numbers auto-increment")
    func testSequenceNumbersAutoIncrement() async throws {
        guard await SurrealDBTestHelpers.isSurrealDBAvailable() else {
            print("⏭️  Skipping: SurrealDB not available. Start with: docker-compose -f docker-compose.surrealdb.yml up -d")
            return
        }

        let stateStore = try await SurrealDBTestHelpers.createStateStore()

        let actorId = SurrealDBTestHelpers.uniqueActorID()
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

        await stateStore.shutdown()
    }

    @Test("Delete removes actor state")
    func testDelete() async throws {
        guard await SurrealDBTestHelpers.isSurrealDBAvailable() else {
            print("⏭️  Skipping: SurrealDB not available. Start with: docker-compose -f docker-compose.surrealdb.yml up -d")
            return
        }

        let stateStore = try await SurrealDBTestHelpers.createStateStore()

        let actorId = SurrealDBTestHelpers.uniqueActorID()

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

        await stateStore.shutdown()
    }

    @Test("Exists returns correct boolean")
    func testExists() async throws {
        guard await SurrealDBTestHelpers.isSurrealDBAvailable() else {
            print("⏭️  Skipping: SurrealDB not available. Start with: docker-compose -f docker-compose.surrealdb.yml up -d")
            return
        }

        let stateStore = try await SurrealDBTestHelpers.createStateStore()

        let actorId = SurrealDBTestHelpers.uniqueActorID()

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

        await stateStore.shutdown()
    }

    @Test("Save with version check succeeds on match")
    func testSaveWithVersionCheckSucceeds() async throws {
        guard await SurrealDBTestHelpers.isSurrealDBAvailable() else {
            print("⏭️  Skipping: SurrealDB not available. Start with: docker-compose -f docker-compose.surrealdb.yml up -d")
            return
        }

        let stateStore = try await SurrealDBTestHelpers.createStateStore()

        let actorId = SurrealDBTestHelpers.uniqueActorID()

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

        await stateStore.shutdown()
    }

    @Test("Save with version check fails on mismatch")
    func testSaveWithVersionCheckFails() async throws {
        guard await SurrealDBTestHelpers.isSurrealDBAvailable() else {
            print("⏭️  Skipping: SurrealDB not available. Start with: docker-compose -f docker-compose.surrealdb.yml up -d")
            return
        }

        let stateStore = try await SurrealDBTestHelpers.createStateStore()

        let actorId = SurrealDBTestHelpers.uniqueActorID()

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

        await stateStore.shutdown()
    }

    @Test("Concurrent saves to different actors")
    func testConcurrentSaves() async throws {
        guard await SurrealDBTestHelpers.isSurrealDBAvailable() else {
            print("⏭️  Skipping: SurrealDB not available. Start with: docker-compose -f docker-compose.surrealdb.yml up -d")
            return
        }

        let stateStore = try await SurrealDBTestHelpers.createStateStore()

        // Create 10 concurrent save operations for different actors
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    let actorId = SurrealDBTestHelpers.uniqueActorID(prefix: "concurrent-\(i)")
                    let state = TestActorState(name: "test-\(i)", count: i)
                    try! await stateStore.save(state, for: actorId)
                }
            }
        }

        // Verify all saves succeeded by checking they exist
        for i in 0..<10 {
            let actorId = SurrealDBTestHelpers.uniqueActorID(prefix: "concurrent-\(i)")
            // Note: We can't verify exact state since actor IDs are unique each time
            // This test mainly verifies no crashes occur during concurrent operations
        }

        await stateStore.shutdown()
    }

    @Test("Update with transform function")
    func testUpdateWithTransform() async throws {
        guard await SurrealDBTestHelpers.isSurrealDBAvailable() else {
            print("⏭️  Skipping: SurrealDB not available. Start with: docker-compose -f docker-compose.surrealdb.yml up -d")
            return
        }

        let stateStore = try await SurrealDBTestHelpers.createStateStore()

        let actorId = SurrealDBTestHelpers.uniqueActorID()

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

        await stateStore.shutdown()
    }

    @Test("Load returns nil for non-existent actor")
    func testLoadNonExistent() async throws {
        guard await SurrealDBTestHelpers.isSurrealDBAvailable() else {
            print("⏭️  Skipping: SurrealDB not available. Start with: docker-compose -f docker-compose.surrealdb.yml up -d")
            return
        }

        let stateStore = try await SurrealDBTestHelpers.createStateStore()

        let actorId = SurrealDBTestHelpers.uniqueActorID()

        let loaded = try await stateStore.load(for: actorId, as: TestActorState.self)
        #expect(loaded == nil)

        await stateStore.shutdown()
    }

    @Test("Save and load complex state with nested data")
    func testComplexState() async throws {
        guard await SurrealDBTestHelpers.isSurrealDBAvailable() else {
            print("⏭️  Skipping: SurrealDB not available. Start with: docker-compose -f docker-compose.surrealdb.yml up -d")
            return
        }

        let stateStore = try await SurrealDBTestHelpers.createStateStore()

        let actorId = SurrealDBTestHelpers.uniqueActorID()

        // Save complex state
        let state = ComplexState(
            id: UUID().uuidString,
            values: [1, 2, 3, 4, 5],
            metadata: ["key1": "value1", "key2": "value2"],
            timestamp: Date()
        )
        try await stateStore.save(state, for: actorId)

        // Load and verify
        let loaded = try await stateStore.load(for: actorId, as: ComplexState.self)
        #expect(loaded != nil)
        #expect(loaded?.id == state.id)
        #expect(loaded?.values == state.values)
        #expect(loaded?.metadata == state.metadata)
        // Note: Date comparison might have slight differences due to serialization
        #expect(loaded?.timestamp.timeIntervalSince1970 ?? 0 >= state.timestamp.timeIntervalSince1970 - 1)

        await stateStore.shutdown()
    }

    @Test("Concurrent updates to same actor with version check")
    func testConcurrentUpdatesWithVersioning() async throws {
        guard await SurrealDBTestHelpers.isSurrealDBAvailable() else {
            print("⏭️  Skipping: SurrealDB not available. Start with: docker-compose -f docker-compose.surrealdb.yml up -d")
            return
        }

        let stateStore = try await SurrealDBTestHelpers.createStateStore()

        let actorId = SurrealDBTestHelpers.uniqueActorID()

        // Save initial state
        let state = TestActorState(name: "test", count: 0)
        try await stateStore.save(state, for: actorId)

        // Attempt concurrent updates
        var successCount = 0
        var failureCount = 0

        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<5 {
                group.addTask {
                    do {
                        let state = TestActorState(name: "test", count: i)
                        _ = try await stateStore.saveIfVersion(state, for: actorId, expectedVersion: 1)
                        return true
                    } catch {
                        return false
                    }
                }
            }

            for await result in group {
                if result {
                    successCount += 1
                } else {
                    failureCount += 1
                }
            }
        }

        // Only one should succeed, rest should fail due to version conflict
        #expect(successCount == 1)
        #expect(failureCount == 4)

        // Final version should be 2
        let finalVersion = try await stateStore.getSequenceNumber(for: actorId)
        #expect(finalVersion == 2)

        await stateStore.shutdown()
    }
}
