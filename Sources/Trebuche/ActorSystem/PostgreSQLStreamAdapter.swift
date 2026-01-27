import Foundation

// MARK: - State Change Notification

/// Represents a state change notification from a database
public struct StateChangeNotification: Codable, Sendable {
    public let actorID: String
    public let stateData: Data
    public let sequenceNumber: UInt64
    public let timestamp: Date

    public init(
        actorID: String,
        stateData: Data,
        sequenceNumber: UInt64,
        timestamp: Date = Date()
    ) {
        self.actorID = actorID
        self.stateData = stateData
        self.sequenceNumber = sequenceNumber
        self.timestamp = timestamp
    }
}

// MARK: - PostgreSQL Stream Adapter (Design)

/// Adapter for PostgreSQL LISTEN/NOTIFY for actor state change notifications.
///
/// This adapter enables multi-instance actor synchronization using PostgreSQL's
/// pub/sub capabilities. When one actor instance updates state, it notifies
/// all other instances via PostgreSQL channels.
///
/// ## Architecture
///
/// ```
/// Actor Instance 1 → saveState() → PostgreSQL
///                                      ↓
///                                  TRIGGER
///                                      ↓
///                              NOTIFY 'actor_changes'
///                                      ↓
///                       ┌──────────────┼──────────────┐
///                       ↓              ↓              ↓
///               Instance 1      Instance 2      Instance 3
///               (ignore)        loadState()     loadState()
///                                    ↓              ↓
///                            Broadcast to    Broadcast to
///                            WebSocket       WebSocket
///                            clients         clients
/// ```
///
/// ## Database Setup
///
/// ### 1. Create Actor State Table
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
/// ```
///
/// ### 2. Create Notification Function
///
/// ```sql
/// CREATE OR REPLACE FUNCTION notify_actor_state_change()
/// RETURNS TRIGGER AS $$
/// BEGIN
///     PERFORM pg_notify('actor_state_changes',
///         json_build_object(
///             'actorID', NEW.actor_id,
///             'sequenceNumber', NEW.sequence_number,
///             'timestamp', EXTRACT(EPOCH FROM NEW.updated_at)
///         )::text
///     );
///     RETURN NEW;
/// END;
/// $$ LANGUAGE plpgsql;
/// ```
///
/// ### 3. Create Trigger
///
/// ```sql
/// CREATE TRIGGER actor_state_change_trigger
/// AFTER INSERT OR UPDATE ON actor_states
/// FOR EACH ROW
/// EXECUTE FUNCTION notify_actor_state_change();
/// ```
///
/// ## Usage Example
///
/// ```swift
/// // Initialize adapter
/// let adapter = try await PostgreSQLStreamAdapter(
///     connectionString: "postgresql://localhost/mydb",
///     channel: "actor_state_changes"
/// )
///
/// // Start listening for changes
/// let stream = try await adapter.start()
///
/// // Process changes in background
/// Task {
///     for await change in stream {
///         // Load updated state and broadcast to clients
///         await handleStateChange(change)
///     }
/// }
/// ```
///
/// ## Integration with StatefulActor
///
/// ```swift
/// @Trebuchet
/// public distributed actor TodoList: StatefulActor {
///     private let stateStore: PostgreSQLStateStore
///     private let streamAdapter: PostgreSQLStreamAdapter
///
///     @StreamedState public var state = State()
///
///     public var persistentState: State {
///         get { state }
///         set { state = newValue }
///     }
///
///     public init(
///         actorSystem: TrebuchetActorSystem,
///         stateStore: PostgreSQLStateStore,
///         streamAdapter: PostgreSQLStreamAdapter
///     ) async throws {
///         self.actorSystem = actorSystem
///         self.stateStore = stateStore
///         self.streamAdapter = streamAdapter
///
///         // Load initial state
///         try await loadState(from: stateStore)
///
///         // Listen for changes from other instances
///         Task {
///             let changes = try await streamAdapter.start()
///             for await change in changes {
///                 if change.actorID == id.id {
///                     // Another instance updated our state
///                     try await loadState(from: stateStore)
///                 }
///             }
///         }
///     }
///
///     // ... StatefulActor implementation ...
/// }
/// ```
///
/// ## Benefits
///
/// - **Multi-instance sync**: All actor instances stay synchronized
/// - **Real-time updates**: Changes propagate immediately via LISTEN/NOTIFY
/// - **Reliable**: PostgreSQL guarantees delivery to connected clients
/// - **Simple**: No additional infrastructure (Redis, Kafka, etc.)
/// - **Transactional**: Notifications are part of the transaction
///
/// ## Performance Considerations
///
/// - **Connection pooling**: Each listener needs a dedicated connection
/// - **Channel naming**: Use namespaced channels to avoid conflicts
/// - **Payload size**: NOTIFY has 8KB limit, send IDs not full state
/// - **Reconnection**: Implement automatic reconnection logic
///
/// ## Future Implementation
///
/// This is a design specification. Implementation would require:
/// 1. PostgreSQL Swift client (e.g., PostgresNIO)
/// 2. Connection management and pooling
/// 3. Automatic reconnection logic
/// 4. Error handling and logging
///
public protocol PostgreSQLStreamAdapterProtocol: Sendable {
    /// Start listening for state change notifications
    /// - Returns: AsyncStream of state changes
    func start() async throws -> AsyncStream<StateChangeNotification>

    /// Stop listening for notifications
    func stop() async throws

    /// Manually notify of a state change
    func notify(_ change: StateChangeNotification) async throws

    /// Check if adapter is currently listening
    var isListening: Bool { get async }
}

// MARK: - PostgreSQL State Store Protocol

