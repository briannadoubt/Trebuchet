import Trebuchet

extension TrebuchetRuntime {
    /// The state store injected by the System DSL, if any.
    ///
    /// This provides typed access to the opaque `_stateStoreBox` property.
    /// Actors can access this in their `init` to load persisted state:
    ///
    /// ```swift
    /// @Trebuchet
    /// distributed actor GameRoom {
    ///     init(actorSystem: TrebuchetActorSystem) async throws {
    ///         self.actorSystem = actorSystem
    ///         if let store = actorSystem.stateStore {
    ///             try await loadState(from: store)
    ///         }
    ///     }
    /// }
    /// ```
    public var stateStore: (any ActorStateStore)? {
        _stateStoreBox as? (any ActorStateStore)
    }
}
