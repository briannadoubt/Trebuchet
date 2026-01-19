import Foundation
import Trebuche

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
