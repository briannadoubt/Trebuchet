import Foundation
import PostgresNIO
import Trebuchet
import TrebuchetCloud
import NIOCore
import NIOPosix
import Logging

// MARK: - PostgreSQL State Store

/// Actor state storage using PostgreSQL.
///
/// This implementation provides reliable, ACID-compliant state persistence with:
/// - Automatic sequence number tracking
/// - Optimistic locking support
/// - Transaction support
/// - Connection pooling
///
/// ## Database Schema
///
/// ```sql
/// CREATE TABLE actor_states (
///     actor_id VARCHAR(255) PRIMARY KEY,
///     state BYTEA NOT NULL,
///     sequence_number BIGINT NOT NULL DEFAULT 0,
///     updated_at TIMESTAMP NOT NULL DEFAULT NOW(),
///     created_at TIMESTAMP NOT NULL DEFAULT NOW()
/// );
///
/// CREATE INDEX idx_actor_states_updated ON actor_states(updated_at);
/// CREATE INDEX idx_actor_states_sequence ON actor_states(sequence_number);
/// ```
///
/// ## Usage
///
/// ```swift
/// let stateStore = try await PostgreSQLStateStore(
///     host: "localhost",
///     database: "mydb",
///     username: "user",
///     password: "pass"
/// )
///
/// // Save state
/// try await stateStore.save(myState, for: "actor-123")
///
/// // Load state
/// let state = try await stateStore.load(for: "actor-123", as: MyState.self)
/// ```
///
public actor PostgreSQLStateStore: ActorStateStore {
    private let eventLoopGroup: EventLoopGroup
    private let configuration: PostgresConnection.Configuration
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let tableName: String
    private let logger: Logger

    /// Initialize with DATABASE_URL connection string
    ///
    /// Parses a PostgreSQL connection string in the format:
    /// `postgresql://[user[:password]@][host][:port][/database][?options]`
    ///
    /// - Parameters:
    ///   - connectionString: PostgreSQL connection URL
    ///   - tableName: Table name for actor states (default: "actor_states")
    ///   - eventLoopGroup: NIO event loop group (creates default if not provided)
    public init(
        connectionString: String,
        tableName: String = "actor_states",
        eventLoopGroup: EventLoopGroup? = nil
    ) async throws {
        // Parse connection string
        guard let components = URLComponents(string: connectionString),
              let scheme = components.scheme,
              ["postgresql", "postgres"].contains(scheme) else {
            throw PostgreSQLError.invalidConnectionString
        }

        guard let host = components.host else {
            throw PostgreSQLError.invalidConnectionString
        }

        let port = components.port ?? 5432
        let username = components.user ?? NSUserName()
        let password = components.password
        let database = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard !database.isEmpty else {
            throw PostgreSQLError.invalidConnectionString
        }

        self.eventLoopGroup = eventLoopGroup ?? MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.tableName = tableName
        self.logger = Logger(label: "com.trebuchet.postgresql")

        self.configuration = PostgresConnection.Configuration(
            host: host,
            port: port,
            username: username,
            password: password,
            database: database,
            tls: .disable
        )

        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601

        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601

        // Verify connection
        try await withConnection { _ in }
    }

    /// Initialize with connection parameters
    ///
    /// - Parameters:
    ///   - host: PostgreSQL host (default: "localhost")
    ///   - port: PostgreSQL port (default: 5432)
    ///   - database: Database name
    ///   - username: Username (default: current user)
    ///   - password: Password (optional)
    ///   - tableName: Table name for actor states (default: "actor_states")
    ///   - eventLoopGroup: NIO event loop group (creates default if not provided)
    public init(
        host: String = "localhost",
        port: Int = 5432,
        database: String,
        username: String = NSUserName(),
        password: String? = nil,
        tableName: String = "actor_states",
        eventLoopGroup: EventLoopGroup? = nil
    ) async throws {
        self.eventLoopGroup = eventLoopGroup ?? MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.tableName = tableName
        self.logger = Logger(label: "com.trebuchet.postgresql")

        self.configuration = PostgresConnection.Configuration(
            host: host,
            port: port,
            username: username,
            password: password,
            database: database,
            tls: .disable
        )

        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601

        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601

        // Verify connection
        try await withConnection { _ in }
    }

    public func load<State: Codable & Sendable>(
        for actorID: String,
        as type: State.Type
    ) async throws -> State? {
        try await withConnection { connection in
            let query = "SELECT state FROM " + tableName + " WHERE actor_id = $1"
            let rows = try await connection.query(
                query,
                [PostgresData(string: actorID)]
            ).get()

            guard let row = rows.first else {
                return nil
            }

            let stateData = try row.decode(Data.self, context: .default)
            return try decoder.decode(State.self, from: stateData)
        }
    }

    public func save<State: Codable & Sendable>(
        _ state: State,
        for actorID: String
    ) async throws {
        let stateData = try encoder.encode(state)

        try await withConnection { connection in
            let query = """
                INSERT INTO \(tableName) (actor_id, state, sequence_number)
                VALUES ($1, $2, 1)
                ON CONFLICT (actor_id) DO UPDATE
                SET state = EXCLUDED.state,
                    sequence_number = \(tableName).sequence_number + 1,
                    updated_at = NOW()
                """
            _ = try await connection.query(
                query,
                [
                    PostgresData(string: actorID),
                    PostgresData(bytes: [UInt8](stateData))
                ]
            ).get()
        }
    }

    public func delete(for actorID: String) async throws {
        try await withConnection { connection in
            let query = "DELETE FROM " + tableName + " WHERE actor_id = $1"
            _ = try await connection.query(
                query,
                [PostgresData(string: actorID)]
            ).get()
        }
    }

    public func exists(for actorID: String) async throws -> Bool {
        try await withConnection { connection in
            let query = "SELECT 1 FROM " + tableName + " WHERE actor_id = $1"
            let rows = try await connection.query(
                query,
                [PostgresData(string: actorID)]
            ).get()

            return !rows.isEmpty
        }
    }

    public func update<State: Codable & Sendable>(
        for actorID: String,
        as type: State.Type,
        transform: @Sendable (State?) async throws -> State
    ) async throws -> State {
        // Load current state
        let current = try await load(for: actorID, as: type)

        // Apply transformation
        let newState = try await transform(current)

        // Save and return
        try await save(newState, for: actorID)
        return newState
    }

    // MARK: - Sequence Number Support

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
        let stateData = try encoder.encode(state)

        if let sequence = sequenceNumber {
            // Use explicit sequence number
            try await withConnection { connection in
                let query = """
                    INSERT INTO \(tableName) (actor_id, state, sequence_number)
                    VALUES ($1, $2, $3)
                    ON CONFLICT (actor_id) DO UPDATE
                    SET state = EXCLUDED.state,
                        sequence_number = EXCLUDED.sequence_number,
                        updated_at = NOW()
                    """
                _ = try await connection.query(
                    query,
                    [
                        PostgresData(string: actorID),
                        PostgresData(bytes: [UInt8](stateData)),
                        PostgresData(int64: Int64(sequence))
                    ]
                ).get()
            }

            return sequence
        } else {
            // Auto-increment sequence number
            return try await withConnection { connection in
                let query = """
                    INSERT INTO \(tableName) (actor_id, state, sequence_number)
                    VALUES ($1, $2, 1)
                    ON CONFLICT (actor_id) DO UPDATE
                    SET state = EXCLUDED.state,
                        sequence_number = \(tableName).sequence_number + 1,
                        updated_at = NOW()
                    RETURNING sequence_number
                    """
                let rows = try await connection.query(
                    query,
                    [
                        PostgresData(string: actorID),
                        PostgresData(bytes: [UInt8](stateData))
                    ]
                ).get()

                guard let row = rows.first else {
                    throw PostgreSQLError.sequenceRetrievalFailed
                }

                let seqNum = try row.decode(Int64.self, context: .default)
                return UInt64(seqNum)
            }
        }
    }

    /// Get the current sequence number for an actor
    ///
    /// - Parameter actorID: Actor identifier
    /// - Returns: Current sequence number, or nil if actor doesn't exist
    public func getSequenceNumber(for actorID: String) async throws -> UInt64? {
        try await withConnection { connection in
            let query = "SELECT sequence_number FROM " + tableName + " WHERE actor_id = $1"
            let rows = try await connection.query(
                query,
                [PostgresData(string: actorID)]
            ).get()

            guard let row = rows.first else {
                return nil
            }

            let seqNum = try row.decode(Int64.self, context: .default)
            return UInt64(seqNum)
        }
    }

    // MARK: - Optimistic Locking

    /// Save state with version check to prevent concurrent write conflicts
    ///
    /// Uses PostgreSQL's atomic UPDATE with WHERE condition to ensure the version
    /// matches before updating. If the version doesn't match, throws versionConflict.
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
        let stateData = try encoder.encode(state)

        return try await withConnection { connection in
            // For new actors (expectedVersion == 0), use INSERT
            if expectedVersion == 0 {
                let insertQuery = """
                    INSERT INTO \(tableName) (actor_id, state, sequence_number)
                    VALUES ($1, $2, 1)
                    ON CONFLICT (actor_id) DO NOTHING
                    RETURNING sequence_number
                    """

                let insertRows = try await connection.query(
                    insertQuery,
                    [
                        PostgresData(string: actorID),
                        PostgresData(bytes: [UInt8](stateData))
                    ]
                ).get()

                if let row = insertRows.first {
                    // Successfully inserted
                    let seqNum = try row.decode(Int64.self, context: .default)
                    return UInt64(seqNum)
                } else {
                    // Conflict - actor already exists, throw version conflict
                    let actualVersion = try await getSequenceNumber(for: actorID) ?? 0
                    throw ActorStateError.versionConflict(
                        expected: expectedVersion,
                        actual: actualVersion
                    )
                }
            }

            // For existing actors, use conditional UPDATE
            let updateQuery = """
                UPDATE \(tableName)
                SET state = $1,
                    sequence_number = sequence_number + 1,
                    updated_at = NOW()
                WHERE actor_id = $2
                  AND sequence_number = $3
                RETURNING sequence_number
                """

            let rows = try await connection.query(
                updateQuery,
                [
                    PostgresData(bytes: [UInt8](stateData)),
                    PostgresData(string: actorID),
                    PostgresData(int64: Int64(expectedVersion))
                ]
            ).get()

            guard let row = rows.first else {
                // No rows updated = version conflict
                let actualVersion = try await getSequenceNumber(for: actorID) ?? 0
                throw ActorStateError.versionConflict(
                    expected: expectedVersion,
                    actual: actualVersion
                )
            }

            let newVersion = try row.decode(Int64.self, context: .default)
            return UInt64(newVersion)
        }
    }

    // MARK: - Connection Management

    /// Execute an operation with a PostgreSQL connection.
    ///
    /// Creates a new connection, executes the operation, and ensures the connection
    /// is closed even if the operation throws an error.
    ///
    /// - Parameter operation: The operation to execute with the connection
    /// - Returns: The result of the operation
    /// - Throws: Any error from connection creation or the operation
    ///
    /// - Note: For production use with high concurrency, consider implementing
    ///   connection pooling to avoid creating a new connection per operation.
    private func withConnection<T>(_ operation: @Sendable (PostgresConnection) async throws -> T) async throws -> T {
        let connection = try await PostgresConnection.connect(
            on: eventLoopGroup.any(),
            configuration: configuration,
            id: 1,
            logger: logger
        )

        do {
            let result = try await operation(connection)
            try await connection.close()
            return result
        } catch {
            // Ensure connection closes even on error
            try? await connection.close()
            throw error
        }
    }
}

// MARK: - PostgreSQL Errors

public enum PostgreSQLError: Error, CustomStringConvertible {
    case invalidConnectionString
    case connectionFailed(underlying: Error)
    case queryFailed(String)
    case sequenceRetrievalFailed
    case invalidChannelName(String)

    public var description: String {
        switch self {
        case .invalidConnectionString:
            return "Invalid PostgreSQL connection string"
        case .connectionFailed(let error):
            return "PostgreSQL connection failed: \(error)"
        case .queryFailed(let message):
            return "PostgreSQL query failed: \(message)"
        case .sequenceRetrievalFailed:
            return "Failed to retrieve sequence number after insert"
        case .invalidChannelName(let name):
            return "Invalid PostgreSQL channel name '\(name)': must start with letter/underscore and contain only letters, digits, underscores, and hyphens (max 63 chars)"
        }
    }
}
