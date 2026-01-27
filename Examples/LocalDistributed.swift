#!/usr/bin/env swift

// Local Distributed Actor Demo
// Run with: swift Examples/LocalDistributed.swift
//
// This demonstrates:
// - Multiple actors running on different "nodes" (ports)
// - Cross-actor remote calls
// - All running locally, zero AWS required

import Foundation

// Simulating the Trebuchet imports (you'd actually import these)
// import Trebuchet
// import TrebuchetCloud

print("""
🚀 Local Distributed Actor Demo
================================

This example shows how Trebuchet actors can run distributed
across multiple "nodes" (different ports) on localhost:

  Node 1 (port 9000): GameLobby actor
  Node 2 (port 9001): GameRoom actor
  Node 3 (port 9002): PlayerStats actor

All running locally with NO AWS required!

To run the actual implementation:

1. Build the project:
   swift build

2. Run the TrebuchetDemo:
   swift run TrebuchetDemo

3. Or create your own:

```swift
import Trebuchet
import TrebuchetCloud

@Trebuchet
distributed actor MyActor {
    distributed func hello() -> String {
        "Hello from distributed actor!"
    }
}

@main
struct Demo {
    static func main() async throws {
        // Option 1: Single server (simplest)
        let server = TrebuchetServer(transport: .webSocket(port: 8080))
        let actor = MyActor(actorSystem: server.actorSystem)
        await server.expose(actor, as: "my-actor")

        Task { try await server.run() }
        try await Task.sleep(for: .milliseconds(100))

        // Client from anywhere (another process, another machine)
        let client = TrebuchetClient(transport: .webSocket(
            host: "localhost",
            port: 8080
        ))
        try await client.connect()
        let remote = try client.resolve(MyActor.self, id: "my-actor")
        print(try await remote.hello())

        // Option 2: Multi-node with LocalProvider
        let provider = LocalProvider(basePort: 9000)

        // Deploy multiple actors on different ports
        let deployment1 = try await provider.deploy(
            MyActor.self,
            as: "actor-1",
            config: .default
        ) { MyActor(actorSystem: $0) }

        let deployment2 = try await provider.deploy(
            MyActor.self,
            as: "actor-2",
            config: .default
        ) { MyActor(actorSystem: $0) }

        print("Actor 1 on port \\(deployment1.port)")
        print("Actor 2 on port \\(deployment2.port)")

        // Actors can call each other across nodes!
    }
}
```

4. With Docker Compose (multi-container):

```bash
docker-compose up
```

See docker-compose.yml for configuration.

📚 Key Points:

• LocalProvider runs multiple HTTP gateways locally
• Each actor gets its own port (simulating separate machines)
• Use PostgreSQL locally for shared state (docker run postgres)
• All Phase 1 features (auth, rate limiting, metrics) work locally
• Zero cloud deployment required for development

🔧 Local State Options:

1. In-Memory: Fast, lost on restart (default)
2. PostgreSQL: Persistent, multi-instance sync
   docker run -p 5432:5432 -e POSTGRES_PASSWORD=test postgres
3. File-based: Custom ActorStateStore implementation

🌐 Production Deployment:

When ready for production, swap LocalProvider for AWSProvider.
Everything else stays the same! Your actors are cloud-agnostic.
""")
