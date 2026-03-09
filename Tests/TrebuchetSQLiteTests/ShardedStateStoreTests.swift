import Testing
import Foundation
@testable import TrebuchetSQLite

@Suite("ShardedStateStore Tests")
struct ShardedStateStoreTests {

    private func makeStore(shardCount: Int = 4) async throws -> (ShardedStateStore, String) {
        let root = NSTemporaryDirectory() + "trebuchet-sharded-\(UUID().uuidString)"
        let config = SQLiteStorageConfiguration(root: root, shardCount: shardCount)
        let manager = SQLiteShardManager(configuration: config)
        try await manager.initialize()
        let store = ShardedStateStore(shardManager: manager)
        return (store, root)
    }

    @Test("Save and load routes to correct shard")
    func saveAndLoadRouting() async throws {
        let (store, root) = try await makeStore()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let state = TestState(name: "player", count: 42)
        try await store.save(state, for: "player-1")
        let loaded = try await store.load(for: "player-1", as: TestState.self)
        #expect(loaded == state)
    }

    @Test("Different actors can land on different shards")
    func distributionAcrossShards() async throws {
        let (store, root) = try await makeStore(shardCount: 4)
        defer { try? FileManager.default.removeItem(atPath: root) }

        // Save many actors and verify they don't all land on shard 0
        var shardsSeen = Set<Int>()
        for i in 0..<20 {
            let actorID = "actor-\(i)"
            try await store.save(TestState(name: actorID, count: i), for: actorID)
            let shard = await store.shardID(for: actorID)
            shardsSeen.insert(shard)
        }

        // With 20 actors and 4 shards, we should see multiple shards used
        #expect(shardsSeen.count > 1)
    }

    @Test("Same actor ID always routes to same shard")
    func deterministicRouting() async throws {
        let (store, root) = try await makeStore()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let shard1 = await store.shardID(for: "player-42")
        let shard2 = await store.shardID(for: "player-42")
        #expect(shard1 == shard2)
    }

    @Test("Delete only affects the correct shard")
    func deleteIsolation() async throws {
        let (store, root) = try await makeStore()
        defer { try? FileManager.default.removeItem(atPath: root) }

        try await store.save(TestState(name: "a", count: 1), for: "actor-a")
        try await store.save(TestState(name: "b", count: 2), for: "actor-b")

        try await store.delete(for: "actor-a")

        #expect(try await store.exists(for: "actor-a") == false)
        #expect(try await store.exists(for: "actor-b") == true)
    }

    @Test("Sequence numbers work through sharded store")
    func sequenceNumbers() async throws {
        let (store, root) = try await makeStore()
        defer { try? FileManager.default.removeItem(atPath: root) }

        try await store.save(TestState(name: "v1", count: 1), for: "actor-1")
        let seq1 = try await store.getSequenceNumber(for: "actor-1")
        #expect(seq1 == 1)

        try await store.save(TestState(name: "v2", count: 2), for: "actor-1")
        let seq2 = try await store.getSequenceNumber(for: "actor-1")
        #expect(seq2 == 2)
    }

    @Test("saveIfVersion works through sharded store")
    func optimisticLocking() async throws {
        let (store, root) = try await makeStore()
        defer { try? FileManager.default.removeItem(atPath: root) }

        try await store.save(TestState(name: "v1", count: 1), for: "actor-1")

        let newVersion = try await store.saveIfVersion(
            TestState(name: "v2", count: 2),
            for: "actor-1",
            expectedVersion: 1
        )
        #expect(newVersion == 2)

        // Wrong version should fail
        await #expect(throws: ActorStateError.self) {
            _ = try await store.saveIfVersion(
                TestState(name: "v3", count: 3),
                for: "actor-1",
                expectedVersion: 1
            )
        }
    }

    @Test("acrossAllShards collects from every shard")
    func crossShardQuery() async throws {
        let (store, root) = try await makeStore(shardCount: 4)
        defer { try? FileManager.default.removeItem(atPath: root) }

        // Save actors that we know will distribute across shards
        for i in 0..<20 {
            try await store.save(
                TestState(name: "actor-\(i)", count: i),
                for: "actor-\(i)"
            )
        }

        // Fan-out query across all shards
        let allIDs: [String] = try await store.acrossAllShards { pool in
            try await pool.read { db in
                try Row.fetchAll(db, sql: "SELECT actorId FROM actor_state")
                    .map { $0["actorId"] as String }
            }
        }

        #expect(allIDs.count == 20)
    }

    @Test("pool(for:) returns the correct shard's pool")
    func poolForActor() async throws {
        let (store, root) = try await makeStore()
        defer { try? FileManager.default.removeItem(atPath: root) }

        // Save via store, then read via direct pool access
        try await store.save(TestState(name: "direct", count: 99), for: "actor-x")

        let pool = try await store.pool(for: "actor-x")
        let count = try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM actor_state WHERE actorId = ?", arguments: ["actor-x"])
        }
        #expect(count == 1)
    }

    @Test("Update transform works through sharded store")
    func updateTransform() async throws {
        let (store, root) = try await makeStore()
        defer { try? FileManager.default.removeItem(atPath: root) }

        try await store.save(TestState(name: "initial", count: 0), for: "actor-1")

        let result = try await store.update(for: "actor-1", as: TestState.self) { current in
            var next = current!
            next.count += 10
            return next
        }

        #expect(result.count == 10)
    }

    @Test("Single shard mode works as passthrough")
    func singleShardMode() async throws {
        let (store, root) = try await makeStore(shardCount: 1)
        defer { try? FileManager.default.removeItem(atPath: root) }

        // Everything should work with just 1 shard
        try await store.save(TestState(name: "a", count: 1), for: "actor-a")
        try await store.save(TestState(name: "b", count: 2), for: "actor-b")

        let a = try await store.load(for: "actor-a", as: TestState.self)
        let b = try await store.load(for: "actor-b", as: TestState.self)
        #expect(a?.name == "a")
        #expect(b?.name == "b")

        // Both should be on shard 0
        #expect(await store.shardID(for: "actor-a") == 0)
        #expect(await store.shardID(for: "actor-b") == 0)
    }
}
