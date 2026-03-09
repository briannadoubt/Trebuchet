import Testing
import Foundation
@testable import TrebuchetSQLite

@Suite("MaglevHasher Routing Tests")
struct RoutingStrategyTests {

    @Test("MaglevHasher deterministic")
    func maglevDeterministic() {
        let names = (0..<4).map { "shard-\(String(format: "%04d", $0))" }
        let hasher = MaglevHasher(shardNames: names, tableSize: 997)
        let key = "test-actor"
        #expect(hasher.shardIndex(for: key) == hasher.shardIndex(for: key))
    }

    @Test("MaglevHasher stays in range")
    func maglevRange() {
        let shardCount = 6
        let names = (0..<shardCount).map { "shard-\(String(format: "%04d", $0))" }
        let hasher = MaglevHasher(shardNames: names, tableSize: 997)
        for i in 0..<1000 {
            let shard = hasher.shardIndex(for: "key-\(i)")
            #expect(shard >= 0 && shard < shardCount)
        }
    }

    @Test("Single shard routes everything to shard 0")
    func singleShard() {
        let hasher = MaglevHasher(shardNames: ["shard-0000"], tableSize: 997)
        for i in 0..<100 {
            let key = "actor-\(i)"
            #expect(hasher.shardIndex(for: key) == 0)
        }
    }

    @Test("ShardedStateStore works with maglev routing")
    func shardedStoreWithMaglev() async throws {
        let root = NSTemporaryDirectory() + "trebuchet-maglev-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }

        let config = SQLiteStorageConfiguration(root: root, shardCount: 4)
        let manager = SQLiteShardManager(configuration: config)
        try await manager.initialize()
        let store = await ShardedStateStore(shardManager: manager)

        // Save and load through maglev routing
        let state = TestState(name: "maglev-test", count: 7)
        try await store.save(state, for: "actor-maglev")
        let loaded = try await store.load(for: "actor-maglev", as: TestState.self)
        #expect(loaded == state)
    }
}
