import Testing
import Foundation
@testable import Trebuchet
@testable import TrebuchetCloud

@Suite("State Versioning Tests")
struct StateVersioningTests {
    // MARK: - Optimistic Locking Tests

    @Test("InMemory store: concurrent writes throw version conflict")
    func inMemoryConcurrentWriteConflict() async throws {
        let store = InMemoryStateStore()

        // Save initial state
        try await store.save("initial", for: "actor-1")

        // Load with version
        let snapshot1 = try await store.loadWithVersion(for: "actor-1", as: String.self)
        #expect(snapshot1?.state == "initial")
        #expect(snapshot1?.version == 1)

        // Load again (simulating concurrent access)
        let snapshot2 = try await store.loadWithVersion(for: "actor-1", as: String.self)
        #expect(snapshot2?.version == 1)

        // First write succeeds
        let newVersion1 = try await store.saveIfVersion(
            "update-1",
            for: "actor-1",
            expectedVersion: 1
        )
        #expect(newVersion1 == 2)

        // Second write with same version fails
        do {
            _ = try await store.saveIfVersion(
                "update-2",
                for: "actor-1",
                expectedVersion: 1
            )
            Issue.record("Expected version conflict error")
        } catch let error as ActorStateError {
            if case .versionConflict(let expected, let actual) = error {
                #expect(expected == 1)
                #expect(actual == 2)
            } else {
                Issue.record("Wrong error type: \(error)")
            }
        }

        // Verify final state is from first write
        let final = try await store.load(for: "actor-1", as: String.self)
        #expect(final == "update-1")
    }

    @Test("InMemory store: new actor starts at version 0")
    func inMemoryNewActorVersion() async throws {
        let store = InMemoryStateStore()

        // Save with version 0 (new actor)
        let version = try await store.saveIfVersion(
            "initial",
            for: "new-actor",
            expectedVersion: 0
        )
        #expect(version == 1)

        // Trying to save again with version 0 fails
        do {
            _ = try await store.saveIfVersion(
                "duplicate",
                for: "new-actor",
                expectedVersion: 0
            )
            Issue.record("Expected version conflict")
        } catch ActorStateError.versionConflict {
            // Expected
        }
    }

    @Test("InMemory store: updateWithRetry succeeds with automatic retry")
    func inMemoryUpdateWithRetry() async throws {
        let store = InMemoryStateStore()

        try await store.save(0, for: "counter")

        // First update
        let result1 = try await store.updateWithRetry(for: "counter", as: Int.self) { current in
            return (current ?? 0) + 1
        }
        #expect(result1 == 1)

        // Second update (sequential to guarantee no conflicts)
        let result2 = try await store.updateWithRetry(for: "counter", as: Int.self) { current in
            return (current ?? 0) + 1
        }
        #expect(result2 == 2)

        // Verify final state
        let finalState = try await store.load(for: "counter", as: Int.self)
        #expect(finalState == 2)
    }

    @Test("ActorStateError cases exist")
    func actorStateErrorCases() {
        // Verify error types can be pattern matched
        let versionConflict = ActorStateError.versionConflict(expected: 1, actual: 2)

        switch versionConflict {
        case .versionConflict(let expected, let actual):
            #expect(expected == 1)
            #expect(actual == 2)
        default:
            Issue.record("Should be version conflict")
        }

        let maxRetries = ActorStateError.maxRetriesExceeded
        if case .maxRetriesExceeded = maxRetries {
            // Expected
        } else {
            Issue.record("Should be maxRetriesExceeded")
        }
    }

    // MARK: - State Updater Tests

    @Test("StateUpdater: convenient wrapper for updates")
    func stateUpdaterUsage() async throws {
        let store = InMemoryStateStore()
        let updater = StateUpdater<String>(store: store, actorID: "test-actor")

        // Initial update
        let state1 = try await updater.update { _ in
            return "first"
        }
        #expect(state1 == "first")

        // Subsequent update
        let state2 = try await updater.update { current in
            return (current ?? "") + "-second"
        }
        #expect(state2 == "first-second")
    }

    // MARK: - Sequence Number Tests

    @Test("InMemory store: sequence numbers increment correctly")
    func sequenceNumberProgression() async throws {
        let store = InMemoryStateStore()

        #expect(try await store.getSequenceNumber(for: "actor-1") == nil)

        try await store.save("state1", for: "actor-1")
        #expect(try await store.getSequenceNumber(for: "actor-1") == 1)

        try await store.save("state2", for: "actor-1")
        #expect(try await store.getSequenceNumber(for: "actor-1") == 2)

        try await store.save("state3", for: "actor-1")
        #expect(try await store.getSequenceNumber(for: "actor-1") == 3)
    }

    @Test("InMemory store: loadWithVersion returns correct snapshot")
    func loadWithVersionSnapshot() async throws {
        let store = InMemoryStateStore()

        try await store.save("data", for: "actor-1")

        let snapshot = try await store.loadWithVersion(for: "actor-1", as: String.self)
        #expect(snapshot != nil)
        #expect(snapshot?.state == "data")
        #expect(snapshot?.version == 1)
        #expect(snapshot?.actorID == "actor-1")
    }

    // MARK: - Complex State Tests

    struct ComplexState: Codable, Sendable, Equatable {
        var counter: Int
        var name: String
        var items: [String]
    }

    @Test("Complex state: sequential modifications preserve all changes")
    func complexStateSequentialModifications() async throws {
        let store = InMemoryStateStore()

        let initial = ComplexState(counter: 0, name: "test", items: [])
        try await store.save(initial, for: "complex")

        // Sequential updates to different fields - all should be preserved
        _ = try await store.updateWithRetry(
            for: "complex",
            as: ComplexState.self
        ) { current in
            var state = current!
            state.counter += 1
            return state
        }

        _ = try await store.updateWithRetry(
            for: "complex",
            as: ComplexState.self
        ) { current in
            var state = current!
            state.items.append("item1")
            return state
        }

        _ = try await store.updateWithRetry(
            for: "complex",
            as: ComplexState.self
        ) { current in
            var state = current!
            state.name = "updated"
            return state
        }

        // All updates should be preserved
        let final = try await store.load(for: "complex", as: ComplexState.self)!
        #expect(final.counter == 1)
        #expect(final.name == "updated")
        #expect(final.items.count == 1)
    }
}
