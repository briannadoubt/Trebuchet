//
//  Server.swift
//  TrebuchetDemoServer
//

import Foundation
import Trebuchet
import Shared

@main
struct Server {
    static func main() async throws {
        let port: UInt16 = 8080

        print("🚀 Starting Trebuchet Demo Server on port \(port)...")

        let server = TrebuchetServer(transport: .webSocket(port: port))

        // Configure streaming for actors with @StreamedState properties
        // This enables realtime state updates to all connected clients
        // You can call configureStreaming multiple times for different actor types!

        // Option 1: Type-safe enum (recommended!)
        await server.configureStreaming(
            for: TodoListStreaming.self,
            method: TodoList.StreamingMethod.observeState
        ) { await $0.observeState() }

        // Option 2: String-based (also works)
        // await server.configureStreaming(
        //     for: TodoListStreaming.self,
        //     method: "observeState"
        // ) { await $0.observeState() }

        // Example: Configure streaming for actors with multiple @StreamedState properties
        // Option A: Type-safe switch over all methods (recommended for multiple streams!)
        // await server.configureStreaming(for: GameRoomStreaming.self) { method, room in
        //     switch method {
        //     case .observeGameState:
        //         return await room.observeGameState()
        //     case .observePlayerList:
        //         return await room.observePlayerList()
        //     case .observeChatMessages:
        //         return await room.observeChatMessages()
        //     }
        // }
        //
        // Option B: Register each method individually
        // await server.configureStreaming(
        //     for: GameRoomStreaming.self,
        //     method: GameRoom.StreamingMethod.observePlayers
        // ) { await $0.observePlayers() }

        // Create and expose actors with a simple factory syntax
        // The server automatically manages actor lifecycle and registration
        await server.expose("todos") { TodoList(actorSystem: $0) }

        // For multiple actors of the same or different types, just add more expose calls:
        // await server.expose("lobby") { GameLobby(actorSystem: $0) }
        // await server.expose("room-1") { GameRoom(actorSystem: $0) }
        // await server.expose("room-2") { GameRoom(actorSystem: $0) }
        // await server.expose("chat") { ChatRoom(actorSystem: $0) }

        print("✅ TodoList actor exposed as 'todos'")
        print("📡 Server ready at ws://localhost:\(port)")
        print("")
        print("Press Ctrl+C to stop the server")

        try await server.run()
    }
}
