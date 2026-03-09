import Testing
import Foundation
@testable import TrebuchetSQLite

@Suite("MaglevHasher Tests")
struct MaglevHasherTests {

    @Test("Same key always maps to same shard (determinism)")
    func determinism() {
        let hasher = MaglevHasher(shardNames: ["shard-0000", "shard-0001", "shard-0002", "shard-0003"])

        for key in ["actor-1", "player-42", "lobby-main", "room-xyz"] {
            let first = hasher.shardIndex(for: key)
            let second = hasher.shardIndex(for: key)
            #expect(first == second, "Key '\(key)' should always map to the same shard")
        }
    }

    @Test("Reconstructed hasher produces identical results")
    func reconstructionDeterminism() {
        let names = ["shard-0000", "shard-0001", "shard-0002", "shard-0003"]
        let hasher1 = MaglevHasher(shardNames: names)
        let hasher2 = MaglevHasher(shardNames: names)

        for i in 0..<1000 {
            let key = "actor-\(i)"
            #expect(hasher1.shardIndex(for: key) == hasher2.shardIndex(for: key))
        }
    }

    @Test("Distribution is roughly uniform across shards")
    func distribution() {
        let shardCount = 8
        let names = (0..<shardCount).map { "shard-\(String(format: "%04d", $0))" }
        let hasher = MaglevHasher(shardNames: names)

        var counts = [Int](repeating: 0, count: shardCount)
        let keyCount = 100_000
        for i in 0..<keyCount {
            let shard = hasher.shardIndex(for: "key-\(i)")
            counts[shard] += 1
        }

        // Chi-squared test for uniformity
        let expected = Double(keyCount) / Double(shardCount)
        var chiSquared = 0.0
        for count in counts {
            let diff = Double(count) - expected
            chiSquared += (diff * diff) / expected
        }

        // Critical value for chi-squared with 7 df at p=0.01 is ~18.48
        // We use a generous threshold to avoid flaky tests
        #expect(chiSquared < 30.0, "Distribution should be roughly uniform (chi-squared: \(chiSquared))")

        // Each shard should have at least some keys
        for (i, count) in counts.enumerated() {
            #expect(count > 0, "Shard \(i) should have at least one key")
        }
    }

    @Test("Minimal disruption when adding a shard (4 -> 5)")
    func minimalDisruption4to5() {
        let oldNames = (0..<4).map { "shard-\(String(format: "%04d", $0))" }
        let newNames = (0..<5).map { "shard-\(String(format: "%04d", $0))" }
        let oldHasher = MaglevHasher(shardNames: oldNames)
        let newHasher = MaglevHasher(shardNames: newNames)

        let keyCount = 10_000
        var remapped = 0
        for i in 0..<keyCount {
            let key = "actor-\(i)"
            if oldHasher.shardIndex(for: key) != newHasher.shardIndex(for: key) {
                remapped += 1
            }
        }

        let remapRatio = Double(remapped) / Double(keyCount)
        // Ideal is ~1/5 = 20%. Allow up to 30%.
        #expect(remapRatio < 0.30, "Maglev should remap <30% of keys (got \(Int(remapRatio * 100))%)")
        // Should remap at least some keys (the new shard needs to get keys)
        #expect(remapRatio > 0.10, "Should remap at least 10% of keys (got \(Int(remapRatio * 100))%)")
    }

    @Test("Modulo remaps much more than Maglev (comparison)")
    func moduloVsMaglev() {
        let keyCount = 10_000
        let oldCount = 4
        let newCount = 5

        // Modulo remapping
        var moduloRemapped = 0
        for i in 0..<keyCount {
            let key = "actor-\(i)"
            let hash = SQLiteShardManager.fnv1a(key)
            let oldShard = Int(hash % UInt64(oldCount))
            let newShard = Int(hash % UInt64(newCount))
            if oldShard != newShard {
                moduloRemapped += 1
            }
        }

        // Maglev remapping
        let oldNames = (0..<oldCount).map { "shard-\(String(format: "%04d", $0))" }
        let newNames = (0..<newCount).map { "shard-\(String(format: "%04d", $0))" }
        let oldHasher = MaglevHasher(shardNames: oldNames)
        let newHasher = MaglevHasher(shardNames: newNames)

        var maglevRemapped = 0
        for i in 0..<keyCount {
            let key = "actor-\(i)"
            if oldHasher.shardIndex(for: key) != newHasher.shardIndex(for: key) {
                maglevRemapped += 1
            }
        }

        let moduloRatio = Double(moduloRemapped) / Double(keyCount)
        let maglevRatio = Double(maglevRemapped) / Double(keyCount)

        // Maglev should be significantly better
        #expect(maglevRatio < moduloRatio, "Maglev (\(Int(maglevRatio * 100))%) should remap fewer keys than modulo (\(Int(moduloRatio * 100))%)")
    }

    @Test("Single shard produces all zeros")
    func singleShard() {
        let hasher = MaglevHasher(shardNames: ["shard-0000"])
        for i in 0..<100 {
            #expect(hasher.shardIndex(for: "key-\(i)") == 0)
        }
    }

    @Test("Lookup table has correct size")
    func tableSize() {
        let hasher = MaglevHasher(shardNames: ["a", "b", "c"], tableSize: 97)
        #expect(hasher.lookupTable.count == 97)
        #expect(hasher.tableSize == 97)
    }

    @Test("DJB2 hash is deterministic")
    func djb2Determinism() {
        let h1 = MaglevHasher.djb2("test-string")
        let h2 = MaglevHasher.djb2("test-string")
        #expect(h1 == h2)
        #expect(h1 != 0)

        // Different strings should (very likely) produce different hashes
        let h3 = MaglevHasher.djb2("other-string")
        #expect(h1 != h3)
    }
}
