import Distributed

/// Protocol that all Trebuchet distributed actors must conform to.
///
/// This protocol enforces a standard initialization interface for actors,
/// enabling the CLI to automatically instantiate actors for development and deployment.
///
/// ## Usage
///
/// The `@Trebuchet` macro automatically adds conformance to this protocol:
///
/// ```swift
/// @Trebuchet
/// public distributed actor GameRoom {
///     // Actors with custom init parameters should provide a convenience init
///     public init(actorSystem: TrebuchetActorSystem) {
///         self.actorSystem = actorSystem
///         // Initialize with defaults for dev mode
///     }
/// }
/// ```
///
/// ## Custom Initializers
///
/// If your actor needs custom initialization parameters for production,
/// provide them as a separate initializer alongside the protocol-required init:
///
/// ```swift
/// @Trebuchet
/// public distributed actor UserActor {
///     let userID: String
///
///     // Production initializer
///     public init(actorSystem: TrebuchetActorSystem, userID: String) {
///         self.actorSystem = actorSystem
///         self.userID = userID
///     }
///
///     // Required by TrebuchetActor - used by CLI dev mode
///     public init(actorSystem: TrebuchetActorSystem) {
///         self.actorSystem = actorSystem
///         self.userID = "dev-user-\(UUID())"
///     }
/// }
/// ```
///
/// **Note**: Actors do not support `convenience` initializers, so you must provide
/// separate regular initializers for each use case.
public protocol TrebuchetActor: DistributedActor where ActorSystem == TrebuchetActorSystem {
    /// Initialize the actor with a Trebuchet actor system.
    ///
    /// This initializer is required for the Trebuchet CLI to automatically
    /// instantiate actors during development (`trebuchet dev`) and deployment.
    ///
    /// For actors that require additional parameters in production, implement this
    /// as a convenience initializer that provides sensible defaults for development.
    ///
    /// - Parameter actorSystem: The actor system to use for this actor
    init(actorSystem: TrebuchetActorSystem)
}
