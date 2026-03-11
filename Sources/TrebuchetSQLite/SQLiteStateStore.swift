import Foundation
import GRDB
import TrebuchetCloud

/// SQLite-backed ActorStateStore using GRDB.
///
/// Stores actor state in a local SQLite database with WAL mode enabled.
/// Each actor's state is serialized as JSON and stored alongside a sequence number
/// for optimistic locking.
public actor SQLiteStateStore: ActorStateStore {
    private let dbPool: DatabasePool
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Initialize with an existing GRDB DatabasePool
    public init(dbPool: DatabasePool) async throws {
        self.dbPool = dbPool
        try await migrate()
    }

    /// Initialize with a file path, creating the database if needed
    public init(path: String) async throws {
        self.dbPool = try SQLiteStorageConfiguration.makeDatabasePool(path: path)
        try await migrate()
    }

    /// Initialize with a temporary database (useful for testing).
    /// Creates a uniquely-named file in the system temp directory.
    public init() async throws {
        let tempPath = NSTemporaryDirectory() + "trebuchet-test-\(UUID().uuidString).sqlite"
        self.dbPool = try SQLiteStorageConfiguration.makeDatabasePool(path: tempPath)
        try await migrate()
    }

    private func migrate() async throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("createActorState") { db in
            try db.create(table: "actor_state", ifNotExists: true) { t in
                t.primaryKey("actorId", .text).notNull()
                t.column("state", .blob).notNull()
                t.column("sequenceNumber", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .integer).notNull()
                t.column("updatedAt", .integer).notNull()
            }
        }

        try migrator.migrate(dbPool)
    }

    // MARK: - ActorStateStore Conformance

    public func load<State: Codable & Sendable>(
        for actorID: String,
        as type: State.Type
    ) async throws -> State? {
        try await dbPool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT state FROM actor_state WHERE actorId = ?
                """, arguments: [actorID]) else {
                return nil
            }
            let data: Data = row["state"]
            return try self.decoder.decode(State.self, from: data)
        }
    }

    public func save<State: Codable & Sendable>(
        _ state: State,
        for actorID: String
    ) async throws {
        let data = try encoder.encode(state)
        let now = Int(Date().timeIntervalSince1970)

        try await dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO actor_state (actorId, state, sequenceNumber, createdAt, updatedAt)
                VALUES (?, ?, 1, ?, ?)
                ON CONFLICT(actorId) DO UPDATE SET
                    state = excluded.state,
                    sequenceNumber = sequenceNumber + 1,
                    updatedAt = excluded.updatedAt
                """, arguments: [actorID, data, now, now])
        }
    }

    public func delete(for actorID: String) async throws {
        try await dbPool.write { db in
            try db.execute(sql: "DELETE FROM actor_state WHERE actorId = ?", arguments: [actorID])
        }
    }

    public func exists(for actorID: String) async throws -> Bool {
        try await dbPool.read { db in
            let count = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM actor_state WHERE actorId = ?
                """, arguments: [actorID])
            return (count ?? 0) > 0
        }
    }

    public func update<State: Codable & Sendable>(
        for actorID: String,
        as type: State.Type,
        transform: @Sendable (State?) async throws -> State
    ) async throws -> State {
        let current = try await load(for: actorID, as: type)
        let new = try await transform(current)
        try await save(new, for: actorID)
        return new
    }

    public func getSequenceNumber(for actorID: String) async throws -> UInt64? {
        try await dbPool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT sequenceNumber FROM actor_state WHERE actorId = ?
                """, arguments: [actorID]) else {
                return nil
            }
            let value: Int64 = row["sequenceNumber"]
            return UInt64(value)
        }
    }

    public nonisolated func saveIfVersion<State: Codable & Sendable>(
        _ state: State,
        for actorID: String,
        expectedVersion: UInt64
    ) async throws -> UInt64 {
        let data = try encoder.encode(state)
        let now = Int(Date().timeIntervalSince1970)

        return try await dbPool.write { db in
            // Atomic compare-and-swap within a single transaction
            let currentRow = try Row.fetchOne(db, sql: """
                SELECT sequenceNumber FROM actor_state WHERE actorId = ?
                """, arguments: [actorID])

            let currentVersion: UInt64 = currentRow.map { UInt64($0["sequenceNumber"] as Int64) } ?? 0

            guard currentVersion == expectedVersion else {
                throw ActorStateError.versionConflict(
                    expected: expectedVersion,
                    actual: currentVersion
                )
            }

            let newVersion = currentVersion + 1

            try db.execute(sql: """
                INSERT INTO actor_state (actorId, state, sequenceNumber, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(actorId) DO UPDATE SET
                    state = excluded.state,
                    sequenceNumber = excluded.sequenceNumber,
                    updatedAt = excluded.updatedAt
                """, arguments: [actorID, data, newVersion, now, now])

            return newVersion
        }
    }

    // MARK: - Direct Database Access

    /// Access the underlying DatabasePool for domain-specific queries.
    /// Use this for custom tables beyond the generic actor state store.
    public nonisolated var pool: DatabasePool { dbPool }
}