/// Protocol for PostgreSQL-based actor state storage
public protocol PostgreSQLStateStoreProtocol: Sendable {
    /// Save state with automatic sequence increment
    func save<State: Codable & Sendable>(
        _ state: State,
        for actorID: String
    ) async throws -> UInt64

    /// Load state
    func load<State: Codable & Sendable>(
        for actorID: String,
        as type: State.Type
    ) async throws -> State?

    /// Get current sequence number
    func getSequence(for actorID: String) async throws -> UInt64?
}

// MARK: - Example Implementation Stub

/// Placeholder implementation showing the interface
///
/// In production, this would use a real PostgreSQL client like PostgresNIO:
///
/// ```swift
/// import PostgresNIO
///
/// public actor PostgreSQLStreamAdapter: PostgreSQLStreamAdapterProtocol {
///     private let connection: PostgresConnection
///     private let channel: String
///     private var isListeningFlag = false
///
///     public init(connectionString: String, channel: String) async throws {
///         self.connection = try await PostgresConnection.connect(
///             on: /* event loop */,
///             configuration: .init(connectionString: connectionString)
///         )
///         self.channel = channel
///     }
///
///     public func start() async throws -> AsyncStream<StateChangeNotification> {
///         try await connection.query("LISTEN \(channel)")
///         isListeningFlag = true
///
///         return AsyncStream { continuation in
///             Task {
///                 for try await notification in connection.notifications {
///                     if notification.channel == channel {
///                         let change = try JSONDecoder().decode(
///                             StateChangeNotification.self,
///                             from: notification.payload.data(using: .utf8) ?? Data()
///                         )
///                         continuation.yield(change)
///                     }
///                 }
///                 continuation.finish()
///             }
///         }
///     }
///
///     public func stop() async throws {
///         try await connection.query("UNLISTEN \(channel)")
///         isListeningFlag = false
///     }
///
///     public func notify(_ change: StateChangeNotification) async throws {
///         let encoder = JSONEncoder()
///         let data = try encoder.encode(change)
///         let payload = String(data: data, encoding: .utf8) ?? ""
///
///         try await connection.query(
///             "SELECT pg_notify($1, $2)",
///             [channel, payload]
///         )
///     }
///
///     public var isListening: Bool {
///         isListeningFlag
///     }
/// }
/// ```
public actor PostgreSQLStreamAdapterStub: PostgreSQLStreamAdapterProtocol {
    private var isListeningFlag = false

    public init() {}

    public func start() async throws -> AsyncStream<StateChangeNotification> {
        isListeningFlag = true
        return AsyncStream { continuation in
            // Placeholder: In production, this would yield actual notifications
            continuation.finish()
        }
    }

    public func stop() async throws {
        isListeningFlag = false
    }

    public func notify(_ change: StateChangeNotification) async throws {
        // Placeholder: In production, this would send via pg_notify
    }

    public var isListening: Bool {
        isListeningFlag
    }
}

// MARK: - Documentation

/// # PostgreSQL Stream Adapter Setup Guide
///
/// ## Prerequisites
///
/// - PostgreSQL 9.0 or later
/// - Database with appropriate permissions
/// - Network connectivity to PostgreSQL instance
///
/// ## Step-by-Step Setup
///
/// ### 1. Create Database and Table
///
/// ```bash
/// createdb trebuche_actors
/// psql trebuche_actors
/// ```
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
/// ### 2. Create Notification Infrastructure
///
/// ```sql
/// -- Function to notify on state changes
/// CREATE OR REPLACE FUNCTION notify_actor_state_change()
/// RETURNS TRIGGER AS $$
/// BEGIN
///     PERFORM pg_notify('actor_state_changes',
///         json_build_object(
///             'actorID', NEW.actor_id,
///             'sequenceNumber', NEW.sequence_number,
///             'timestamp', EXTRACT(EPOCH FROM NEW.updated_at)
///         )::text
///     );
///     RETURN NEW;
/// END;
/// $$ LANGUAGE plpgsql;
///
/// -- Trigger to execute function
/// CREATE TRIGGER actor_state_change_trigger
/// AFTER INSERT OR UPDATE ON actor_states
/// FOR EACH ROW
/// EXECUTE FUNCTION notify_actor_state_change();
/// ```
///
/// ### 3. Test Notifications
///
/// In one terminal:
/// ```sql
/// LISTEN actor_state_changes;
/// ```
///
/// In another terminal:
/// ```sql
/// INSERT INTO actor_states (actor_id, state, sequence_number)
/// VALUES ('test-actor', E'\\x00', 1);
/// ```
///
/// First terminal should show:
/// ```
/// Asynchronous notification "actor_state_changes" received from server process...
/// ```
///
/// ## Production Deployment
///
/// ### Connection Pooling
///
/// Each LISTEN connection requires a dedicated PostgreSQL connection.
/// Use connection pooling carefully:
///
/// - **Dedicated listener pool**: Separate from query connection pool
/// - **Reconnection logic**: Automatic reconnection on connection loss
/// - **Health checks**: Monitor connection health
///
/// ### Monitoring
///
/// ```sql
/// -- Check active listeners
/// SELECT pid, usename, application_name, state, query
/// FROM pg_stat_activity
/// WHERE query LIKE 'LISTEN%';
///
/// -- Check notification queue
/// SELECT * FROM pg_notification_queue_usage();
/// ```
///
/// ### Scaling Considerations
///
/// - **Horizontal scaling**: Each instance gets all notifications
/// - **Filtering**: Filter by actorID to process only relevant changes
/// - **Batching**: Batch updates when possible to reduce notifications
/// - **Monitoring**: Track notification volume and processing time
///
public enum PostgreSQLStreamAdapterDocumentation {
    // This enum exists solely for documentation purposes
}
