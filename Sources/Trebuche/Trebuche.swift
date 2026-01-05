// Trebuche - Location-transparent distributed actors for Swift
//
// Make distributed actors stupid simple.
//
// Example:
// ```swift
// @Trebuchet
// distributed actor GameRoom {
//     distributed func join(player: Player) -> RoomState
// }
//
// // Server
// let server = TrebuchetServer(transport: .webSocket(port: 8080))
// let room = GameRoom(actorSystem: server.actorSystem)
// server.expose(room, as: "main-room")
// try await server.run()
//
// // Client
// let client = TrebuchetClient(transport: .webSocket(host: "localhost", port: 8080))
// try await client.connect()
// let room = try client.resolve(GameRoom.self, id: "main-room")
// try await room.join(player: me)
// ```

@_exported import Distributed

// MARK: - Macro Declaration

/// Marks a distributed actor for use with the Trebuchet system.
///
/// The `@Trebuchet` macro simplifies distributed actor declarations by
/// automatically adding the `ActorSystem` typealias and other boilerplate.
///
/// Usage:
/// ```swift
/// @Trebuchet
/// distributed actor ChatRoom {
///     distributed func sendMessage(_ message: String) -> MessageID
/// }
/// ```
@attached(member, names: named(ActorSystem))
public macro Trebuchet() = #externalMacro(module: "TrebucheMacros", type: "TrebuchetMacro")

// MARK: - Convenience Extensions

extension TrebuchetActorSystem {
    /// Create an actor system configured for use with a server
    public static func forServer(host: String, port: UInt16) -> TrebuchetActorSystem {
        let system = TrebuchetActorSystem()
        let transport = WebSocketTransport()
        system.configure(transport: transport, host: host, port: port)
        return system
    }

    /// Create an actor system configured for use with a client
    public static func forClient() -> TrebuchetActorSystem {
        TrebuchetActorSystem()
    }
}
