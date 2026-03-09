import Testing
import Foundation
@testable import TrebuchetSQLite

@Suite("MaglevMigrationPlanner Tests")
struct MaglevMigrationPlannerTests {

    @Test("Diff reports slot changes between shard counts")
    func diffBasic() {
        let planner = MaglevMigrationPlanner(tableSize: 997)
        let diff = planner.diff(oldShardCount: 4, newShardCount: 5)

        #expect(diff.totalSlots == 997)
        #expect(diff.slotsChanged > 0)
        #expect(diff.changeRatio > 0)
        #expect(diff.changeRatio < 0.35)  // Should be around 20%
    }

    @Test("Diff with same shard count reports zero changes")
    func diffSameCount() {
        let planner = MaglevMigrationPlanner(tableSize: 997)
        let diff = planner.diff(oldShardCount: 4, newShardCount: 4)
        #expect(diff.slotsChanged == 0)
        #expect(diff.changeRatio == 0)
    }

    @Test("Actor migration identifies moved actors")
    func actorMigration() {
        let planner = MaglevMigrationPlanner(tableSize: 997)
        let actorIDs = (0..<100).map { "actor-\($0)" }

        let migrations = planner.actorsToMigrate(
            actorIDs: actorIDs,
            oldShardCount: 4,
            newShardCount: 5
        )

        // Should have some migrations but not all
        #expect(migrations.count > 0)
        #expect(migrations.count < 100)

        // Each migration should have different from/to shards
        for m in migrations {
            #expect(m.fromShard != m.toShard)
            #expect(m.fromShard >= 0 && m.fromShard < 4)
            #expect(m.toShard >= 0 && m.toShard < 5)
        }
    }

    @Test("No migrations when shard count is unchanged")
    func noMigrationsWhenUnchanged() {
        let planner = MaglevMigrationPlanner(tableSize: 997)
        let actorIDs = (0..<50).map { "actor-\($0)" }

        let migrations = planner.actorsToMigrate(
            actorIDs: actorIDs,
            oldShardCount: 4,
            newShardCount: 4
        )

        #expect(migrations.isEmpty)
    }

    @Test("Empty actor list produces no migrations")
    func emptyActors() {
        let planner = MaglevMigrationPlanner(tableSize: 997)
        let migrations = planner.actorsToMigrate(
            actorIDs: [],
            oldShardCount: 4,
            newShardCount: 8
        )
        #expect(migrations.isEmpty)
    }

    @Test("Migration ratio matches diff ratio approximately")
    func migrationRatioConsistency() {
        let planner = MaglevMigrationPlanner(tableSize: 65537)
        let actorIDs = (0..<10_000).map { "actor-\($0)" }

        let diff = planner.diff(oldShardCount: 4, newShardCount: 5)
        let migrations = planner.actorsToMigrate(
            actorIDs: actorIDs,
            oldShardCount: 4,
            newShardCount: 5
        )

        let migrationRatio = Double(migrations.count) / Double(actorIDs.count)

        // Migration ratio should be in the same ballpark as slot change ratio
        #expect(abs(migrationRatio - diff.changeRatio) < 0.10,
                "Migration ratio (\(migrationRatio)) should be close to diff ratio (\(diff.changeRatio))")
    }
}
