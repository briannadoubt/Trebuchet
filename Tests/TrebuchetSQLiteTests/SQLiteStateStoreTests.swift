import Testing
import Foundation
@testable import TrebuchetSQLite

struct TestState: Codable, Sendable, Equatable {
    var name: String
    var count: Int
}

@Suite("SQLiteStateStore Tests")
struct SQLiteStateStoreTests {

    @Test("Save and load state")
    func saveAndLoad() async throws {
        let store = try await SQLiteStateStore()
        let state = TestState(name: "test", count: 42)

        try await store.save(state, for: "actor-1")
        let loaded = try await store.load(for: "actor-1", as: TestState.self)

        #expect(loaded == state)
    }

    @Test("Load returns nil for missing actor")
    func loadMissing() async throws {
        let store = try await SQLiteStateStore()
        let loaded = try await store.load(for: "nonexistent", as: TestState.self)
        #expect(loaded == nil)
    }

    @Test("Exists check")
    func existsCheck() async throws {
        let store = try await SQLiteStateStore()

        #expect(try await store.exists(for: "actor-1") == false)

        try await store.save(TestState(name: "test", count: 1), for: "actor-1")
        #expect(try await store.exists(for: "actor-1") == true)
    }

    @Test("Delete state")
    func deleteState() async throws {
        let store = try await SQLiteStateStore()

        try await store.save(TestState(name: "test", count: 1), for: "actor-1")
        #expect(try await store.exists(for: "actor-1") == true)

        try await store.delete(for: "actor-1")
        #expect(try await store.exists(for: "actor-1") == false)
    }

    @Test("Sequence number increments on save")
    func sequenceNumberIncrements() async throws {
        let store = try await SQLiteStateStore()

        try await store.save(TestState(name: "v1", count: 1), for: "actor-1")
        let seq1 = try await store.getSequenceNumber(for: "actor-1")
        #expect(seq1 == 1)

        try await store.save(TestState(name: "v2", count: 2), for: "actor-1")
        let seq2 = try await store.getSequenceNumber(for: "actor-1")
        #expect(seq2 == 2)
    }

    @Test("Save if version succeeds with correct version")
    func saveIfVersionSuccess() async throws {
        let store = try await SQLiteStateStore()

        // First save creates version 1
        try await store.save(TestState(name: "v1", count: 1), for: "actor-1")

        // Save with expected version 1 should succeed and return 2
        let newVersion = try await store.saveIfVersion(
            TestState(name: "v2", count: 2),
            for: "actor-1",
            expectedVersion: 1
        )
        #expect(newVersion == 2)
    }

    @Test("Save if version fails with wrong version")
    func saveIfVersionConflict() async throws {
        let store = try await SQLiteStateStore()

        try await store.save(TestState(name: "v1", count: 1), for: "actor-1")
        try await store.save(TestState(name: "v2", count: 2), for: "actor-1")

        // Current version is 2, but we expect 1
        await #expect(throws: ActorStateError.self) {
            _ = try await store.saveIfVersion(
                TestState(name: "v3", count: 3),
                for: "actor-1",
                expectedVersion: 1
            )
        }
    }

    @Test("Update with transform")
    func updateTransform() async throws {
        let store = try await SQLiteStateStore()

        try await store.save(TestState(name: "initial", count: 0), for: "actor-1")

        let result = try await store.update(for: "actor-1", as: TestState.self) { current in
            var next = current!
            next.count += 1
            return next
        }

        #expect(result.count == 1)
    }

    @Test("Multiple actors don't interfere")
    func multipleActors() async throws {
        let store = try await SQLiteStateStore()

        try await store.save(TestState(name: "actor1", count: 1), for: "actor-1")
        try await store.save(TestState(name: "actor2", count: 2), for: "actor-2")

        let loaded1 = try await store.load(for: "actor-1", as: TestState.self)
        let loaded2 = try await store.load(for: "actor-2", as: TestState.self)

        #expect(loaded1?.name == "actor1")
        #expect(loaded2?.name == "actor2")
    }

    @Test("Direct pool access for custom queries")
    func directPoolAccess() async throws {
        let store = try await SQLiteStateStore()

        // Create a custom table using the pool directly
        try await store.pool.write { db in
            try db.create(table: "messages", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("conversationId", .text).notNull()
                t.column("content", .text).notNull()
                t.column("timestamp", .integer).notNull()
            }

            try db.execute(sql: """
                INSERT INTO messages (conversationId, content, timestamp) VALUES (?, ?, ?)
                """, arguments: ["conv-1", "Hello!", Int(Date().timeIntervalSince1970)])
        }

        let count = try await store.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages")
        }

        #expect(count == 1)
    }
}

@Suite("SQLiteShardManager Tests")
struct SQLiteShardManagerTests {

    @Test("Deterministic shard assignment")
    func shardAssignment() async throws {
        let config = SQLiteStorageConfiguration(root: NSTemporaryDirectory() + "trebuchet-test-\(UUID().uuidString)", shardCount: 4)
        let manager = SQLiteShardManager(configuration: config)

        // Same key always maps to same shard
        let shard1 = await manager.shardID(for: "conversation-123")
        let shard2 = await manager.shardID(for: "conversation-123")
        #expect(shard1 == shard2)

        // Shard ID is within bounds
        #expect(shard1 >= 0 && shard1 < 4)
    }

    @Test("Initialize creates directory structure")
    func initializeDirectoryStructure() async throws {
        let root = NSTemporaryDirectory() + "trebuchet-test-\(UUID().uuidString)"
        let config = SQLiteStorageConfiguration(root: root, shardCount: 2)
        let manager = SQLiteShardManager(configuration: config)

        try await manager.initialize()

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: "\(root)/shards/shard-0000"))
        #expect(fm.fileExists(atPath: "\(root)/shards/shard-0001"))
        #expect(fm.fileExists(atPath: "\(root)/metadata"))

        // Cleanup
        try? fm.removeItem(atPath: root)
    }

    @Test("Open and close shards")
    func openCloseShard() async throws {
        let root = NSTemporaryDirectory() + "trebuchet-test-\(UUID().uuidString)"
        let config = SQLiteStorageConfiguration(root: root, shardCount: 2)
        let manager = SQLiteShardManager(configuration: config)

        try await manager.initialize()

        let pool = try await manager.openShard(0)
        // Pool should be usable
        try await pool.write { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS test (id INTEGER PRIMARY KEY)")
        }

        await manager.closeShard(0)
        await manager.shutdown()

        // Cleanup
        try? FileManager.default.removeItem(atPath: root)
    }
}
