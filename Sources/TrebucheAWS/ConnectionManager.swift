import Foundation
import Trebuche

// MARK: - Connection Storage Protocol

/// Protocol for storing WebSocket connection information.
///
/// Implementations can use DynamoDB, Redis, or in-memory storage.
public protocol ConnectionStorage: Sendable {
    /// Register a new WebSocket connection
    func register(connectionID: String, actorID: String?) async throws

    /// Update connection with stream subscription info
    func subscribe(
        connectionID: String,
        streamID: UUID,
        actorID: String,
        lastSequence: UInt64
    ) async throws

    /// Remove connection on disconnect
    func unregister(connectionID: String) async throws

    /// Get all connections subscribed to an actor
    func getConnections(for actorID: String) async throws -> [Connection]

    /// Update the last sequence number for a connection
    func updateSequence(
        connectionID: String,
        lastSequence: UInt64
    ) async throws
}

// MARK: - Connection Sender Protocol

/// Protocol for sending data to WebSocket connections.
///
/// Implementations can use API Gateway Management API, direct WebSocket, etc.
public protocol ConnectionSender: Sendable {
    /// Send data to a specific connection
    func send(data: Data, to connectionID: String) async throws

    /// Check if a connection is still alive
    func isAlive(connectionID: String) async -> Bool
}

// MARK: - Connection Model

/// Represents a WebSocket connection with subscription information
public struct Connection: Codable, Sendable, Identifiable {
    public let id: String  // Same as connectionID
    public let connectionID: String
    public let connectedAt: Date
    public let streamID: UUID?
    public let actorID: String?
    public let lastSequence: UInt64

    public init(
        connectionID: String,
        connectedAt: Date = Date(),
        streamID: UUID? = nil,
        actorID: String? = nil,
        lastSequence: UInt64 = 0
    ) {
        self.id = connectionID
        self.connectionID = connectionID
        self.connectedAt = connectedAt
        self.streamID = streamID
        self.actorID = actorID
        self.lastSequence = lastSequence
    }
}

// MARK: - Connection Manager

/// Manages WebSocket connections and broadcasts stream updates.
///
/// This actor coordinates between connection storage (DynamoDB) and
/// the connection sender (API Gateway Management API).
public actor ConnectionManager {
    private let storage: ConnectionStorage
    private let sender: ConnectionSender

    public init(storage: ConnectionStorage, sender: ConnectionSender) {
        self.storage = storage
        self.sender = sender
    }

    // MARK: - Connection Lifecycle

    /// Register a new WebSocket connection
    public func register(connectionID: String, actorID: String? = nil) async throws {
        try await storage.register(connectionID: connectionID, actorID: actorID)
    }

    /// Track stream subscription for a connection
    public func subscribe(
        connectionID: String,
        streamID: UUID,
        actorID: String
    ) async throws {
        try await storage.subscribe(
            connectionID: connectionID,
            streamID: streamID,
            actorID: actorID,
            lastSequence: 0
        )
    }

    /// Remove connection on disconnect
    public func unregister(connectionID: String) async throws {
        try await storage.unregister(connectionID: connectionID)
    }

    /// Update the last sequence number for a connection
    public func updateSequence(
        connectionID: String,
        lastSequence: UInt64
    ) async throws {
        try await storage.updateSequence(
            connectionID: connectionID,
            lastSequence: lastSequence
        )
    }

    // MARK: - Sending Data

    /// Send data to a specific connection
    public func send(data: Data, to connectionID: String) async throws {
        // Check if connection is still alive
        guard await sender.isAlive(connectionID: connectionID) else {
            // Connection is dead, clean up
            try? await storage.unregister(connectionID: connectionID)
            throw ConnectionError.connectionClosed
        }

        try await sender.send(data: data, to: connectionID)
    }

    /// Broadcast data to all connections subscribed to an actor
    public func broadcast(
        data: Data,
        to actorID: String,
        excluding excludeConnectionID: String? = nil
    ) async throws {
        let connections = try await storage.getConnections(for: actorID)

        await withTaskGroup(of: Void.self) { group in
            for connection in connections {
                if connection.connectionID == excludeConnectionID {
                    continue
                }

                group.addTask {
                    do {
                        try await self.send(data: data, to: connection.connectionID)
                    } catch {
                        // Log error but don't fail entire broadcast
                        print("Failed to send to connection \(connection.connectionID): \(error)")
                    }
                }
            }
        }
    }

    /// Broadcast a stream envelope to all connections for an actor
    public func broadcastEnvelope(
        _ envelope: TrebuchetEnvelope,
        to actorID: String,
        excluding excludeConnectionID: String? = nil
    ) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(envelope)

        try await broadcast(data: data, to: actorID, excluding: excludeConnectionID)
    }

    // MARK: - Query

    /// Get all active connections for an actor
    public func getConnections(for actorID: String) async throws -> [Connection] {
        try await storage.getConnections(for: actorID)
    }
}

