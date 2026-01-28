import Foundation
import Trebuchet

// MARK: - Actor State Store Protocol

/// Protocol for external state storage for distributed actors.
///
/// Since serverless functions are stateless, actors deployed to Lambda/Cloud Functions
/// need external storage for their state. This protocol abstracts the storage backend.
public protocol ActorStateStore: Sendable {
    /// Load state for an actor
    /// - Parameters:
    ///   - actorID: The actor's identifier
    ///   - type: The expected state type
    /// - Returns: The state if found, nil otherwise
    func load<State: Codable & Sendable>(
        for actorID: String,
        as type: State.Type
    ) async throws -> State?

    /// Save state for an actor
    /// - Parameters:
    ///   - state: The state to save
    ///   - actorID: The actor's identifier
    func save<State: Codable & Sendable>(
        _ state: State,
        for actorID: String
    ) async throws

    /// Delete state for an actor
    /// - Parameter actorID: The actor's identifier
    func delete(for actorID: String) async throws

    /// Check if state exists for an actor
    /// - Parameter actorID: The actor's identifier
    /// - Returns: True if state exists
    func exists(for actorID: String) async throws -> Bool

    /// Atomically update state using a transform function
    /// - Parameters:
    ///   - actorID: The actor's identifier
    ///   - type: The expected state type
    ///   - transform: Function to transform the state
    /// - Returns: The new state after transformation
    func update<State: Codable & Sendable>(
        for actorID: String,
        as type: State.Type,
        transform: @Sendable (State?) async throws -> State
    ) async throws -> State

    /// Get the current sequence number (version) for an actor's state
    /// - Parameter actorID: The actor's identifier
    /// - Returns: The current version number, or nil if no state exists
    func getSequenceNumber(for actorID: String) async throws -> UInt64?
}

// MARK: - State Versioning Extension

/// Errors related to state versioning
public enum ActorStateError: Error, Codable, Sendable {
    case versionConflict(expected: UInt64, actual: UInt64)
    case maxRetriesExceeded
    case stateNotFound
}

extension ActorStateStore {
    /// Load state with version metadata for optimistic locking
    /// - Parameters:
    ///   - actorID: The actor's identifier
    ///   - type: The expected state type
    /// - Returns: A snapshot containing the state and its version, or nil if not found
    public func loadWithVersion<State: Codable & Sendable>(
        for actorID: String,
        as type: State.Type
    ) async throws -> StateSnapshot<State>? {
        guard let state = try await load(for: actorID, as: type) else {
            return nil
        }

        // Get version from store-specific implementation
        let version = try await getSequenceNumber(for: actorID) ?? 0

        return StateSnapshot(
            state: state,
            version: Int(version),
            actorID: actorID
        )
    }

    /// Save state with version check to prevent concurrent write conflicts
    /// - Parameters:
    ///   - state: The state to save
    ///   - actorID: The actor's identifier
    ///   - expectedVersion: The version number that must match for the save to succeed
    /// - Returns: The new version number after save
    /// - Throws: ActorStateError.versionConflict if the version doesn't match
    public func saveIfVersion<State: Codable & Sendable>(
        _ state: State,
        for actorID: String,
        expectedVersion: UInt64
    ) async throws -> UInt64 {
        // Default implementation: compare-and-swap using the basic update
        // Stores should override this for atomic database-level checks
        let currentVersion = try await getSequenceNumber(for: actorID) ?? 0

        guard currentVersion == expectedVersion else {
            throw ActorStateError.versionConflict(
                expected: expectedVersion,
                actual: currentVersion
            )
        }

        try await save(state, for: actorID)
        return currentVersion + 1
    }

    /// Update state with automatic retry on version conflicts
    /// - Parameters:
    ///   - actorID: The actor's identifier
    ///   - type: The expected state type
    ///   - maxRetries: Maximum number of retry attempts
    ///   - transform: Function to transform the state
    /// - Returns: The new state after transformation
    /// - Throws: ActorStateError.maxRetriesExceeded if all retries fail
    public func updateWithRetry<State: Codable & Sendable>(
        for actorID: String,
        as type: State.Type,
        maxRetries: Int = 3,
        transform: @Sendable (State?) async throws -> State
    ) async throws -> State {
        for attempt in 1...maxRetries {
            let snapshot = try await loadWithVersion(for: actorID, as: type)

            let newState = try await transform(snapshot?.state)

            do {
                _ = try await saveIfVersion(
                    newState,
                    for: actorID,
                    expectedVersion: UInt64(snapshot?.version ?? 0)
                )
                return newState
            } catch ActorStateError.versionConflict where attempt < maxRetries {
                // Retry with exponential backoff
                try await Task.sleep(for: .milliseconds(100 * (1 << attempt)))
                continue
            } catch ActorStateError.versionConflict {
                // Final attempt failed - throw maxRetriesExceeded instead
                throw ActorStateError.maxRetriesExceeded
            }
        }
        throw ActorStateError.maxRetriesExceeded
    }

}

