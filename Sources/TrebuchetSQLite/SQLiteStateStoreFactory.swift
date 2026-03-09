import Trebuchet
import TrebuchetCloud

extension System {
    /// Creates a ``ShardedStateStore`` from a `.sqlite` ``StateConfiguration``.
    ///
    /// Call this from your ``System/makeStateStore(for:)`` implementation:
    ///
    /// ```swift
    /// @main struct MyGame: System {
    ///     static func makeStateStore(
    ///         for config: StateConfiguration
    ///     ) async throws -> (any Sendable)? {
    ///         try await Self.makeSQLiteStateStore(for: config)
    ///     }
    ///
    ///     var topology: some Topology {
    ///         GameRoom.self.state(.sqlite(shards: 4))
    ///     }
    /// }
    /// ```
    ///
    /// - Parameter config: The state configuration from the topology DSL.
    /// - Returns: A ``ShardedStateStore`` if the config is `.sqlite`, otherwise `nil`.
    public static func makeSQLiteStateStore(
        for config: StateConfiguration
    ) async throws -> (any ActorStateStore)? {
        guard case .sqlite(let path, let shards) = config else { return nil }
        let root = path ?? ".trebuchet/db"
        let storageConfig = SQLiteStorageConfiguration(root: root, shardCount: shards)
        let manager = SQLiteShardManager(configuration: storageConfig)
        try await manager.initialize()
        return await ShardedStateStore(shardManager: manager)
    }
}
