//
//  Server.swift
//  TrebucheDemoServer
//

import Foundation
import Trebuche
import Shared

@main
struct Server {
    static func main() async throws {
        let port: UInt16 = 8080

        print("🚀 Starting Trebuche Demo Server on port \(port)...")

        // Create the server
        let server = TrebuchetServer(transport: .webSocket(port: port))

        // Create and expose the TodoList actor
        let todoList = TodoList(actorSystem: server.actorSystem)
        await server.expose(todoList, as: "todos")

        print("✅ TodoList actor exposed as 'todos'")
        print("📡 Server ready at ws://localhost:\(port)")
        print("")
        print("Press Ctrl+C to stop the server")

        // Run the server
        try await server.run()
    }
}