// MARK: - Default Implementations

extension ActorStateStore {
    /// Default implementation of getSequenceNumber for stores without native versioning
    public func getSequenceNumber(for actorID: String) async throws -> UInt64? {
        return nil
    }
}

// MARK: - State Store Options

/// Options for state store operations
public struct StateStoreOptions: Sendable {
    /// Time-to-live for cached state
    public var ttl: Duration?

    /// Whether to use optimistic locking
    public var optimisticLocking: Bool

    /// Consistency level for reads
    public var consistency: ConsistencyLevel

    public init(
        ttl: Duration? = nil,
        optimisticLocking: Bool = true,
        consistency: ConsistencyLevel = .eventual
    ) {
        self.ttl = ttl
        self.optimisticLocking = optimisticLocking
        self.consistency = consistency
    }

    public static let `default` = StateStoreOptions()
    public static let strongConsistency = StateStoreOptions(consistency: .strong)
}

/// Consistency level for state operations
public enum ConsistencyLevel: String, Sendable, Codable {
    /// Eventually consistent reads (faster)
    case eventual
    /// Strongly consistent reads (slower but guaranteed up-to-date)
    case strong
}

// MARK: - In-Memory State Store

/// Simple in-memory state store for testing and local development.
public actor InMemoryStateStore: ActorStateStore {
    private var storage: [String: Data] = [:]
    private var versions: [String: Int] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init() {}

    public func load<State: Codable & Sendable>(
        for actorID: String,
        as type: State.Type
    ) async throws -> State? {
        guard let data = storage[actorID] else {
            return nil
        }
        return try decoder.decode(State.self, from: data)
    }

    public func save<State: Codable & Sendable>(
        _ state: State,
        for actorID: String
    ) async throws {
        let data = try encoder.encode(state)
        storage[actorID] = data
        versions[actorID, default: 0] += 1
    }

    public func delete(for actorID: String) async throws {
        storage.removeValue(forKey: actorID)
        versions.removeValue(forKey: actorID)
    }

    public func exists(for actorID: String) async throws -> Bool {
        storage[actorID] != nil
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

    /// Get the version number for an actor's state
    public func version(for actorID: String) -> Int {
        versions[actorID] ?? 0
    }

    /// Clear all state (useful for testing)
    public func clear() {
        storage.removeAll()
        versions.removeAll()
    }

    // MARK: - Versioning Support

    public func getSequenceNumber(for actorID: String) async throws -> UInt64? {
        return versions[actorID].map { UInt64($0) }
    }

    public func saveIfVersion<State: Codable & Sendable>(
        _ state: State,
        for actorID: String,
        expectedVersion: UInt64
    ) async throws -> UInt64 {
        let currentVersion = UInt64(versions[actorID] ?? 0)

        guard currentVersion == expectedVersion else {
            throw ActorStateError.versionConflict(
                expected: expectedVersion,
                actual: currentVersion
            )
        }

        let data = try encoder.encode(state)
        storage[actorID] = data
        let newVersion = currentVersion + 1
        versions[actorID] = Int(newVersion)

        return newVersion
    }
}

// MARK: - Stateful Actor Protocol

/// Protocol for actors that use external state storage.
///
/// Actors conforming to this protocol can have their state automatically
/// persisted to an external store when deployed to serverless environments.
public protocol StatefulActor: DistributedActor where ActorSystem == TrebuchetActorSystem {
    /// The type of state this actor persists
    associatedtype PersistentState: Codable & Sendable

    /// Load state from the store
    func loadState(from store: any ActorStateStore) async throws

    /// Save state to the store
    func saveState(to store: any ActorStateStore) async throws

    /// The actor's persistent state
    var persistentState: PersistentState { get set }
}

// MARK: - State Snapshot

/// A snapshot of actor state with metadata
public struct StateSnapshot<State: Codable & Sendable>: Codable, Sendable {
    /// The actual state
    public let state: State

    /// Version number for optimistic locking
    public let version: Int

    /// When the snapshot was created
    public let timestamp: Date

    /// The actor ID this state belongs to
    public let actorID: String

    public init(state: State, version: Int, actorID: String) {
        self.state = state
        self.version = version
        self.timestamp = Date()
        self.actorID = actorID
    }
}
