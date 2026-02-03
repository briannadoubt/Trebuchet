import Foundation
import SurrealDB
import TrebuchetCloud
import Logging

// MARK: - SurrealDB State Store

/// Actor state storage using SurrealDB.
///
/// This implementation provides type-safe, ORM-based state persistence with:
/// - Automatic schema generation
/// - Sequence number tracking
/// - Type-safe ORM queries
/// - Transaction support
///
/// ## Database Schema
///
/// The store automatically creates a table for actor states:
///
/// ```surrealql
/// DEFINE TABLE actor_states SCHEMAFULL;
/// DEFINE FIELD actorId ON actor_states TYPE string;
/// DEFINE FIELD state ON actor_states TYPE bytes;
/// DEFINE FIELD sequenceNumber ON actor_states TYPE int;
/// DEFINE FIELD updatedAt ON actor_states TYPE datetime;
/// DEFINE FIELD createdAt ON actor_states TYPE datetime;
/// DEFINE INDEX idx_actor_id ON actor_states FIELDS actorId UNIQUE;
/// ```
///
/// ## Usage
///
/// ```swift
/// let stateStore = try await SurrealDBStateStore(
///     url: "ws://localhost:8000/rpc",
///     namespace: "production",
///     database: "myapp"
/// )
///
/// // Save state
/// try await stateStore.save(myState, for: "actor-123")
///
/// // Load state
/// let state = try await stateStore.load(for: "actor-123", as: MyState.self)
/// ```
///
public actor SurrealDBStateStore: ActorStateStore {
    private let db: SurrealDB
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let tableName: String
    private let logger: Logger

    /// Internal model for actor state storage
    private struct ActorState: SurrealModel {
        var id: RecordID?
        var actorId: String
        var state: Data
        var sequenceNumber: Int
        var updatedAt: Date
        var createdAt: Date

        static var tableName: String { "actor_states" }
    }

    /// Initialize with connection parameters
    ///
    /// - Parameters:
    ///   - url: SurrealDB server URL (e.g., "ws://localhost:8000/rpc")
    ///   - namespace: Namespace to use
    ///   - database: Database to use
    ///   - username: Username for authentication (default: "root")
    ///   - password: Password for authentication (default: "root")
    ///   - tableName: Table name for actor states (default: "actor_states")
    public init(
        url: String,
        namespace: String,
        database: String,
        username: String = "root",
        password: String = "root",
        tableName: String = "actor_states"
    ) async throws {
        self.tableName = tableName
        self.logger = Logger(label: "com.trebuchet.surrealdb")

        // Initialize SurrealDB client
        self.db = try SurrealDB(url: url)

        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601

        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601

        // Connect and authenticate
        try await db.connect()
        try await db.signin(.root(RootAuth(username: username, password: password)))
        try await db.use(namespace: namespace, database: database)

        // Initialize schema
        try await initializeSchema()
    }

    /// Initialize with existing SurrealDB client
    ///
    /// - Parameters:
    ///   - db: Existing SurrealDB client (must be connected and authenticated)
    ///   - tableName: Table name for actor states (default: "actor_states")
    public init(
        db: SurrealDB,
        tableName: String = "actor_states"
    ) async throws {
        self.db = db
        self.tableName = tableName
        self.logger = Logger(label: "com.trebuchet.surrealdb")

        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601

        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601

        // Initialize schema
        try await initializeSchema()
    }

    /// Initialize the database schema
    private func initializeSchema() async throws {
        logger.debug("Initializing SurrealDB schema for table: \(tableName)")

        // Define table as SCHEMAFULL
        let defineTable = """
        DEFINE TABLE \(tableName) SCHEMAFULL;
        """

        // Define fields
        let defineFields = """
        DEFINE FIELD actorId ON \(tableName) TYPE string;
        DEFINE FIELD state ON \(tableName) TYPE bytes;
        DEFINE FIELD sequenceNumber ON \(tableName) TYPE int;
        DEFINE FIELD updatedAt ON \(tableName) TYPE datetime;
        DEFINE FIELD createdAt ON \(tableName) TYPE datetime;
        """

        // Define unique index on actorId
        let defineIndex = """
        DEFINE INDEX idx_actor_id ON \(tableName) FIELDS actorId UNIQUE;
        """

        // Execute schema statements
        let schema = [defineTable, defineFields, defineIndex]
        for statement in schema {
            do {
                _ = try await db.query(statement)
                logger.debug("Executed schema statement successfully")
            } catch {
                // Schema might already exist, which is fine
                logger.debug("Schema statement execution: \(error)")
            }
        }

        logger.debug("Schema initialization complete")
    }

    // MARK: - ActorStateStore Protocol

    public func load<State: Codable & Sendable>(
        for actorID: String,
        as type: State.Type
    ) async throws -> State? {
        logger.debug("Loading state for actor: \(actorID)")

        // Query for the actor state using type-safe query
        let query = "SELECT * FROM \(tableName) WHERE actorId = $actorId LIMIT 1"
        let results = try await db.query(query, variables: ["actorId": .string(actorID)])

        guard let firstResult = results.first,
              case .array(let records) = firstResult,
              let firstRecord = records.first else {
            logger.debug("No state found for actor: \(actorID)")
            return nil
        }

        // Decode the ActorState
        let actorState: ActorState = try firstRecord.decode()

        // Decode the state data
        let state = try decoder.decode(State.self, from: actorState.state)
        logger.debug("Loaded state for actor: \(actorID)")

        return state
    }

    public func save<State: Codable & Sendable>(
        _ state: State,
        for actorID: String
    ) async throws {
        logger.debug("Saving state for actor: \(actorID)")

        let stateData = try encoder.encode(state)
        let now = Date()

        // Check if record exists
        let existingState: ActorState? = try await loadActorState(for: actorID)

        if let existing = existingState, let existingId = existing.id {
            // Update existing record
            let updatedState = ActorState(
                id: existingId,
                actorId: actorID,
                state: stateData,
                sequenceNumber: existing.sequenceNumber + 1,
                updatedAt: now,
                createdAt: existing.createdAt
            )

            let _: ActorState = try await db.update(existingId.toString(), data: updatedState)
            logger.debug("Updated state for actor: \(actorID), sequence: \(updatedState.sequenceNumber)")
        } else {
            // Create new record
            let newState = ActorState(
                id: nil,
                actorId: actorID,
                state: stateData,
                sequenceNumber: 1,
                updatedAt: now,
                createdAt: now
            )

            let _: ActorState = try await db.create(tableName, data: newState)
            logger.debug("Created new state for actor: \(actorID)")
        }
    }

    public func delete(for actorID: String) async throws {
        logger.debug("Deleting state for actor: \(actorID)")

        // Find the record
        guard let actorState: ActorState = try await loadActorState(for: actorID),
              let recordId = actorState.id else {
            logger.debug("No state found to delete for actor: \(actorID)")
            return
        }

        // Delete the record
        try await db.delete(recordId.toString())
        logger.debug("Deleted state for actor: \(actorID)")
    }

    public func exists(for actorID: String) async throws -> Bool {
        logger.debug("Checking existence for actor: \(actorID)")

        let query = "SELECT VALUE id FROM \(tableName) WHERE actorId = $actorId LIMIT 1"
        let results = try await db.query(query, variables: ["actorId": .string(actorID)])

        guard let firstResult = results.first,
              case .array(let records) = firstResult else {
            return false
        }

        return !records.isEmpty
    }

    public func update<State: Codable & Sendable>(
        for actorID: String,
        as type: State.Type,
        transform: @Sendable (State?) async throws -> State
    ) async throws -> State {
        logger.debug("Updating state for actor: \(actorID)")

        // Load current state
        let current = try await load(for: actorID, as: type)

        // Apply transformation
        let newState = try await transform(current)

        // Save and return
        try await save(newState, for: actorID)
        return newState
    }

    // MARK: - Sequence Number Support

    /// Get the current sequence number for an actor
    ///
    /// - Parameter actorID: Actor identifier
    /// - Returns: Current sequence number, or nil if actor doesn't exist
    public func getSequenceNumber(for actorID: String) async throws -> UInt64? {
        logger.debug("Getting sequence number for actor: \(actorID)")

        guard let actorState: ActorState = try await loadActorState(for: actorID) else {
            return nil
        }

        return UInt64(actorState.sequenceNumber)
    }

    /// Save state with explicit sequence number tracking
    ///
    /// - Parameters:
    ///   - state: The state to save
    ///   - actorID: Actor identifier
    ///   - sequenceNumber: Explicit sequence number, or nil to auto-increment
    /// - Returns: The sequence number that was used
    @discardableResult
    public func saveWithSequence<State: Codable & Sendable>(
        _ state: State,
        for actorID: String,
        sequenceNumber: UInt64? = nil
    ) async throws -> UInt64 {
        logger.debug("Saving state with sequence for actor: \(actorID)")

        let stateData = try encoder.encode(state)
        let now = Date()

        if let sequence = sequenceNumber {
            // Use explicit sequence number
            let existingState: ActorState? = try await loadActorState(for: actorID)

            if let existing = existingState, let existingId = existing.id {
                // Update with explicit sequence
                let updatedState = ActorState(
                    id: existingId,
                    actorId: actorID,
                    state: stateData,
                    sequenceNumber: Int(sequence),
                    updatedAt: now,
                    createdAt: existing.createdAt
                )

                let _: ActorState = try await db.update(existingId.toString(), data: updatedState)
            } else {
                // Create with explicit sequence
                let newState = ActorState(
                    id: nil,
                    actorId: actorID,
                    state: stateData,
                    sequenceNumber: Int(sequence),
                    updatedAt: now,
                    createdAt: now
                )

                let _: ActorState = try await db.create(tableName, data: newState)
            }

            return sequence
        } else {
            // Auto-increment sequence number
            let existingState: ActorState? = try await loadActorState(for: actorID)

            let newSequence: UInt64
            if let existing = existingState, let existingId = existing.id {
                newSequence = UInt64(existing.sequenceNumber + 1)
                let updatedState = ActorState(
                    id: existingId,
                    actorId: actorID,
                    state: stateData,
                    sequenceNumber: Int(newSequence),
                    updatedAt: now,
                    createdAt: existing.createdAt
                )

                let _: ActorState = try await db.update(existingId.toString(), data: updatedState)
            } else {
                newSequence = 1
                let newState = ActorState(
                    id: nil,
                    actorId: actorID,
                    state: stateData,
                    sequenceNumber: Int(newSequence),
                    updatedAt: now,
                    createdAt: now
                )

                let _: ActorState = try await db.create(tableName, data: newState)
            }

            logger.debug("Saved state for actor: \(actorID), sequence: \(newSequence)")
            return newSequence
        }
    }

    // MARK: - Optimistic Locking

    /// Save state with version check to prevent concurrent write conflicts
    ///
    /// Uses SurrealDB's query conditions to ensure the version matches before updating.
    /// If the version doesn't match, throws versionConflict.
    ///
    /// - Parameters:
    ///   - state: The state to save
    ///   - actorID: Actor identifier
    ///   - expectedVersion: The version number that must match for the save to succeed
    /// - Returns: The new version number after save
    /// - Throws: ActorStateError.versionConflict if the version doesn't match
    public func saveIfVersion<State: Codable & Sendable>(
        _ state: State,
        for actorID: String,
        expectedVersion: UInt64
    ) async throws -> UInt64 {
        logger.debug("Saving state with version check for actor: \(actorID), expected version: \(expectedVersion)")

        let stateData = try encoder.encode(state)
        let now = Date()

        // For new actors (expectedVersion == 0)
        if expectedVersion == 0 {
            // Verify no existing state
            let existingState: ActorState? = try await loadActorState(for: actorID)
            if existingState != nil {
                let actualVersion = try await getSequenceNumber(for: actorID) ?? 0
                throw ActorStateError.versionConflict(
                    expected: expectedVersion,
                    actual: actualVersion
                )
            }

            // Create new state
            let newState = ActorState(
                id: nil,
                actorId: actorID,
                state: stateData,
                sequenceNumber: 1,
                updatedAt: now,
                createdAt: now
            )

            let _: ActorState = try await db.create(tableName, data: newState)
            logger.debug("Created new state for actor: \(actorID), version: 1")
            return 1
        }

        // For existing actors, use conditional update
        let query = """
        UPDATE \(tableName) SET
            state = $state,
            sequenceNumber = sequenceNumber + 1,
            updatedAt = $updatedAt
        WHERE actorId = $actorId AND sequenceNumber = $expectedSeq
        RETURN AFTER
        """

        let results = try await db.query(query, variables: [
            "state": .string(stateData.base64EncodedString()),
            "updatedAt": .string(ISO8601DateFormatter().string(from: now)),
            "actorId": .string(actorID),
            "expectedSeq": .int(Int(expectedVersion))
        ])

        guard let firstResult = results.first,
              case .array(let records) = firstResult,
              !records.isEmpty else {
            // No rows updated = version conflict
            let actualVersion = try await getSequenceNumber(for: actorID) ?? 0
            throw ActorStateError.versionConflict(
                expected: expectedVersion,
                actual: actualVersion
            )
        }

        let updatedState: ActorState = try records.first!.decode()
        let newVersion = UInt64(updatedState.sequenceNumber)

        logger.debug("Updated state for actor: \(actorID), version: \(newVersion)")
        return newVersion
    }

    // MARK: - Connection Management

    /// Shutdown the state store and close the database connection
    public func shutdown() async {
        logger.debug("Shutting down SurrealDB state store")
        try? await db.disconnect()
    }

    // MARK: - Helper Methods

    /// Load the internal ActorState for an actor
    private func loadActorState(for actorID: String) async throws -> ActorState? {
        let query = "SELECT * FROM \(tableName) WHERE actorId = $actorId LIMIT 1"
        let results = try await db.query(query, variables: ["actorId": .string(actorID)])

        guard let firstResult = results.first,
              case .array(let records) = firstResult,
              let firstRecord = records.first else {
            return nil
        }

        return try firstRecord.decode()
    }
}

// MARK: - SurrealDB Errors

public enum SurrealDBError: Error, CustomStringConvertible {
    case connectionFailed(underlying: Error)
    case queryFailed(String)
    case stateNotFound(String)
    case invalidRecordFormat

    public var description: String {
        switch self {
        case .connectionFailed(let error):
            return "SurrealDB connection failed: \(error)"
        case .queryFailed(let message):
            return "SurrealDB query failed: \(message)"
        case .stateNotFound(let actorID):
            return "No state found for actor: \(actorID)"
        case .invalidRecordFormat:
            return "Invalid record format returned from SurrealDB"
        }
    }
}

// MARK: - SurrealValue Extension

extension SurrealValue {
    /// Decode a SurrealValue to a Decodable type
    func decode<T: Decodable>() throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
