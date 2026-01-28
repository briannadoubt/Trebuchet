import Foundation
import Trebuchet

// MARK: - Versioned State Protocol

/// Protocol for state structures that support schema versioning and migration
public protocol VersionedState: Codable, Sendable {
    /// The current schema version for this state type
    static var currentSchemaVersion: Int { get }

    /// Migrate state from an older schema version
    /// - Parameter oldVersion: The version to migrate from
    /// - Returns: The migrated state
    /// - Throws: If migration is not possible or fails
    func migrate(from oldVersion: Int) throws -> Self
}

// MARK: - State Updater

/// Helper for safe state updates with automatic optimistic locking
public struct StateUpdater<State: Codable & Sendable>: Sendable {
    public let store: any ActorStateStore
    public let actorID: String

    public init(store: any ActorStateStore, actorID: String) {
        self.store = store
        self.actorID = actorID
    }

    /// Update state with automatic retry on version conflicts
    /// - Parameters:
    ///   - maxRetries: Maximum number of retry attempts (default: 3)
    ///   - transform: Function to transform the current state into new state
    /// - Returns: The new state after successful update
    /// - Throws: ActorStateError.maxRetriesExceeded if all retries fail
    public func update(
        maxRetries: Int = 3,
        _ transform: @Sendable (State?) async throws -> State
    ) async throws -> State {
        return try await store.updateWithRetry(
            for: actorID,
            as: State.self,
            maxRetries: maxRetries,
            transform: transform
        )
    }

}

// MARK: - StatefulActor Extensions

extension StatefulActor {
    /// Create a StateUpdater for this actor
    /// - Parameter store: The state store to use
    /// - Returns: A StateUpdater configured for this actor
    public func stateUpdater(store: any ActorStateStore) -> StateUpdater<PersistentState> {
        StateUpdater(store: store, actorID: id.id)
    }

    /// Update the actor's state safely with automatic retry on version conflicts
    /// - Parameters:
    ///   - store: The state store to use
    ///   - maxRetries: Maximum number of retry attempts (default: 3)
    ///   - transform: Function to transform the current state
    /// - Throws: ActorStateError.maxRetriesExceeded if all retries fail
    public func updateStateSafely(
        store: any ActorStateStore,
        maxRetries: Int = 3,
        _ transform: @Sendable (PersistentState?) async throws -> PersistentState
    ) async throws {
        let updater = stateUpdater(store: store)
        persistentState = try await updater.update(maxRetries: maxRetries, transform)
    }

}
