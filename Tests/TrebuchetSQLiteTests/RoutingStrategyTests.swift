import Testing
import Foundation
@testable import TrebuchetSQLite

@Suite("ShardRoutingStrategy Tests")
struct RoutingStrategyTests {

    @Test("ModuloRouting matches legacy fnv1a % shardCount")
    func moduloRegression() {
        let shardCount = 4
        let routing = ModuloRouting(shardCount: shardCount)

        for i in 0..<1000 {
            let key = "actor-\(i)"
            let expected = Int(SQLiteShardManager.fnv1a(key) % UInt64(shardCount))
            let actual = routing.shardID(for: key)
            #expect(actual == expected, "ModuloRouting should match inline fnv1a for key '\(key)'")
        }
    }

    @Test("ModuloRouting deterministic")
    func moduloDeterministic() {
        let routing = ModuloRouting(shardCount: 8)
        let key = "test-actor"
        #expect(routing.shardID(for: key) == routing.shardID(for: key))
    }

    @Test("MaglevRouting deterministic")
    func maglevDeterministic() {
        let routing = MaglevRouting(shardCount: 4)
        let key = "test-actor"
        #expect(routing.shardID(for: key) == routing.shardID(for: key))
    }

    @Test("MaglevRouting stays in range")
    func maglevRange() {
        let shardCount = 6
        let routing = MaglevRouting(shardCount: shardCount)
        for i in 0..<1000 {
            let shard = routing.shardID(for: "key-\(i)")
            #expect(shard >= 0 && shard < shardCount)
        }
    }

    @Test("Single shard routes everything to shard 0")
    func singleShardBothStrategies() {
        let modulo = ModuloRouting(shardCount: 1)
        let maglev = MaglevRouting(shardCount: 1)

        for i in 0..<100 {
            let key = "actor-\(i)"
            #expect(modulo.shardID(for: key) == 0)
            #expect(maglev.shardID(for: key) == 0)
        }
    }

    @Test("RoutingMode persisted name round-trips")
    func routingModePersistence() {
        #expect(RoutingMode.modulo.persistedName == "modulo")
        #expect(RoutingMode.maglev().persistedName == "maglev")
        #expect(RoutingMode.maglev(tableSize: 997).persistedName == "maglev")

        #expect(RoutingMode.from(persistedName: nil) == .modulo)
        #expect(RoutingMode.from(persistedName: "modulo") == .modulo)
        #expect(RoutingMode.from(persistedName: "maglev") == .maglev())
        #expect(RoutingMode.from(persistedName: "unknown") == .modulo)
    }

    @Test("ShardedStateStore works with maglev routing")
    func shardedStoreWithMaglev() async throws {
        let root = NSTemporaryDirectory() + "trebuchet-maglev-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }

        let config = SQLiteStorageConfiguration(root: root, shardCount: 4, routing: .maglev(tableSize: 997))
        let manager = SQLiteShardManager(configuration: config)
        try await manager.initialize()
        let store = await ShardedStateStore(shardManager: manager)

        // Save and load through maglev routing
        let state = TestState(name: "maglev-test", count: 7)
        try await store.save(state, for: "actor-maglev")
        let loaded = try await store.load(for: "actor-maglev", as: TestState.self)
        #expect(loaded == state)
    }

    @Test("ShardedStateStore works with modulo routing")
    func shardedStoreWithModulo() async throws {
        let root = NSTemporaryDirectory() + "trebuchet-modulo-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }

        let config = SQLiteStorageConfiguration(root: root, shardCount: 4, routing: .modulo)
        let manager = SQLiteShardManager(configuration: config)
        try await manager.initialize()
        let store = await ShardedStateStore(shardManager: manager)

        let state = TestState(name: "modulo-test", count: 3)
        try await store.save(state, for: "actor-modulo")
        let loaded = try await store.load(for: "actor-modulo", as: TestState.self)
        #expect(loaded == state)
    }

    @Test("SQLiteShardManager uses configured routing strategy")
    func managerUsesConfiguredStrategy() async throws {
        let root = NSTemporaryDirectory() + "trebuchet-routing-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }

        let moduloConfig = SQLiteStorageConfiguration(root: root + "/modulo", shardCount: 4, routing: .modulo)
        let moduloManager = SQLiteShardManager(configuration: moduloConfig)

        let maglevConfig = SQLiteStorageConfiguration(root: root + "/maglev", shardCount: 4, routing: .maglev())
        let maglevManager = SQLiteShardManager(configuration: maglevConfig)

        // They should produce the same type of routing
        let moduloStrategy = await moduloManager.routingStrategy
        let maglevStrategy = await maglevManager.routingStrategy

        #expect(moduloStrategy is ModuloRouting)
        #expect(maglevStrategy is MaglevRouting)
    }
}
