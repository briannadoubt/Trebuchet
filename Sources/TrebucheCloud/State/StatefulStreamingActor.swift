import Foundation
import Trebuche

// MARK: - Stateful Streaming Actor

/// Protocol combining StatefulActor with streaming support.
///
/// This protocol enables actors to have both:
/// - **Persistent state** via `ActorStateStore` (for serverless environments)
/// - **Realtime streaming** via `@StreamedState` (for live updates to clients)
///
/// When state changes, both persistence and streaming happen automatically.
///
/// ## Example
///
/// ```swift
/// @Trebuchet
/// public distributed actor TodoList: StatefulStreamingActor {
///     public typealias PersistentState = State
///
///     private let stateStore: ActorStateStore
///
///     @StreamedState public var state = State()
///
///     public var persistentState: State {
///         get { state }
///         set { state = newValue }  // Triggers both streaming AND persistence
///     }
///
///     public init(
///         actorSystem: TrebuchetActorSystem,
///         stateStore: ActorStateStore
///     ) async throws {
///         self.actorSystem = actorSystem
///         self.stateStore = stateStore
///         try await loadState(from: stateStore)
///     }
///
///     public func loadState(from store: any ActorStateStore) async throws {
///         if let loaded = try await store.load(for: id.id, as: State.self) {
///             state = loaded  // Triggers stream update to all clients
///         }
///     }
///
///     public func saveState(to store: any ActorStateStore) async throws {
///         try await store.save(state, for: id.id)
///     }
///
///     public distributed func addTodo(title: String) async throws {
///         var newState = state
///         newState.todos.append(TodoItem(title: title))
///         state = newState  // 1. Streams to clients, 2. Save below
///
///         try await saveState(to: stateStore)
///     }
/// }
///
/// public struct State: Codable, Sendable {
///     var todos: [TodoItem] = []
/// }
/// ```
public protocol StatefulStreamingActor: StatefulActor {
    /// Whether to automatically save state after changes.
    ///
    /// When `true`, helper methods will automatically call `saveState(to:)`
    /// after updating state. When `false`, you must manually call `saveState`.
    ///
    /// Default: `true`
    var autoSaveEnabled: Bool { get }
}

extension StatefulStreamingActor {
    /// Default to auto-save enabled
    public var autoSaveEnabled: Bool { true }

    /// Helper to update a specific field and automatically persist.
    ///
    /// This method:
    /// 1. Updates the state field via keyPath
    /// 2. Triggers streaming (if using @StreamedState)
    /// 3. Persists to state store (if autoSaveEnabled)
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Instead of:
    /// var newState = state
    /// newState.count += 1
    /// state = newState
    /// try await saveState(to: stateStore)
    ///
    /// // Use:
    /// try await updateState(\.count, to: state.count + 1, store: stateStore)
    /// ```
    ///
    /// - Parameters:
    ///   - keyPath: The key path to the field to update
    ///   - value: The new value
    ///   - store: The state store to persist to
    public func updateState<T>(
        _ keyPath: WritableKeyPath<PersistentState, T>,
        to value: T,
        store: ActorStateStore
    ) async throws {
        var newState = persistentState
        newState[keyPath: keyPath] = value
        persistentState = newState  // Triggers streaming

        if autoSaveEnabled {
            try await saveState(to: store)
        }
    }

    /// Helper to transform state and automatically persist.
    ///
    /// This method:
    /// 1. Applies the transform function to current state
    /// 2. Updates persistentState (triggering streaming)
    /// 3. Persists to state store (if autoSaveEnabled)
    ///
    /// ## Example
    ///
    /// ```swift
    /// try await transformState(store: stateStore) { state in
    ///     var newState = state
    ///     newState.items.append(newItem)
    ///     newState.lastUpdated = Date()
    ///     return newState
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - store: The state store to persist to
    ///   - transform: Function that transforms the current state
    public func transformState(
        store: ActorStateStore,
        transform: @Sendable (PersistentState) -> PersistentState
    ) async throws {
        let newState = transform(persistentState)
        persistentState = newState  // Triggers streaming

        if autoSaveEnabled {
            try await saveState(to: store)
        }
    }

    /// Helper to transform state asynchronously and automatically persist.
    ///
    /// Same as `transformState(store:transform:)` but allows async operations
    /// in the transform function.
    ///
    /// - Parameters:
    ///   - store: The state store to persist to
    ///   - transform: Async function that transforms the current state
    public func transformStateAsync(
        store: ActorStateStore,
        transform: @Sendable (PersistentState) async throws -> PersistentState
    ) async throws {
        let newState = try await transform(persistentState)
        persistentState = newState  // Triggers streaming

        if autoSaveEnabled {
            try await saveState(to: store)
        }
    }
}

// MARK: - Convenience Extensions

extension StatefulStreamingActor {
    /// Load state from store and trigger streaming update.
    ///
    /// This is a convenience method that loads state and ensures
    /// any connected stream subscribers receive the loaded state.
    ///
    /// - Parameter store: The state store to load from
    /// - Returns: True if state was loaded, false if no state existed
    @discardableResult
    public func loadAndStream(from store: ActorStateStore) async throws -> Bool {
        if let loaded = try await store.load(for: id.id, as: PersistentState.self) {
            persistentState = loaded  // Triggers streaming
            return true
        }
        return false
    }
}