// MARK: - Errors

public enum ConnectionError: Error, Sendable {
    case connectionClosed
    case connectionNotFound
    case invalidData
    case sendFailed(String)
}

// MARK: - In-Memory Implementation

/// In-memory connection storage for testing and local development
public actor InMemoryConnectionStorage: ConnectionStorage {
    private var connections: [String: Connection] = [:]
    private var actorIndex: [String: Set<String>] = [:]  // actorID -> Set<connectionID>

    public init() {}

    public func register(connectionID: String, actorID: String?) async throws {
        let connection = Connection(
            connectionID: connectionID,
            connectedAt: Date(),
            streamID: nil,
            actorID: actorID,
            lastSequence: 0
        )
        connections[connectionID] = connection

        if let actorID = actorID {
            actorIndex[actorID, default: []].insert(connectionID)
        }
    }

    public func subscribe(
        connectionID: String,
        streamID: UUID,
        actorID: String,
        lastSequence: UInt64
    ) async throws {
        guard var connection = connections[connectionID] else {
            throw ConnectionError.connectionNotFound
        }

        // Update connection
        connection = Connection(
            connectionID: connection.connectionID,
            connectedAt: connection.connectedAt,
            streamID: streamID,
            actorID: actorID,
            lastSequence: lastSequence
        )
        connections[connectionID] = connection

        // Update actor index
        actorIndex[actorID, default: []].insert(connectionID)
    }

    public func unregister(connectionID: String) async throws {
        guard let connection = connections.removeValue(forKey: connectionID) else {
            return  // Already removed
        }

        // Remove from actor index
        if let actorID = connection.actorID {
            actorIndex[actorID]?.remove(connectionID)
            if actorIndex[actorID]?.isEmpty == true {
                actorIndex.removeValue(forKey: actorID)
            }
        }
    }

    public func getConnections(for actorID: String) async throws -> [Connection] {
        guard let connectionIDs = actorIndex[actorID] else {
            return []
        }

        return connectionIDs.compactMap { connections[$0] }
    }

    public func updateSequence(
        connectionID: String,
        lastSequence: UInt64
    ) async throws {
        guard var connection = connections[connectionID] else {
            throw ConnectionError.connectionNotFound
        }

        connection = Connection(
            connectionID: connection.connectionID,
            connectedAt: connection.connectedAt,
            streamID: connection.streamID,
            actorID: connection.actorID,
            lastSequence: lastSequence
        )
        connections[connectionID] = connection
    }

    /// Clear all connections (useful for testing)
    public func clear() {
        connections.removeAll()
        actorIndex.removeAll()
    }
}

/// In-memory connection sender for testing
public actor InMemoryConnectionSender: ConnectionSender {
    private var sentMessages: [String: [Data]] = [:]
    private var aliveConnections: Set<String> = []

    public init() {}

    public func send(data: Data, to connectionID: String) async throws {
        guard aliveConnections.contains(connectionID) else {
            throw ConnectionError.connectionClosed
        }

        sentMessages[connectionID, default: []].append(data)
    }

    public func isAlive(connectionID: String) async -> Bool {
        aliveConnections.contains(connectionID)
    }

    // MARK: - Testing Helpers

    public func markAlive(_ connectionID: String) {
        aliveConnections.insert(connectionID)
    }

    public func markDead(_ connectionID: String) {
        aliveConnections.remove(connectionID)
    }

    public func getSentMessages(for connectionID: String) -> [Data] {
        sentMessages[connectionID] ?? []
    }

    public func clear() {
        sentMessages.removeAll()
        aliveConnections.removeAll()
    }
}
