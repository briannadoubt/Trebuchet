// Trebuchet - Location-transparent distributed actors for Swift
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
/// automatically adding the `ActorSystem` typealias and scanning for
/// @StreamedState properties to generate observe methods.
///
/// Usage:
/// ```swift
/// @Trebuchet
/// distributed actor ChatRoom {
///     @StreamedState var state = State(messages: [])
///
///     distributed func sendMessage(_ message: String) -> MessageID
/// }
/// ```
///
/// The macro will generate:
/// - `public func observeState() -> AsyncStream<State>`
@attached(member, names: named(ActorSystem), arbitrary)
public macro Trebuchet() = #externalMacro(module: "TrebuchetMacros", type: "TrebuchetMacro")

/// Marks a property for automatic state streaming.
///
/// The `@StreamedState` macro transforms a stored property into a computed property
/// that automatically notifies all subscribers when the value changes.
///
/// Usage:
/// ```swift
/// @Trebuchet
/// distributed actor TodoList {
///     @StreamedState var state = State(todos: [], pendingCount: 0)
///
///     distributed func addTodo(title: String) {
///         var todo = TodoItem(title: title)
///         state.todos.append(todo)  // Automatically notifies subscribers
///     }
/// }
/// ```
///
/// Requirements:
/// - Property must have an explicit type annotation
/// - Property type must be Codable and Sendable
/// - Can only be used within @Trebuchet distributed actors
@attached(accessor)
@attached(peer, names: arbitrary)
public macro StreamedState() = #externalMacro(module: "TrebuchetMacros", type: "StreamedStateMacro")

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
