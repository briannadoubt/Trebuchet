#if canImport(SwiftUI)
import Foundation
import SwiftUI

/// An observable wrapper around ``TrebuchetClient`` that manages connection lifecycle.
///
/// `TrebuchetConnection` provides SwiftUI-compatible state observation for connection status,
/// automatic reconnection with exponential backoff, and event streaming.
///
/// ## Basic Usage
///
/// ```swift
/// let connection = TrebuchetConnection(
///     transport: .webSocket(host: "localhost", port: 8080),
///     reconnectionPolicy: .default
/// )
///
/// // Connect
/// try await connection.connect()
///
/// // Resolve and use actors
/// let room = try connection.resolve(GameRoom.self, id: "main-room")
/// try await room.join(player: me)
///
/// // Disconnect when done
/// await connection.disconnect()
/// ```
///
/// ## Observing State in SwiftUI
///
/// ```swift
/// struct StatusView: View {
///     let connection: TrebuchetConnection
///
///     var body: some View {
///         switch connection.state {
///         case .connected:
///             Circle().fill(.green)
///         case .connecting, .reconnecting:
///             ProgressView()
///         default:
///             Circle().fill(.red)
///         }
///     }
/// }
/// ```
@Observable
@MainActor
public final class TrebuchetConnection {
    // MARK: - Observable Properties

    /// The current connection state.
    public private(set) var state: ConnectionState = .disconnected

    /// The most recent connection error, if any.
    public private(set) var lastError: ConnectionError?

    /// When the connection was successfully established (nil if not connected).
    public private(set) var connectedSince: Date?

    /// Number of successful reconnections in this session.
    public private(set) var reconnectionCount: Int = 0

    // MARK: - Configuration

    /// The transport configuration for this connection.
    public let transportConfiguration: TransportConfiguration

    /// The reconnection policy.
    public let reconnectionPolicy: ReconnectionPolicy

    /// Optional name for identifying this connection in multi-server scenarios.
    public let name: String?

    // MARK: - Internal State

    /// The underlying client (created on connect).
    private var _client: TrebuchetClient?

    /// Reconnection task handle.
    private var reconnectionTask: Task<Void, Never>?

    /// Message processing task handle.
    private var messageTask: Task<Void, Never>?

    /// Event stream continuation.
    private var eventContinuation: AsyncStream<ConnectionEvent>.Continuation?

    /// The event stream for connection lifecycle events.
    public private(set) var events: AsyncStream<ConnectionEvent>!

    // MARK: - Computed Properties

    /// The underlying ``TrebuchetClient`` (nil if not connected).
    ///
    /// Only available when ``state`` is `.connected`.
    public var client: TrebuchetClient? {
        guard state == .connected else { return nil }
        return _client
    }

    /// The actor system from the client (nil if not connected).
    public var actorSystem: TrebuchetActorSystem? {
        client?.actorSystem
    }

    // MARK: - Initialization

    /// Creates a new connection with the specified configuration.
    ///
    /// - Parameters:
    ///   - transport: The transport configuration (e.g., `.webSocket(host:port:)`).
    ///   - reconnectionPolicy: Policy for automatic reconnection. Defaults to `.default`.
    ///   - name: Optional name for this connection (useful in multi-server scenarios).
    public init(
        transport: TransportConfiguration,
        reconnectionPolicy: ReconnectionPolicy = .default,
        name: String? = nil
    ) {
        self.transportConfiguration = transport
        self.reconnectionPolicy = reconnectionPolicy
        self.name = name

        var continuation: AsyncStream<ConnectionEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
    }

    deinit {
        // Note: Tasks will be cancelled automatically when their references are released
        // The continuation will be finished when the stream goes out of scope
    }

    // MARK: - Public API

    /// Connect to the server.
    ///
    /// This establishes the network connection and starts processing messages.
    /// If already connected or connecting, this method returns immediately.
    ///
    /// - Throws: ``TrebuchetError`` if connection fails and no reconnection policy is active.
    public func connect() async throws {
        guard state.canConnect else { return }
        try await performConnect()
    }

    /// Disconnect from the server.
    ///
    /// This cancels any pending reconnection attempts and cleanly shuts down the connection.
    public func disconnect() async {
        reconnectionTask?.cancel()
        reconnectionTask = nil
        messageTask?.cancel()
        messageTask = nil

        emit(.willDisconnect)

        if let client = _client {
            await client.disconnect()
        }
        _client = nil

        state = .disconnected
        connectedSince = nil
        emit(.didDisconnect)
    }

    /// Resolve a remote actor by its ID.
    ///
    /// - Parameters:
    ///   - actorType: The type of the distributed actor.
    ///   - id: The actor's ID string (as exposed by the server).
    /// - Returns: A proxy to the remote actor.
    /// - Throws: ``TrebuchetError/systemNotRunning`` if not connected.
    public func resolve<Act: DistributedActor>(
        _ actorType: Act.Type,
        id: String
    ) throws -> Act where Act.ID == TrebuchetActorID, Act.ActorSystem == TrebuchetActorSystem {
        guard let client = client else {
            throw TrebuchetError.systemNotRunning
        }
        return try client.resolve(actorType, id: id)
    }

    // MARK: - Private Methods

    private func performConnect() async throws {
        state = .connecting
        emit(.willConnect)

        do {
            let client = TrebuchetClient(transport: transportConfiguration)
            try await client.connect()

            _client = client
            state = .connected
            connectedSince = Date()
            lastError = nil
            emit(.didConnect)

        } catch let error as TrebuchetError {
            let connectionError = ConnectionError(
                underlyingError: error,
                timestamp: Date(),
                connectionName: name
            )
            lastError = connectionError
            state = .failed(connectionError)
            emit(.didFailWithError(error))

            // Start reconnection if policy allows
            if reconnectionPolicy.maxAttempts > 0 {
                startReconnection()
            } else {
                throw error
            }
        }
    }

    private func startReconnection() {
        guard reconnectionTask == nil else { return }

        reconnectionTask = Task { [weak self] in
            guard let self else { return }

            var attempt = 0

            while attempt < self.reconnectionPolicy.maxAttempts {
                attempt += 1
                let delay = self.reconnectionPolicy.delay(for: attempt)

                await MainActor.run {
                    self.state = .reconnecting(attempt: attempt)
                    self.emit(.willReconnect(attempt: attempt, delay: delay))
                }

                try? await Task.sleep(for: delay)

                if Task.isCancelled { return }

                do {
                    let client = TrebuchetClient(transport: self.transportConfiguration)
                    try await client.connect()

                    await MainActor.run {
                        self._client = client
                        self.state = .connected
                        self.connectedSince = Date()
                        self.lastError = nil
                        self.reconnectionCount += 1
                        self.emit(.didReconnect(afterAttempts: attempt))
                    }

                    self.reconnectionTask = nil
                    return

                } catch {
                    // Continue trying
                }
            }

            // All attempts exhausted
            await MainActor.run {
                let endpoint = self.transportConfiguration.endpoint
                let error = ConnectionError(
                    underlyingError: .connectionFailed(
                        host: endpoint.host,
                        port: endpoint.port,
                        underlying: nil
                    ),
                    timestamp: Date(),
                    connectionName: self.name
                )
                self.lastError = error
                self.state = .failed(error)
            }

            self.reconnectionTask = nil
        }
    }

    private func emit(_ event: ConnectionEvent) {
        eventContinuation?.yield(event)
    }
}

// MARK: - Sendable Conformance

extension TrebuchetConnection: @unchecked Sendable {}
#endif
