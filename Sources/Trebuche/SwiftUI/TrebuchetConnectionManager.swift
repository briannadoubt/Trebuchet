#if canImport(SwiftUI)
import Foundation
import SwiftUI

/// Manages multiple named Trebuchet connections for multi-server scenarios.
///
/// Use `TrebuchetConnectionManager` when your app needs to communicate with
/// multiple Trebuchet servers simultaneously.
///
/// ## Basic Usage
///
/// ```swift
/// let manager = TrebuchetConnectionManager()
///
/// // Add connections
/// try await manager.addConnection(
///     named: "game",
///     transport: .webSocket(host: "game.example.com", port: 8080)
/// )
/// try await manager.addConnection(
///     named: "chat",
///     transport: .webSocket(host: "chat.example.com", port: 8080)
/// )
///
/// // Access connections
/// if let gameConnection = manager["game"] {
///     let room = try gameConnection.resolve(GameRoom.self, id: "lobby")
/// }
/// ```
///
/// ## SwiftUI Integration
///
/// ```swift
/// TrebuchetEnvironment(connections: [
///     "game": .webSocket(host: "game.example.com", port: 8080),
///     "chat": .webSocket(host: "chat.example.com", port: 8080)
/// ]) {
///     TabView {
///         GameTab()  // Uses default connection
///         ChatTab().trebuchetConnection(name: "chat")
///     }
/// }
/// ```
@Observable
@MainActor
public final class TrebuchetConnectionManager {
    // MARK: - Observable State

    /// All registered connections by name.
    public private(set) var connections: [String: TrebuchetConnection] = [:]

    /// The default connection name.
    ///
    /// This is automatically set to the first added connection unless explicitly changed.
    public var defaultConnectionName: String?

    // MARK: - Computed Properties

    /// The default connection (if set).
    public var defaultConnection: TrebuchetConnection? {
        guard let name = defaultConnectionName else { return nil }
        return connections[name]
    }

    /// Whether all registered connections are connected.
    public var allConnected: Bool {
        !connections.isEmpty && connections.values.allSatisfy { $0.state.isConnected }
    }

    /// Whether any registered connection is connected.
    public var anyConnected: Bool {
        connections.values.contains { $0.state.isConnected }
    }

    /// The names of all registered connections.
    public var connectionNames: [String] {
        Array(connections.keys).sorted()
    }

    // MARK: - Initialization

    /// Creates an empty connection manager.
    public init() {}

    // MARK: - Subscript Access

    /// Access a connection by name.
    ///
    /// - Parameter name: The connection name.
    /// - Returns: The connection, or nil if not registered.
    public subscript(name: String) -> TrebuchetConnection? {
        connections[name]
    }

    // MARK: - Connection Management

    /// Add a new connection with the given name.
    ///
    /// - Parameters:
    ///   - name: A unique name for this connection.
    ///   - transport: The transport configuration.
    ///   - reconnectionPolicy: Policy for automatic reconnection. Defaults to `.default`.
    ///   - connectImmediately: Whether to connect immediately after adding. Defaults to `true`.
    /// - Throws: ``TrebuchetError`` if immediate connection fails.
    public func addConnection(
        named name: String,
        transport: TransportConfiguration,
        reconnectionPolicy: ReconnectionPolicy = .default,
        connectImmediately: Bool = true
    ) async throws {
        let connection = TrebuchetConnection(
            transport: transport,
            reconnectionPolicy: reconnectionPolicy,
            name: name
        )

        connections[name] = connection

        if defaultConnectionName == nil {
            defaultConnectionName = name
        }

        if connectImmediately {
            try await connection.connect()
        }
    }

    /// Add a connection without connecting immediately.
    ///
    /// - Parameters:
    ///   - name: A unique name for this connection.
    ///   - transport: The transport configuration.
    ///   - reconnectionPolicy: Policy for automatic reconnection. Defaults to `.default`.
    public func registerConnection(
        named name: String,
        transport: TransportConfiguration,
        reconnectionPolicy: ReconnectionPolicy = .default
    ) {
        let connection = TrebuchetConnection(
            transport: transport,
            reconnectionPolicy: reconnectionPolicy,
            name: name
        )

        connections[name] = connection

        if defaultConnectionName == nil {
            defaultConnectionName = name
        }
    }

    /// Remove a connection by name.
    ///
    /// This disconnects the connection before removing it.
    ///
    /// - Parameter name: The connection name to remove.
    public func removeConnection(named name: String) async {
        if let connection = connections.removeValue(forKey: name) {
            await connection.disconnect()
        }

        if defaultConnectionName == name {
            defaultConnectionName = connections.keys.first
        }
    }

    /// Connect all registered connections.
    ///
    /// Connections are established concurrently. If any connection fails,
    /// this method throws the first error encountered.
    ///
    /// - Throws: ``TrebuchetError`` if any connection fails.
    public func connectAll() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for connection in connections.values {
                group.addTask {
                    try await connection.connect()
                }
            }
            try await group.waitForAll()
        }
    }

    /// Disconnect all registered connections.
    ///
    /// Connections are disconnected concurrently.
    public func disconnectAll() async {
        await withTaskGroup(of: Void.self) { group in
            for connection in connections.values {
                group.addTask {
                    await connection.disconnect()
                }
            }
        }
    }

    /// Connect a specific connection by name.
    ///
    /// - Parameter name: The connection name to connect.
    /// - Throws: ``TrebuchetError`` if connection fails or name not found.
    public func connect(named name: String) async throws {
        guard let connection = connections[name] else {
            throw TrebuchetError.invalidConfiguration("Connection '\(name)' not found")
        }
        try await connection.connect()
    }

    /// Disconnect a specific connection by name.
    ///
    /// - Parameter name: The connection name to disconnect.
    public func disconnect(named name: String) async {
        await connections[name]?.disconnect()
    }

    /// Resolve an actor from a specific connection.
    ///
    /// - Parameters:
    ///   - actorType: The type of the distributed actor.
    ///   - id: The actor's ID string.
    ///   - connectionName: The connection to use. Defaults to the default connection.
    /// - Returns: A proxy to the remote actor.
    /// - Throws: ``TrebuchetError`` if resolution fails or connection not found.
    public func resolve<Act: DistributedActor>(
        _ actorType: Act.Type,
        id: String,
        from connectionName: String? = nil
    ) throws -> Act where Act.ID == TrebuchetActorID, Act.ActorSystem == TrebuchetActorSystem {
        let name = connectionName ?? defaultConnectionName
        guard let name, let connection = connections[name] else {
            throw TrebuchetError.systemNotRunning
        }
        return try connection.resolve(actorType, id: id)
    }
}

// MARK: - Sendable Conformance

extension TrebuchetConnectionManager: @unchecked Sendable {}
#endif
