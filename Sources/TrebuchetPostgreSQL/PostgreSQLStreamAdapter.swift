import Foundation
import PostgresNIO
import Trebuchet
import TrebuchetCloud
import NIOCore
import NIOPosix
import Logging

// MARK: - State Change Notification

/// Represents a state change notification from PostgreSQL
public struct StateChangeNotification: Codable, Sendable {
    public let actorID: String
    public let sequenceNumber: UInt64
    public let timestamp: Date

    public init(
        actorID: String,
        sequenceNumber: UInt64,
        timestamp: Date = Date()
    ) {
        self.actorID = actorID
        self.sequenceNumber = sequenceNumber
        self.timestamp = timestamp
    }
}

// MARK: - PostgreSQL Stream Adapter

/// Adapter for PostgreSQL LISTEN/NOTIFY for multi-instance actor synchronization.
///
/// This adapter enables real-time state change notifications across multiple
/// actor instances using PostgreSQL's pub/sub capabilities.
///
/// ## Database Setup
///
/// ### 1. Create Notification Function
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
/// ### 2. Create Trigger
///
/// ```sql
/// CREATE TRIGGER actor_state_change_trigger
/// AFTER INSERT OR UPDATE ON actor_states
/// FOR EACH ROW
/// EXECUTE FUNCTION notify_actor_state_change();
/// ```
///
/// ## Usage
///
/// ```swift
/// let adapter = try await PostgreSQLStreamAdapter(
///     host: "localhost",
///     database: "mydb",
///     username: "user",
///     password: "pass"
/// )
///
/// // Start listening for changes
/// let stream = try await adapter.start()
///
/// // Process changes
/// for await change in stream {
///     print("Actor \(change.actorID) updated to sequence \(change.sequenceNumber)")
/// }
/// ```
///
/// ## Note on Implementation
///
/// The current implementation provides the foundation for LISTEN/NOTIFY but requires
/// additional work to fully integrate with PostgresNIO's notification system. The stream
/// adapter is designed to work with the notification mechanism but the PostgresNIO library's
/// notification API needs proper async stream integration.
///
public actor PostgreSQLStreamAdapter {
    private let eventLoopGroup: EventLoopGroup
    private let configuration: PostgresConnection.Configuration
    private let channel: String
    private var connection: PostgresConnection?
    private var isListeningFlag = false
    private let decoder: JSONDecoder
    private let logger: Logger

    /// Initialize with connection parameters
    ///
    /// - Parameters:
    ///   - host: PostgreSQL host (default: "localhost")
    ///   - port: PostgreSQL port (default: 5432)
    ///   - database: Database name
    ///   - username: Username (default: current user)
    ///   - password: Password (optional)
    ///   - channel: PostgreSQL notification channel (default: "actor_state_changes")
    ///   - eventLoopGroup: NIO event loop group (creates default if not provided)
    /// - Throws: PostgreSQLError.invalidChannelName if channel contains invalid characters
    public init(
        host: String = "localhost",
        port: Int = 5432,
        database: String,
        username: String = NSUserName(),
        password: String? = nil,
        channel: String = "actor_state_changes",
        eventLoopGroup: EventLoopGroup? = nil
    ) async throws {
        // Validate channel name to prevent SQL injection
        guard Self.isValidIdentifier(channel) else {
            throw PostgreSQLError.invalidChannelName(channel)
        }

        self.eventLoopGroup = eventLoopGroup ?? MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.channel = channel
        self.logger = Logger(label: "com.trebuchet.postgresql.stream")

        self.configuration = PostgresConnection.Configuration(
            host: host,
            port: port,
            username: username,
            password: password,
            database: database,
            tls: .disable
        )

        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .secondsSince1970
    }

    /// Validates that an identifier is safe for use in SQL queries.
    ///
    /// PostgreSQL identifiers must start with a letter or underscore,
    /// and contain only letters, digits, underscores, and hyphens.
    ///
    /// - Parameter identifier: The identifier to validate
    /// - Returns: true if the identifier is safe to use
    private static func isValidIdentifier(_ identifier: String) -> Bool {
        guard !identifier.isEmpty, identifier.count <= 63 else {
            return false  // PostgreSQL identifier max length is 63
        }

        // Must start with letter or underscore
        guard let first = identifier.first,
              first.isLetter || first == "_" else {
            return false
        }

        // Rest must be letters, digits, underscores, or hyphens
        return identifier.allSatisfy { char in
            char.isLetter || char.isNumber || char == "_" || char == "-"
        }
    }

    /// Start listening for state change notifications
    ///
    /// - Returns: AsyncStream of state change notifications
    ///
    /// ## Implementation
    ///
    /// This method connects to PostgreSQL and starts listening for notifications on the
    /// configured channel. It uses PostgresNIO's native `listen()` method which returns
    /// an AsyncSequence of notifications.
    ///
    /// ### How It Works
    ///
    /// 1. Connects to PostgreSQL
    /// 2. Calls `connection.listen(channel)` which automatically sends LISTEN command
    /// 3. Bridges PostgresNIO's notification sequence to an AsyncStream
    /// 4. Parses JSON payloads into StateChangeNotification objects
    /// 5. Yields notifications to subscribers
    ///
    /// ### Error Handling
    ///
    /// - Connection errors will throw immediately
    /// - JSON decoding errors are logged but don't terminate the stream
    /// - When the stream is cancelled, PostgresNIO automatically sends UNLISTEN
    ///
    /// ### Database Trigger Setup
    ///
    /// Your PostgreSQL database should have a trigger that calls pg_notify():
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
    public func start() async throws -> AsyncStream<StateChangeNotification> {
        // Connect to PostgreSQL
        let conn = try await PostgresConnection.connect(
            on: eventLoopGroup.any(),
            configuration: configuration,
            id: 1,
            logger: logger
        )

        self.connection = conn

        // Start listening on the channel
        // PostgresNIO's listen() automatically sends the LISTEN command
        // and returns an AsyncSequence of notifications
        let notifications = try await conn.listen(channel)
        isListeningFlag = true

        logger.info("Started listening on PostgreSQL channel: \(channel)")

        // Create async stream that bridges PostgreSQL notifications to our stream type
        return AsyncStream { continuation in
            continuation.onTermination = { @Sendable [weak self] _ in
                Task {
                    // Clean up connection when stream is terminated
                    try? await self?.stop()
                }
            }

            // Bridge PostgresNIO notifications to our AsyncStream
            Task { [weak self] in
                guard let self = self else {
                    continuation.finish()
                    return
                }

                do {
                    // Iterate over notifications from PostgreSQL
                    for try await notification in notifications {
                        // Check for cancellation
                        guard !Task.isCancelled else {
                            break
                        }

                        // Parse the JSON payload from PostgreSQL
                        guard let data = notification.payload.data(using: .utf8) else {
                            self.logger.warning("Failed to convert notification payload to UTF-8")
                            continue
                        }

                        do {
                            // Decode JSON into StateChangeNotification
                            let change = try self.decoder.decode(
                                StateChangeNotification.self,
                                from: data
                            )

                            // Yield to stream subscribers
                            continuation.yield(change)

                            self.logger.debug("Received notification for actor: \(change.actorID), sequence: \(change.sequenceNumber)")
                        } catch {
                            // Log decoding errors but don't terminate the stream
                            self.logger.error("Failed to decode notification payload: \(error)")
                        }
                    }

                    // Notification sequence finished (connection closed or UNLISTEN)
                    self.logger.info("Notification stream ended for channel: \(channel)")
                    continuation.finish()

                } catch {
                    // Connection or iteration error
                    self.logger.error("Error receiving notifications: \(error)")
                    continuation.finish()
                }
            }
        }
    }

    /// Stop listening for notifications
    ///
    /// This closes the PostgreSQL connection, which automatically terminates any
    /// active LISTEN subscriptions. PostgresNIO sends UNLISTEN automatically when
    /// the notification AsyncSequence is cancelled or the connection closes.
    public func stop() async throws {
        guard let connection = self.connection else {
            return
        }

        logger.info("Stopping PostgreSQL listener on channel: \(channel)")

        // Close connection (PostgresNIO automatically sends UNLISTEN)
        try await connection.close()
        isListeningFlag = false
        self.connection = nil

        logger.info("PostgreSQL listener stopped")
    }

    /// Manually send a notification (for testing or manual triggering)
    ///
    /// - Parameter change: The state change to notify about
    public func notify(_ change: StateChangeNotification) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970

        let data = try encoder.encode(change)

        guard let payload = String(data: data, encoding: .utf8) else {
            throw PostgreSQLError.queryFailed("Failed to encode notification payload")
        }

        guard let connection = self.connection else {
            throw PostgreSQLError.queryFailed("Not connected")
        }

        _ = try await connection.query(
            "SELECT pg_notify($1, $2)",
            [
                PostgresData(string: channel),
                PostgresData(string: payload)
            ]
        ).get()
    }

    /// Check if currently listening for notifications
    public var isListening: Bool {
        isListeningFlag
    }
}
